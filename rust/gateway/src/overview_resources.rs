use serde::Serialize;
use std::{collections::VecDeque, sync::Mutex};

const WINDOW_SECONDS: i64 = 3600;

#[derive(Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
struct Sample {
    unix_seconds: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    process_resident_bytes: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    host_available_bytes: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    host_total_bytes: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    #[serde(rename = "hostCPUPercent")]
    host_cpu_percent: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    host_load_average_1m: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    disk_available_bytes: Option<u64>,
}

#[derive(Default)]
pub(crate) struct ResourceHistory(Mutex<VecDeque<Sample>>);

impl ResourceHistory {
    fn in_window(sample: &Sample, now: i64) -> bool {
        (now.saturating_sub(WINDOW_SECONDS)..=now).contains(&sample.unix_seconds)
    }

    #[cfg(any(target_os = "linux", test))]
    fn record(&self, sample: Sample) {
        const MAX_SAMPLES: usize = 121;
        let mut samples = self.0.lock().expect("resource history");
        let now = sample.unix_seconds;
        samples.retain(|sample| sample.unix_seconds < now && Self::in_window(sample, now));
        if samples.len() >= MAX_SAMPLES {
            samples.pop_front();
        }
        samples.push_back(sample);
    }

    pub(crate) fn snapshot(&self, now: i64) -> impl Serialize {
        self.0
            .lock()
            .expect("resource history")
            .iter()
            .filter(|sample| Self::in_window(sample, now))
            .cloned()
            .collect::<Vec<_>>()
    }
}

#[cfg(any(target_os = "linux", test))]
mod linux {
    use super::Sample;

    #[derive(Clone, Copy)]
    struct Cpu {
        total: u64,
        idle: u64,
    }

    impl Cpu {
        fn parse(stat: &str) -> Option<Self> {
            let mut fields = stat.lines().next()?.split_whitespace();
            if fields.next()? != "cpu" {
                return None;
            }
            let mut ticks = [0_u64; 8];
            for tick in &mut ticks {
                *tick = fields.next()?.parse().ok()?;
            }
            Some(Self {
                total: ticks.into_iter().try_fold(0_u64, u64::checked_add)?,
                idle: ticks[3].checked_add(ticks[4])?,
            })
        }

        fn percent_since(self, previous: Self) -> Option<f64> {
            let elapsed = self.total.checked_sub(previous.total)?;
            let idle = self.idle.checked_sub(previous.idle)?;
            let active = elapsed.checked_sub(idle)?;
            (elapsed > 0).then(|| active as f64 / elapsed as f64 * 100.0)
        }
    }

    fn kib_value(contents: &str, key: &str) -> Option<u64> {
        let mut fields = contents
            .lines()
            .find_map(|line| line.strip_prefix(key))?
            .split_whitespace();
        let kib: u64 = fields.next()?.parse().ok()?;
        if fields.next()? != "kB" || fields.next().is_some() {
            return None;
        }
        kib.checked_mul(1024)
    }

    #[derive(Default)]
    pub(super) struct Sampler {
        previous_cpu: Option<Cpu>,
    }

    impl Sampler {
        pub(super) fn sample(
            &mut self,
            now: i64,
            stat: &str,
            meminfo: &str,
            status: &str,
            loadavg: &str,
            disk: Option<u64>,
        ) -> Sample {
            let cpu = Cpu::parse(stat);
            let host_cpu_percent = cpu
                .zip(self.previous_cpu)
                .and_then(|(current, previous)| current.percent_since(previous));
            self.previous_cpu = cpu;
            Sample {
                unix_seconds: now,
                process_resident_bytes: kib_value(status, "VmRSS:"),
                host_available_bytes: kib_value(meminfo, "MemAvailable:"),
                host_total_bytes: kib_value(meminfo, "MemTotal:").filter(|value| *value > 0),
                host_cpu_percent,
                host_load_average_1m: loadavg
                    .split_whitespace()
                    .next()
                    .and_then(|value| value.parse::<f64>().ok())
                    .filter(|value| value.is_finite() && *value >= 0.0),
                disk_available_bytes: disk,
            }
        }
    }
}

