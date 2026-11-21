use codexone_wire::{SseDecoder, SseError, SsePayload};

fn feed(
    decoder: &mut SseDecoder,
    mut chunk: &[u8],
    seen: &mut Vec<(Vec<u8>, SsePayload)>,
) -> Result<(), SseError> {
    while let Some(frame) = decoder.next_frame(&mut chunk)? {
        seen.push((frame.raw.to_vec(), frame.payload));
    }
    Ok(())
}

#[test]
fn every_split_keeps_multiline_utf8_frames_and_original_wire_bytes() {
    let comment = b": synthetic\n\n";
    let data = "event: response.output_text.delta\r\ndata: {\"type\":\"response.output_text.delta\",\r\ndata: \"delta\":\"合成文本\"}\r\n\r\n".as_bytes();
    let done = b"data: [DONE]\n\n";
    let post_done = b": trailing comment\r\n\r\n";
    let stream = [comment.as_slice(), data, done, post_done].concat();

    for split in 0..=stream.len() {
        let mut decoder = SseDecoder::default();
        let mut seen = Vec::new();
        feed(&mut decoder, &stream[..split], &mut seen).unwrap();
        feed(&mut decoder, &stream[split..], &mut seen).unwrap();
        assert_eq!(seen.len(), 4);
        assert_eq!(seen[0], (comment.to_vec(), SsePayload::Ignored));
        let SsePayload::Json(value) = &seen[1].1 else {
            panic!("expected a JSON event");
        };
        assert_eq!(seen[1].0, data);
        assert_eq!(
            value.get("delta").and_then(|delta| delta.as_str()),
            Some("合成文本")
        );
        assert_eq!(seen[2], (done.to_vec(), SsePayload::Done));
        assert_eq!(seen[3], (post_done.to_vec(), SsePayload::Ignored));
        assert!(decoder.saw_done());
        assert!(decoder.is_at_event_boundary());
        assert_eq!(decoder.finish(), Ok(()));
    }
}

#[test]
fn an_error_in_the_same_chunk_never_erases_preceding_usage() {
    let evidence = br#"data: {"usage":{"output_tokens":2,"input_tokens":3}}"#;
    let evidence = [evidence.as_slice(), b"\n\n"].concat();
    for (failure, limits, expected) in [
        (
            &b"data: {broken}\n\n"[..],
            (512, 1024),
            SseError::InvalidEvent,
        ),
        (
            &b"data: \"\xff\"\n\n"[..],
            (512, 1024),
            SseError::InvalidEvent,
        ),
        (&b"data: ["[..], (512, 1024), SseError::IncompleteEvent),
        (
            &b": 123456789012345678901234567890123456789012345678901234567890\n\n"[..],
            (evidence.len() - 2, 1024),
            SseError::EventTooLarge,
        ),
        (
            &b": comment\n\n"[..],
            (512, evidence.len()),
            SseError::ResponseTooLarge,
        ),
    ] {
        let stream = [evidence.as_slice(), failure].concat();
        for split in 0..=stream.len() {
            let mut decoder = SseDecoder::new(limits.0, limits.1);
            let mut seen = Vec::new();
            let result = feed(&mut decoder, &stream[..split], &mut seen)
                .and_then(|()| feed(&mut decoder, &stream[split..], &mut seen))
                .and_then(|()| decoder.finish());
            assert_eq!(result, Err(expected));
            let [(raw, SsePayload::Json(value))] = seen.as_slice() else {
                panic!("exactly one usage event must be observable before the error");
            };
            assert_eq!(*raw, evidence);
            assert_eq!(
                value.get("usage").unwrap().encode(false),
                br#"{"output_tokens":2,"input_tokens":3}"#,
            );
        }
    }
}

#[test]
fn done_rejects_more_data_and_eof_only_checks_the_boundary() {
    let mut decoder = SseDecoder::default();
    let mut chunk = &b"data: 0\n\ndata: [DONE]\n\ndata: \n\ndata: {}\n\n"[..];
    assert!(matches!(
        decoder.next_frame(&mut chunk).unwrap().unwrap().payload,
        SsePayload::Json(_),
    ));
    assert!(!decoder.saw_done());
    assert_eq!(decoder.finish(), Ok(()));
    assert_eq!(
        decoder.next_frame(&mut chunk).unwrap().unwrap().payload,
        SsePayload::Done
    );
    assert_eq!(
        decoder.next_frame(&mut chunk).unwrap().unwrap().payload,
        SsePayload::Ignored
    );
    assert!(decoder.saw_done());
    assert_eq!(decoder.next_frame(&mut chunk), Err(SseError::InvalidEvent));
}

