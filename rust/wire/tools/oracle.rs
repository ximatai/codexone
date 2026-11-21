use codexone_wire::{JsonValue, SseDecoder, SsePayload};
use std::{
    fmt::Write,
    io::{self, BufRead},
};

fn hex(bytes: &[u8]) -> String {
    let mut text = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        write!(text, "{byte:02x}").unwrap();
    }
    text
}

fn sse(data: &[u8], chunk_bytes: usize, max_event_bytes: usize, max_total_bytes: usize) -> String {
    let mut decoder = SseDecoder::new(max_event_bytes, max_total_bytes);
    let mut output = Vec::new();
    let mut consumed = 0;
    let result = (|| {
        for mut chunk in data.chunks(chunk_bytes) {
            loop {
                let available = chunk.len();
                let frame = decoder.next_frame(&mut chunk);
                consumed += available - chunk.len();
                match frame? {
                    Some(frame) => {
                        if let SsePayload::Json(value) = frame.payload {
                            output.push(hex(&value.encode(true)));
                        }
                    }
                    None => break,
                }
            }
        }
        decoder.finish()
    })();
    if let Err(error) = result {
        output.push(error.code().into());
    }
    format!(
        "{}|{}|{}|{consumed}",
        output.join(","),
        decoder.saw_done(),
        decoder.is_at_event_boundary(),
    )
}

fn main() {
    let args: Vec<_> = std::env::args().skip(1).collect();
    let mode = args.first().expect("supply json or sse").as_str();
    let options = &args[1..];
    for line in io::stdin().lock().lines() {
        let line = line.unwrap();
        let data: Vec<_> = (0..line.len())
            .step_by(2)
            .map(|offset| u8::from_str_radix(&line[offset..offset + 2], 16).unwrap())
            .collect();
        match mode {
            "json" => {
                let keys: Vec<_> = options.iter().map(String::as_str).collect();
                match JsonValue::decode_rejecting_duplicates(&data, &keys) {
                    Ok(value) => println!("{}", hex(&value.encode(false))),
                    Err(error) => println!("{}", error.code()),
                }
            }
            "sse" => {
                let [chunk_bytes, max_event_bytes, max_total_bytes] = options else {
                    panic!("supply chunk, event and total byte limits");
                };
                println!(
                    "{}",
                    sse(
                        &data,
                        chunk_bytes.parse().unwrap(),
                        max_event_bytes.parse().unwrap(),
                        max_total_bytes.parse().unwrap(),
                    )
                );
            }
            _ => panic!("unknown probe mode"),
        }
    }
}
