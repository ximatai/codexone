use std::{
    io,
    sync::{Arc, Mutex, mpsc},
    thread::{self, JoinHandle},
};

use tokio::sync::oneshot;

type Job = Box<dyn FnOnce() + Send>;

/// The caller holds an upload reservation through each job and submits at most
/// one job at a time. Closing the pool joins any final in-flight block.
pub(crate) struct UploadWorkers {
    jobs: Option<mpsc::Sender<Job>>,
    threads: Vec<JoinHandle<()>>,
}

impl UploadWorkers {
    pub(crate) fn new(name: &str) -> io::Result<Self> {
        let (jobs, receiver) = mpsc::channel::<Job>();
        let receiver = Arc::new(Mutex::new(receiver));
        let mut pool = Self {
            jobs: Some(jobs),
            threads: Vec::new(),
        };
        for index in 0..2 {
            let receiver = receiver.clone();
            pool.threads.push(
                thread::Builder::new()
                    .name(format!("{name}-{index}"))
                    .spawn(move || {
                        loop {
                            let next = receiver.lock().unwrap().recv();
                            match next {
                                Ok(job) => job(),
                                Err(_) => break,
                            }
                        }
                    })?,
            );
        }
        Ok(pool)
    }

    pub(crate) async fn run<T: Send + 'static, E: Send + 'static>(
        &self,
        stopped: E,
        work: impl FnOnce() -> Result<T, E> + Send + 'static,
    ) -> Result<T, E> {
        let (send, receive) = oneshot::channel();
        let job = Box::new(move || {
            if !send.is_closed() {
                let _ = send.send(work());
            }
        });
        if self.jobs.as_ref().unwrap().send(job).is_err() {
            return Err(stopped);
        }
        receive.await.unwrap_or(Err(stopped))
    }
}

impl Drop for UploadWorkers {
    fn drop(&mut self) {
        drop(self.jobs.take());
        for worker in self.threads.drain(..) {
            let _ = worker.join();
        }
    }
}