#[test]
fn limits_count_payload_and_cumulative_framing_at_exact_boundaries() {
    let mut decoder = SseDecoder::new(7, 11);
    let mut chunk = &b"data: 1\r\n\r\n"[..];
    assert!(decoder.next_frame(&mut chunk).unwrap().is_some());
    assert!(chunk.is_empty());
    assert_eq!(decoder.finish(), Ok(()));
    assert_eq!(
        decoder.next_frame(&mut &b"x"[..]),
        Err(SseError::ResponseTooLarge)
    );

    let mut decoder = SseDecoder::new(6, 11);
    assert_eq!(
        decoder.next_frame(&mut &b"data: 1\r\n\r\n"[..]),
        Err(SseError::EventTooLarge)
    );

    let mut decoder = SseDecoder::new(0, 16);
    assert!(decoder.next_frame(&mut &b"\n\n"[..]).unwrap().is_some());
    assert!(decoder.next_frame(&mut &b"abcd"[..]).unwrap().is_none());
    assert_eq!(
        decoder.next_frame(&mut &b"e"[..]),
        Err(SseError::EventTooLarge)
    );
    assert!(!decoder.is_at_event_boundary());
}

#[test]
fn only_baseline_blank_line_delimiters_dispatch() {
    for incomplete in [b"data: 1\r\r".as_slice(), b"data: 1\n\r\n"] {
        let mut decoder = SseDecoder::default();
        assert_eq!(decoder.next_frame(&mut &incomplete[..]), Ok(None));
        assert_eq!(decoder.finish(), Err(SseError::IncompleteEvent));
    }
    let mut decoder = SseDecoder::default();
    let mut chunk = "data:\u{0301}\n\ndata: null\r\r\n\r\n".as_bytes();
    assert_eq!(
        decoder.next_frame(&mut chunk).unwrap().unwrap().payload,
        SsePayload::Ignored
    );
    assert_eq!(
        decoder.next_frame(&mut chunk).unwrap().unwrap().payload,
        SsePayload::Json(codexone_wire::JsonValue::Null)
    );

    let mut chunk =
        b": synthetic\r\r\ndata: null\n\ndata: null\r\r\nevent: synthetic\n\n".as_slice();
    assert_eq!(
        decoder.next_frame(&mut chunk).unwrap().unwrap().payload,
        SsePayload::Ignored,
    );
    assert_eq!(decoder.next_frame(&mut chunk), Err(SseError::InvalidEvent));
}

#[test]
fn batch_scanning_preserves_limit_precedence_and_unconsumed_bytes() {
    let cases = [
        // Cumulative exhaustion happens before the first byte beyond event slack.
        (
            b"abcdefghijkTAIL".as_slice(),
            7,
            11,
            11,
            SseError::ResponseTooLarge,
        ),
        (
            b"abcdefghijkTAIL".as_slice(),
            7,
            12,
            12,
            SseError::EventTooLarge,
        ),
        // A complete oversize frame fails at its delimiter, even below that slack.
        (b"abc\n\nTAIL".as_slice(), 1, 5, 5, SseError::EventTooLarge),
        (
            b"abc\n\nTAIL".as_slice(),
            1,
            4,
            4,
            SseError::ResponseTooLarge,
        ),
        // An invalid event consumes its delimiter but leaves later bytes alone.
        (
            b"data: +\r\n\r\nTAIL".as_slice(),
            64,
            64,
            11,
            SseError::InvalidEvent,
        ),
    ];
    for (stream, event_limit, total_limit, consumed, expected) in cases {
        for split in 0..=stream.len() {
            let mut decoder = SseDecoder::new(event_limit, total_limit);
            let mut first = &stream[..split];
            let mut second = &stream[split..];
            let result = match decoder.next_frame(&mut first) {
                Ok(None) => decoder.next_frame(&mut second),
                result => result,
            };
            assert_eq!(result, Err(expected), "split at {split}");
            assert_eq!(first.len() + second.len(), stream.len() - consumed);
        }
    }
}
