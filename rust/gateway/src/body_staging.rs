use std::{
    fs::File,
    io::Write,
    os::unix::fs::{FileExt, MetadataExt},
    path::PathBuf,
    sync::Arc,
};

use aes_gcm::{
    Aes256Gcm, Nonce, Tag,
    aead::{AeadInPlace, KeyInit, OsRng, rand_core::RngCore},
};
use bytes::{Bytes, BytesMut};
use codexone_http_upstream::UPLOAD_CHUNK_BYTES;
use tokio::sync::{OwnedSemaphorePermit, Semaphore};
use zeroize::Zeroizing;

use crate::upload_workers::UploadWorkers;

const BLOCK: usize = UPLOAD_CHUNK_BYTES;
const NONCE: usize = 12;
const TAG: usize = 16;
const OVERHEAD: usize = NONCE + TAG;
pub(crate) const THRESHOLD: usize = 8 * 1024 * 1024;
const CAPACITY: u32 = 192 * 1024 * 1024;

#[derive(Clone, Copy, Debug)]
pub(crate) enum StageError {
    Capacity,
    StoragePressure,
    StorageUnavailable,
    InvalidLength,
}

use StageError::{Capacity, InvalidLength, StoragePressure, StorageUnavailable};

pub(crate) struct BodyStaging {
    directory: Arc<PathBuf>,
    available: Arc<Semaphore>,
    workers: Arc<UploadWorkers>,
}

impl BodyStaging {
    pub(crate) fn new(directory: PathBuf) -> std::io::Result<Self> {
        Ok(Self {
            directory: Arc::new(directory),
            available: Arc::new(Semaphore::new(CAPACITY as usize)),
            workers: Arc::new(UploadWorkers::new("http-body-staging")?),
        })
    }

    pub(crate) async fn begin(&self, length: usize) -> Result<StagingWriter, StageError> {
        let reservation = self.reserve(length)?;
        self.create(length, reservation).await
    }

    fn reserve(&self, length: usize) -> Result<OwnedSemaphorePermit, StageError> {
        self.available
            .clone()
            .try_acquire_many_owned(disk_bytes(length)?)
            .map_err(|_| Capacity)
    }

    async fn create(
        &self,
        length: usize,
        reservation: OwnedSemaphorePermit,
    ) -> Result<StagingWriter, StageError> {
        let directory = self.directory.clone();
        let file = self
            .workers
            .run(StorageUnavailable, move || {
                codexone_storage::require_free_space(&directory, i64::from(CAPACITY), true)
                    .map_err(|_| StoragePressure)?;
                // The temporary file is anonymous or unlinked before any bytes are written.
                let file = tempfile::tempfile_in(&*directory).map_err(|_| StorageUnavailable)?;
                // tempfile's Unix fallback ignores errors from unlink.
                if file.metadata().map_err(|_| StorageUnavailable)?.nlink() != 0 {
                    return Err(StorageUnavailable);
                }
                let mut key = Zeroizing::new([0; 32]);
                OsRng
                    .try_fill_bytes(key.as_mut())
                    .map_err(|_| StorageUnavailable)?;
                Ok(EncryptedFile {
                    file,
                    key,
                    length,
                    _reservation: reservation,
                })
            })
            .await?;
        Ok(StagingWriter {
            workers: self.workers.clone(),
            data: WriterData {
                file,
                pending: Zeroizing::new(Vec::with_capacity(BLOCK)),
                committed: 0,
            },
        })
    }

