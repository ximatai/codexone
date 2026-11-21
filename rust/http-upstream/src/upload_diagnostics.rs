use std::{
    sync::{
        Arc, Mutex,
        atomic::{AtomicU64, Ordering},
    },
    time::{Duration, Instant},
};

const MIB: usize = 1024 * 1024;

#[derive(Clone, Default)]
pub struct CompressionTime(Arc<AtomicU64>);

impl CompressionTime {
    pub fn record(&self, elapsed: Duration) {
        self.0.fetch_add(
            elapsed.as_nanos().min(u64::MAX as u128) as u64,
            Ordering::Relaxed,
        );
    }
}

pub(crate) struct UploadDiagnostics {
    plain: usize,
    wire: usize,
    sent: bool,
    began: Instant,
    compression: Option<CompressionTime>,
}

impl UploadDiagnostics {
    pub(crate) fn new(plain: usize, compression: Option<CompressionTime>) -> Option<Self> {
        (plain > 8 * MIB).then(|| Self {
            plain,
            wire: 0,
            sent: false,
            began: Instant::now(),
            compression,
        })
    }

    pub(crate) fn pulled(&mut self, bytes: usize, sent: bool) {
        self.wire += bytes;
        self.sent = sent;
    }
}

impl Drop for UploadDiagnostics {
    fn drop(&mut self) {
        static LIMIT: Mutex<Option<(Instant, u8)>> = Mutex::new(None);
        let now = Instant::now();
        let mut limit = LIMIT.lock().unwrap();
        let (start, count) = limit.get_or_insert((now, 0));
        if now.duration_since(*start) >= Duration::from_secs(60) {
            (*start, *count) = (now, 0);
        }
        if *count >= 16 {
            return;
        }
        *count += 1;
        drop(limit);
        let result = if self.sent { "sent" } else { "interrupted" };
        let plain = size_bucket(self.plain);
        let wire = match self.wire.div_ceil(MIB) {
            0..=1 => "at_most_1_mib",
            2..=4 => "1_to_4_mib",
            5..=8 => "4_to_8_mib",
            9..=16 => "8_to_16_mib",
            _ => size_bucket(self.wire),
        };
        let upload = match now.duration_since(self.began).as_secs() {
            0 => "under_1_s",
            1..=9 => "1_to_10_s",
            10..=29 => "10_to_30_s",
            30..=59 => "30_to_60_s",
            _ => "at_least_60_s",
        };
        let (encoding, compression) = match &self.compression {
            None => ("identity", "not_applicable"),
            Some(time) => {
                let bucket = match Duration::from_nanos(time.0.load(Ordering::Relaxed)).as_millis()
                {
                    0 => "under_1_ms",
                    1..=9 => "1_to_10_ms",
                    10..=99 => "10_to_100_ms",
                    100..=999 => "100_to_1000_ms",
                    _ => "at_least_1000_ms",
                };
                ("zstd", bucket)
            }
        };
        eprintln!(
            "Upstream request upload transport=http result={result} size_bucket={plain} \
             upload_duration_bucket={upload} content_encoding={encoding} wire_size_bucket={wire} \
             compression_duration_bucket={compression}"
        );
    }
}

fn size_bucket(bytes: usize) -> &'static str {
    match bytes.div_ceil(MIB) {
        0..=16 => "at_most_16_mib",
        17..=24 => "16_to_24_mib",
        25..=32 => "24_to_32_mib",
        _ => "over_32_mib",
    }
}