#[cfg(target_os = "linux")]
pub(crate) async fn run(
    history: std::sync::Arc<ResourceHistory>,
    execution: codexone_execution::ExecutionService,
    stopping: tokio_util::sync::CancellationToken,
) {
    use std::{
        fs,
        io::{BufRead, BufReader},
        time::Duration,
    };
    use tokio::{task, time};

    let mut sampler = linux::Sampler::default();
    loop {
        if stopping.is_cancelled() {
            return;
        }
        let execution = execution.clone();
        let Ok((next, sample)) = task::spawn_blocking(move || {
            let mut stat = String::new();
            if let Ok(file) = fs::File::open("/proc/stat") {
                let _ = BufReader::new(file).read_line(&mut stat);
            }
            let meminfo = fs::read_to_string("/proc/meminfo").unwrap_or_default();
            let status = fs::read_to_string("/proc/self/status").unwrap_or_default();
            let loadavg = fs::read_to_string("/proc/loadavg").unwrap_or_default();
            let sample = sampler.sample(
                crate::management_usage::unix_now(),
                &stat,
                &meminfo,
                &status,
                &loadavg,
                execution.storage_observation().available_bytes,
            );
            (sampler, sample)
        })
        .await
        else {
            return;
        };
        sampler = next;
        history.record(sample);
        tokio::select! {
            _ = stopping.cancelled() => return,
            _ = time::sleep(Duration::from_secs(30)) => {}
        }
    }
}

#[cfg(test)]
mod tests {
    use serde_json::{json, to_value};

    use super::*;

    #[test]
    fn caps_history_and_drops_expired_or_future_samples() {
        let history = ResourceHistory::default();
        let record = |unix_seconds| {
            history.record(Sample {
                unix_seconds,
                ..Sample::default()
            })
        };
        for now in 0..=121 {
            record(now);
        }
        let snapshot = to_value(history.snapshot(121)).unwrap();
        assert_eq!(snapshot.as_array().unwrap().len(), 121);
        assert_eq!(snapshot[0], json!({"unixSeconds": 1}));
        assert_eq!(
            to_value(history.snapshot(3720))
                .unwrap()
                .as_array()
                .unwrap()
                .len(),
            2
        );
        assert_eq!(
            to_value(ResourceHistory::default().snapshot(3720)).unwrap(),
            json!([])
        );
        record(3721);
        record(2);
        assert_eq!(
            to_value(history.snapshot(2)).unwrap(),
            json!([{"unixSeconds": 2}])
        );
    }

    #[test]
    fn emits_real_counter_deltas_and_omits_missing_readings() {
        let mut sampler = linux::Sampler::default();
        let first = sampler.sample(10, "cpu 1 0 0 4 0 0 0 0", "", "", "", None);
        assert_eq!(to_value(first).unwrap(), json!({"unixSeconds": 10}));
        let next = sampler.sample(
            40,
            "cpu 2 0 0 5 2 0 0 0 50 100",
            "MemTotal: 16 kB\nMemAvailable: 4 kB",
            "VmRSS: 2 kB",
            "0.4 0.6 1.2",
            Some(1024),
        );
        assert_eq!(
            to_value(next).unwrap(),
            json!({
                "unixSeconds": 40, "hostCPUPercent": 25.0,
                "hostAvailableBytes": 4096, "hostTotalBytes": 16384,
                "processResidentBytes": 2048, "hostLoadAverage1m": 0.4,
                "diskAvailableBytes": 1024
            })
        );
        let reset = sampler.sample(70, "cpu 1 0 0 4 0 0 0 0", "MemTotal: 0 kB", "", "NaN", None);
        assert_eq!(to_value(reset).unwrap(), json!({"unixSeconds": 70}));
    }
}