    pub(crate) async fn rewrite(
        &self,
        mut bytes: Bytes,
        StageReservation(mut reservation): StageReservation,
    ) -> Result<StagedBody, StageError> {
        #[cfg(all(target_os = "linux", target_env = "gnu"))]
        let reclaim_pages = bytes.len() >= 32 * 1024 * 1024;
        let wanted = disk_bytes(bytes.len())?;
        let held = reservation.num_permits();
        if wanted as usize > held {
            reservation.merge(
                self.available
                    .clone()
                    .try_acquire_many_owned(wanted - held as u32)
                    .map_err(|_| Capacity)?,
            );
        } else {
            drop(reservation.split(held - wanted as usize));
        }
        let mut writer = self.create(bytes.len(), reservation).await?;
        while !bytes.is_empty() {
            let chunk = bytes.split_to(bytes.len().min(BLOCK));
            // A cancelled writer job can outlive the caller's shared memory permit.
            writer = writer.append(Bytes::copy_from_slice(&chunk)).await?;
        }
        drop(bytes);
        let staged = writer.seal().await?;
        #[cfg(all(target_os = "linux", target_env = "gnu"))]
        if reclaim_pages {
            // Large structured JSON leaves free pages inside the glibc arena. Reclaim
            // them on a staging worker after dropping the decoded and encoded buffers.
            let _ = self
                .workers
                .run((), || {
                    // SAFETY: glibc supports concurrent calls and takes no pointers here.
                    unsafe { libc::malloc_trim(0) };
                    Ok(())
                })
                .await;
        }
        Ok(staged)
    }
}

pub(crate) struct StageReservation(OwnedSemaphorePermit);

pub(crate) struct StagingWriter {
    workers: Arc<UploadWorkers>,
    data: WriterData,
}

impl StagingWriter {
    pub(crate) async fn append(self, chunk: Bytes) -> Result<Self, StageError> {
        let Self { workers, mut data } = self;
        let data = workers
            .run(StorageUnavailable, move || {
                if chunk.len() > data.file.length - data.committed - data.pending.len() {
                    return Err(InvalidLength);
                }
                let mut tail = chunk.as_ref();
                while !tail.is_empty() {
                    let take = tail.len().min(BLOCK - data.pending.len());
                    data.pending.extend_from_slice(&tail[..take]);
                    tail = &tail[take..];
                    if data.pending.len() == BLOCK {
                        data.write_block()?;
                    }
                }
                Ok(data)
            })
            .await?;
        Ok(Self { workers, data })
    }

    pub(crate) async fn seal(self) -> Result<StagedBody, StageError> {
        let Self { workers, mut data } = self;
        let file = workers
            .run(StorageUnavailable, move || {
                if data.committed + data.pending.len() != data.file.length {
                    return Err(InvalidLength);
                }
                if !data.pending.is_empty() {
                    data.write_block()?;
                }
                Ok(data.file)
            })
            .await?;
        Ok(StagedBody {
            file: Arc::new(file),
            workers,
        })
    }
}

struct WriterData {
    file: EncryptedFile,
    pending: Zeroizing<Vec<u8>>,
    committed: usize,
}

impl WriterData {
    fn write_block(&mut self) -> Result<(), StageError> {
        let index = ((self.committed / BLOCK) as u64).to_be_bytes();
        // The block index is a unique nonce for this file's independent random key.
        let mut nonce = [0; NONCE];
        nonce[NONCE - index.len()..].copy_from_slice(&index);
        let cipher = Aes256Gcm::new(self.file.key.as_ref().into());
        let tag = cipher
            .encrypt_in_place_detached(Nonce::from_slice(&nonce), &index, &mut self.pending)
            .map_err(|_| StorageUnavailable)?;
        self.file
            .file
            .write_all(&nonce)
            .and_then(|_| self.file.file.write_all(&self.pending))
            .and_then(|_| self.file.file.write_all(&tag))
            .map_err(|_| StorageUnavailable)?;
        self.committed += self.pending.len();
        self.pending.clear();
        Ok(())
    }
}

struct EncryptedFile {
    file: File,
    key: Zeroizing<[u8; 32]>,
    length: usize,
    _reservation: OwnedSemaphorePermit,
}

#[derive(Clone)]
pub(crate) struct StagedBody {
    file: Arc<EncryptedFile>,
    workers: Arc<UploadWorkers>,
}

impl StagedBody {
    pub(crate) fn len(&self) -> usize {
        self.file.length
    }

