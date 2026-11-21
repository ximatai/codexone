use codexone_wire::SseDecoder;
use std::{hint::black_box, time::Instant};

const TRIALS: usize = 7;
const CHUNK_BYTES: usize = 65_536;

fn measure(name: &str, stream: &[u8], frames: usize, repetitions: usize) {
    let run = || {
        let mut decoder = SseDecoder::new(stream.len(), stream.len());
        let mut count = 0;
        for mut chunk in black_box(stream).chunks(CHUNK_BYTES) {
            while let Some(frame) = decoder.next_frame(&mut chunk).unwrap() {
                black_box(frame);
                count += 1;
            }
        }
        decoder.finish().unwrap();
        assert_eq!(count, frames);
    };
    run();
    let mut measurements = [0.0; TRIALS];
    for time_per_stream in &mut measurements {
        let start = Instant::now();
        for _ in 0..repetitions {
            run();
        }
        *time_per_stream = start.elapsed().as_secs_f64() / repetitions as f64;
    }
    measurements.sort_by(f64::total_cmp);
    let median = measurements[TRIALS / 2];
    let mib_per_second = stream.len() as f64 / median / (1024.0 * 1024.0);
    println!(
        "{name} bytes={} frames={frames} median_ms={:.3} MiB/s={mib_per_second:.1}",
        stream.len(),
        median * 1000.0
    );
}

fn main() {
    let mut large_event = br#"data: {"type":"response.output_text.delta","delta":""#.to_vec();
    large_event.resize(large_event.len() + 4 * 1024 * 1024, b'x');
    large_event.extend_from_slice(b"\"}\r\n\r\n");
    measure("large_event", &large_event, 1, 20);

    const PAIRS: usize = 32_768;
    let small_frames = b": synthetic\n\ndata: {\"usage\":{\"output_tokens\":2}}\n\n".repeat(PAIRS);
    measure("dense_small_frames", &small_frames, 2 * PAIRS, 20);
}
