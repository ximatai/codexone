use std::{sync::Mutex, time::Duration};

use tokio::time::Instant;

pub enum Path {
    Http,
    Native,
    Continuation,
    Http1009,
    Native1009,
    Continuation1009,
    Indeterminate1009,
}

#[derive(Default)]
pub struct SizeDiagnostics(Mutex<Option<(Instant, u8)>>);

impl SizeDiagnostics {
    pub fn record(&self, path: Path, bytes: usize) {
        let mut state = self.0.lock().unwrap();
        let now = Instant::now();
        let (start, count) = state.get_or_insert((now, 0));
        if now.duration_since(*start) >= Duration::from_secs(60) {
            *start = now;
            *count = 0;
        }
        if *count >= 16 {
            return;
        }
        *count += 1;
        drop(state);

        let (path, close) = match path {
            Path::Http => ("http", ""),
            Path::Native => ("reject_native", ""),
            Path::Continuation => ("reject_continuation", ""),
            Path::Http1009 => ("http_1009", " upstream_ws_close_code=1009"),
            Path::Native1009 => ("reject_native_1009", " upstream_ws_close_code=1009"),
            Path::Continuation1009 => ("reject_continuation_1009", " upstream_ws_close_code=1009"),
            Path::Indeterminate1009 => ("indeterminate_1009", " upstream_ws_close_code=1009"),
        };
        let bucket = match bytes {
            ..=16_777_216 => "at_most_16_mib",
            16_777_217..=25_165_824 => "16_to_24_mib",
            25_165_825..=33_554_432 => "24_to_32_mib",
            _ => "over_32_mib",
        };
        eprintln!("Request body size boundary path={path} size_bucket={bucket}{close}");
    }
}