    pub(crate) async fn read_block(&self, offset: usize) -> Result<Bytes, StageError> {
        debug_assert!(offset.is_multiple_of(BLOCK) && offset < self.len());
        let file = self.file.clone();
        self.workers
            .run(StorageUnavailable, move || {
                let block = offset / BLOCK;
                let length = (file.length - offset).min(BLOCK);
                let mut record = vec![0; length + OVERHEAD];
                file.file
                    .read_exact_at(&mut record, (offset + block * OVERHEAD) as u64)
                    .map_err(|_| StorageUnavailable)?;
                let (nonce, rest) = record.split_at_mut(NONCE);
                let (ciphertext, tag) = rest.split_at_mut(length);
                let cipher = Aes256Gcm::new(file.key.as_ref().into());
                cipher
                    .decrypt_in_place_detached(
                        Nonce::from_slice(nonce),
                        &(block as u64).to_be_bytes(),
                        ciphertext,
                        Tag::from_slice(tag),
                    )
                    .map_err(|_| StorageUnavailable)?;
                Ok(Bytes::from(record).slice(NONCE..NONCE + length))
            })
            .await
    }

    /// Close the inbound file while holding the staging capacity for re-encoding.
    pub(crate) async fn decode(self) -> Result<(Bytes, StageReservation), StageError> {
        let mut result = BytesMut::with_capacity(self.len());
        for offset in (0..self.len()).step_by(BLOCK) {
            result.extend_from_slice(&self.read_block(offset).await?);
        }
        let EncryptedFile { _reservation, .. } =
            Arc::try_unwrap(self.file).map_err(|_| StorageUnavailable)?;
        Ok((result.freeze(), StageReservation(_reservation)))
    }
}

fn disk_bytes(length: usize) -> Result<u32, StageError> {
    length
        .checked_add(length.div_ceil(BLOCK) * OVERHEAD)
        .and_then(|bytes| u32::try_from(bytes).ok())
        .ok_or(Capacity)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn stage_is_anonymous_and_authenticates_block_position() {
        let directory = tempfile::tempdir().unwrap();
        let staging = BodyStaging::new(directory.path().to_owned()).unwrap();
        let length = 2 * BLOCK;
        let writer = staging.begin(length).await.unwrap();
        let writer = writer.append(Bytes::from(vec![b'a'; BLOCK])).await.unwrap();
        let writer = writer.append(Bytes::from(vec![b'b'; BLOCK])).await.unwrap();
        let body = writer.seal().await.unwrap();

        assert_eq!(directory.path().read_dir().unwrap().count(), 0);
        assert_eq!(
            body.file.file.metadata().unwrap().len(),
            disk_bytes(length).unwrap() as u64
        );
        assert_eq!(body.read_block(0).await.unwrap(), vec![b'a'; BLOCK]);
        assert_eq!(body.read_block(BLOCK).await.unwrap(), vec![b'b'; BLOCK]);
        let mut second_record = vec![0; BLOCK + OVERHEAD];
        body.file
            .file
            .read_exact_at(&mut second_record, (BLOCK + OVERHEAD) as u64)
            .unwrap();
        body.file.file.write_all_at(&second_record, 0).unwrap();
        assert!(matches!(
            body.read_block(0).await,
            Err(StageError::StorageUnavailable)
        ));

        drop(body);
        assert_eq!(staging.available.available_permits(), CAPACITY as usize);
    }

    #[test]
    fn stage_budget_includes_record_overhead_and_releases_abandoned_reservations() {
        let directory = tempfile::tempdir().unwrap();
        let staging = BodyStaging::new(directory.path().to_owned()).unwrap();
        let max = codexone_responses::MAX_REQUEST_BYTES;
        let first = staging.reserve(max).unwrap();
        let second = staging.reserve(max).unwrap();
        assert!(matches!(staging.reserve(max), Err(StageError::Capacity)));
        drop(first);
        let third = staging.reserve(max).unwrap();
        drop((second, third));
        assert_eq!(staging.available.available_permits(), CAPACITY as usize);
    }
}
