use codexone_responses::*;

const HOST: Rates = Rates {
    input_micros_per_million: 1_000_000,
    output_micros_per_million: 1_000_000,
};
const TEXT: UsageConfig<'static> = UsageConfig {
    host: HOST,
    image: None,
};

fn json(data: &str) -> JsonValue {
    JsonValue::decode(data.as_bytes()).unwrap()
}

fn event(stream: &mut ResponseStream<'_>, data: &str) -> Observation {
    let wire = format!("data: {data}\r\n\r\n");
    stream.next_event(&mut wire.as_bytes()).unwrap().unwrap()
}

#[test]
fn subscription_rewrite_preserves_order_and_only_strips_known_nulls() {
    let body = br#"{"z":{"b":1,"a":2},"stream":false,"input":"a/b","model":"synthetic-contract","temperature":null,"reasoning":{"effort":null,"extra":null},"text":{"format":null,"future":1},"tool_choice":null,"extension":null,"service_tier":null}"#;
    let request = Request::parse(body, Mode::Generation, None).unwrap();
    assert!(!request.stream);
    assert_eq!(request.reasoning_effort.as_deref(), Some("other"));
    assert_eq!(request.service_tier.as_deref(), Some("other"));
    let document = request
        .into_upstream_document(Contract::CodexSubscription, false)
        .unwrap();
    assert_eq!(document.encode(true), br#"{"z":{"b":1,"a":2},"stream":true,"input":[{"role":"user","content":"a\/b"}],"model":"synthetic-contract","reasoning":{"extra":null},"text":{"future":1},"extension":null,"store":false}"#);
}

#[test]
fn local_rejection_precedence_matches_subscription_contract() {
    for (body, code) in [
        (
            r#"{"model":"synthetic","input":"x","stream":"true"}"#,
            "invalid_request",
        ),
        (
            r#"{"model":"synthetic","input":"x","background":true}"#,
            "unsupported_background",
        ),
        (
            r#"{"model":"synthetic","input":"x","conversation":{},"prompt":true}"#,
            "unsupported_request",
        ),
        (
            r#"{"model":"synthetic","input":"x","previous_response_id":""}"#,
            "invalid_reference",
        ),
        (r#"{"model":"synthetic","input":null}"#, "invalid_input"),
        (
            r#"{"model":"synthetic","input":[{"type":"compaction_trigger","x":1}]}"#,
            "unsupported_compaction_trigger",
        ),
        (
            r#"{"model":"synthetic","input":[{"type":"additional_tools","tools":[{"type":"namespace","tools":[{"type":"image_generation"}]}]}]}"#,
            "unsupported_tools",
        ),
    ] {
        assert_eq!(
            Request::parse(body.as_bytes(), Mode::Generation, None)
                .unwrap_err()
                .code,
            code
        );
    }
    let body = br#"{"model":"synthetic","input":"x","previous_response_id":"resp_test","store":true,"temperature":0,"max_output_tokens":1}"#;
    let request = Request::parse(body, Mode::Generation, None).unwrap();
    let error = request
        .validate_contract(Contract::CodexSubscription, false)
        .unwrap_err();
    assert_eq!(
        error,
        ProtocolError::new(400, "unsupported_backend_parameter")
            .with_detail("backend_parameter_max_output_tokens")
    );
    let independent = Request::parse(body, Mode::Compact, None).unwrap();
    assert_eq!(
        independent
            .into_upstream_document(Contract::CodexSubscription, false)
            .unwrap()
            .encode(true),
        body
    );

    let previous = br#"{"model":"synthetic","input":"x","previous_response_id":"resp_test"}"#;
    let request = Request::parse(previous, Mode::Generation, None).unwrap();
    assert_eq!(
        request
            .validate_contract(Contract::CodexSubscription, false)
            .unwrap_err()
            .detail,
        Some("backend_parameter_previous_response_id")
    );
    assert!(
        request
            .validate_contract(Contract::CodexSubscription, true)
            .is_ok()
    );
    assert!(validate_request_media_type(&["Application/JSON; charset=UTF-8"], &[]).is_ok());
    assert!(validate_request_media_type(&["application/json", "application/json"], &[]).is_err());
    assert!(validate_request_media_type(&["application/json"], &["identity"]).is_err());
}

#[test]
fn distinct_references_and_affinity_hints_cannot_grant_each_other() {
    let request = Request::parse(br#"{"model":"synthetic","previous_response_id":"resp_a","input":[{"type":"item_reference","id":"i_owned"},{"id":"local","content":[{"type":"extension","x":{"type":"input_image"}}]},{"type":"reasoning","id":"local_reason","encrypted_content":"abc"},{"type":"function_call_output","id":"local_result","call_id":"call_a"},{"type":"future","id":"i_owned"},{"type":"additional_tools","id":"local_package"},{"type":"compaction_trigger"}]}"#, Mode::Generation, None).unwrap();
    assert!(request.vision_input);
    assert!(request.uses_responses_lite);
    assert_eq!(request.mode, Mode::Compact);
    assert!(request.stream_compaction);
    assert_eq!(
        request
            .references
            .iter()
            .map(|ref_| (ref_.kind, ref_.raw_id.as_str()))
            .collect::<Vec<_>>(),
        [
            (BindingKind::Response, "resp_a"),
            (BindingKind::Item, "i_owned")
        ]
    );
    assert_eq!(
        request
            .affinity_hints
            .iter()
            .map(|hint| (hint.kind, hint.raw_id.as_str()))
            .collect::<Vec<_>>(),
        [
            (
                BindingKind::ReasoningContext,
                "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
            ),
            (BindingKind::FunctionCall, "call_a")
        ]
    );
    let items = request.document().get("input").unwrap().as_array().unwrap();
    for i in [1, 2, 3, 5] {
        assert!(items[i].get("id").is_none());
    }
    assert_eq!(
        items[0].get("id").and_then(JsonValue::as_str),
        Some("i_owned")
    );
    assert_eq!(
        request
            .validate_contract(Contract::CodexSubscription, false)
            .unwrap_err()
            .detail,
        Some("backend_parameter_previous_response_id")
    );
}

#[test]
fn turn_state_and_model_permissions_are_bound_to_trusted_configuration() {
    let body = br#"{"model":"synthetic","input":"x","client_metadata":{"x-codex-turn-state":"state"},"reasoning":{"effort":"high"}}"#;
    let request = Request::parse(body, Mode::Generation, None).unwrap();
    let document = request.document();
    assert_eq!(
        request_turn_state(&["state"], &[], document),
        Ok(Some("state"))
    );
    assert_eq!(
        request_turn_state(&["other"], &[], document)
            .unwrap_err()
            .code,
        "conflicting_turn_state"
    );
    assert_eq!(
        request_turn_state(&["state"], &["close,X-CODEX-TURN-STATE"], document)
            .unwrap_err()
            .code,
        "invalid_turn_state"
    );
    let policy = ModelPolicy {
        id: "synthetic",
        vision_input: false,
        image_generation: false,
        effective_image_models: &[],
        effective_reasoning_efforts: &["medium", "high"],
        restrict_reasoning_effort: true,
        key_reasoning_efforts: Some(&["medium"]),
    };
    assert_eq!(
        policy.validate(&request).unwrap_err().code,
        "reasoning_effort_not_allowed"
    );
    assert!(
        ModelPolicy {
            key_reasoning_efforts: None,
            ..policy
        }
        .validate(&request)
        .is_ok()
    );
}

#[test]
fn swift_fixture_replays_as_sse_and_terminal_json() {
    // Existing synthetic fixture used by verify_text_contract.py against the Swift service.
    let fixture = JsonValue::decode(include_bytes!(
        "../../../Tests/CodexOneAdaptersTests/Fixtures/provider-text-contract.json"
    ))
    .unwrap();
    let provider = fixture.get("events").unwrap().as_array().unwrap();
    let mut wire = Vec::new();
    for item in provider {
        // Framer must interpret the JSON type, independent of the upstream event line.
        wire.extend(b": fixture\r\nevent: provider.hint\r\ndata: ");
        wire.extend(item.encode(false));
        wire.extend(b"\r\n\r\n");
    }
    let expected_terminal = provider.last().unwrap().get("response").unwrap();
    for streaming in [false, true] {
        let mut stream = ResponseStream::new(streaming, TEXT);
        let mut seen = 0;
        for mut chunk in wire.chunks(31) {
            while let Some(observation) = stream.next_event(&mut chunk).unwrap() {
                let delivery = observation.result.unwrap();
                let document = delivery.document.as_ref();
                if seen + 1 == provider.len() {
                    assert_eq!(delivery.terminal, Some(Terminal::Completed));
                    let [usage] = observation.usage.as_slice() else {
                        panic!("terminal usage")
                    };
                    assert_eq!(
                        (
                            usage.input_tokens,
                            usage.output_tokens,
                            usage.estimated_micros
                        ),
                        (5, 3, 8)
                    );
                    assert_eq!(usage.completeness, Completeness::Complete);
                    assert_eq!(
                        delivery
                            .bindings
                            .iter()
                            .map(|binding| binding.raw_id.as_str())
                            .collect::<Vec<_>>(),
                        ["resp_contract_1", "msg_contract_1"]
                    );
                    if !streaming {
                        assert_eq!(document, Some(expected_terminal));
                    }
                } else {
                    assert!(observation.usage.is_empty());
                    if !streaming {
                        assert!(document.is_none());
                    }
                }
                if streaming {
                    let frame = encode_sse_event(document.unwrap()).unwrap();
                    let tag = format!("event: {}\ndata: ", event_type(&provider[seen]).unwrap());
                    assert_eq!(
                        frame,
                        [tag.as_bytes(), &provider[seen].encode(true), b"\n\n"].concat()
                    );
                }
                seen += 1;
            }
        }
        assert_eq!(seen, provider.len());
        assert_eq!(stream.finish(), Ok(()));
    }
    let observed = observe_json(&expected_terminal.encode(true), TEXT, false);
    assert_eq!(
        observed.result.unwrap().document.as_ref(),
        Some(expected_terminal)
    );
    assert_eq!(observed.usage[0].estimated_micros, 8);
}

#[test]
fn streaming_extensions_and_foreign_events_do_not_grant_evidence() {
    let mut stream = ResponseStream::new(true, TEXT);
    let extension = r#"{"type":"synthetic.future","item_id":"foreign","item":{"id":"bad"},"usage":{"input_tokens":9999}}"#;
    let observed = event(&mut stream, extension);
    assert!(observed.usage.is_empty());
    let delivery = observed.result.unwrap();
    assert_eq!(delivery.progress, Progress::None);
    assert!(delivery.bindings.is_empty());
    assert_eq!(delivery.document, Some(json(extension)));

    let observed = event(
        &mut stream,
        r#"{"type":"response.created","response":{"id":"right","usage":{"input_tokens":9999}}}"#,
    );
    assert_eq!(observed.result.unwrap().progress, Progress::Acknowledgement);
    assert!(observed.usage.is_empty());
    let foreign =
        r#"{"type":"response.completed","response":{"id":"wrong","usage":{"input_tokens":9999}}}"#;
    let observed = event(&mut stream, foreign);
    assert!(observed.usage.is_empty());
    assert_eq!(
        observed.result,
        Err(EventFailure::Protocol(ProtocolError::new(
            502,
            "invalid_upstream_turn"
        )))
    );
}

#[test]
fn first_event_refusal_only_yields_zero_before_activity() {
    let raw = r#"{"type":"error","status":429,"error":{"code":"usage_limit_reached","message":"Email synthetic@example.test and acct_synthetic","account_id":"synthetic-secret","resets_in_seconds":7200},"headers":{"Retry-After":"012","X-Private":"synthetic-secret"}}"#;
    for early in [true, false] {
        let mut stream = ResponseStream::new(true, TEXT);
        if !early {
            let _ = event(&mut stream, r#"{"type":"synthetic.unknown"}"#);
        }
        let observed = event(&mut stream, raw);
        assert_eq!(observed.usage.len(), usize::from(early));
        if early {
            assert!(observed.usage[0].provider_rejected_before_output);
            assert_eq!(observed.usage[0].input_tokens, 0);
        }
        let Err(EventFailure::Provider(failure)) = observed.result else {
            panic!("provider failure")
        };
        assert_eq!(failure.protocol.status, 429);
        assert_eq!(failure.client_retry_after.as_deref(), Some("012"));
        assert_eq!(failure.cooldown_seconds, Some(3600));
        assert_eq!(stream_error_event(failure.protocol, Some(&failure), "ref").encode(true),
            br#"{"type":"response.failed","response":{"status":"failed","error":{"code":"usage_limit_reached","message":"Email [redacted] and [redacted]","resets_in_seconds":7200,"type":"invalid_request_error","request_id":"ref","headers":{"retry-after":"012"}}}}"#);
    }
    let failure = http_provider_failure(
        401,
        Some(br#"{"error":{"code":"invalid_api_key","message":"synthetic secret"}}"#),
        &["12"],
        &[],
        false,
    );
    assert!(failure.provider_error.is_none());
    assert!(failure.client_retry_after.is_none());
    assert!(failure.http_rejection_usage(false).is_some());
}

#[test]
fn streaming_termination_distinguishes_done_and_trailing_frame_failure() {
    let mut stream = ResponseStream::new(true, TEXT);
    let mut done = DONE_FRAME;
    assert!(stream.next_event(&mut done).unwrap().is_none());
    assert_eq!(stream.finish().unwrap_err().code, "execution_indeterminate");

    let mut stream = ResponseStream::new(true, TEXT);
    let mut bytes = &b"data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_a\"}}\n\ndata: invalid\n\n"[..];
    assert_eq!(
        stream
            .next_event(&mut bytes)
            .unwrap()
            .unwrap()
            .result
            .unwrap()
            .terminal,
        Some(Terminal::Completed)
    );
    assert_eq!(stream.finish(), Ok(()));
    assert_eq!(bytes, b"data: invalid\n\n");
    assert!(validate_upstream_media_type(None, true).is_ok());
    assert_eq!(
        validate_upstream_media_type(Some("application/json"), true)
            .unwrap_err()
            .detail,
        Some("upstream_media_type_json")
    );
}

#[test]
fn incomplete_and_compact_outcomes_preserve_their_distinct_evidence() {
    let mut stream = ResponseStream::new(false, TEXT);
    let observed = event(
        &mut stream,
        r#"{"type":"response.incomplete","response":{"id":"resp_a","incomplete_details":{"reason":"max_output_tokens"},"service_tier":"flex","usage":{"input_tokens":10,"output_tokens":1,"input_tokens_details":{"cached_tokens":100,"future":5},"output_tokens_details":{"reasoning_tokens":"bad"},"total_tokens":-1,"future":7}}}"#,
    );
    let delivery = observed.result.unwrap();
    assert_eq!(
        delivery.terminal,
        Some(Terminal::Incomplete(IncompleteReason::MaxOutputTokens))
    );
    assert_eq!(delivery.actual_service_tier.as_deref(), Some("flex"));
    assert_eq!(observed.usage[0].cached_tokens, 0);
    assert_eq!(observed.usage[0].completeness, Completeness::Partial);
    assert_eq!(delivery.document.unwrap().get("usage").unwrap().encode(true),
        br#"{"input_tokens":10,"output_tokens":1,"input_tokens_details":{"cached_tokens":100,"future":5},"output_tokens_details":{},"future":7}"#);

    let raw = br#"{"object":"response.compaction","id":"cmp_a","output":[{"type":"compaction","id":"i_a","encrypted_content":"abc"}],"error":{"extension":true},"usage":{"input_tokens":10,"total_tokens":-1}}"#;
    let compact = observe_json(raw, TEXT, true);
    let delivery = compact.result.unwrap();
    assert_eq!(delivery.terminal, None);
    assert_eq!(
        delivery
            .bindings
            .iter()
            .map(|binding| binding.kind)
            .collect::<Vec<_>>(),
        [
            BindingKind::Compaction,
            BindingKind::Item,
            BindingKind::CompactionContext
        ]
    );
    assert_eq!(delivery.document.unwrap().encode(true), raw);
    assert_eq!(compact.usage[0].input_tokens, 10);
}

#[test]
fn image_host_and_render_evidence_survives_invalid_output() {
    let images = Some(ImageModels {
        default_model: "synthetic-image",
        allowed_models: &["synthetic-image"],
    });
    let body = br#"{"model":"synthetic","input":"x","tools":[{"type":"image_generation","output_format":"svg"}],"max_output_tokens":5,"previous_response_id":"resp_a"}"#;
    let request = Request::parse(body, Mode::Generation, images).unwrap();
    assert_eq!(request.image_model.as_deref(), Some("synthetic-image"));
    assert!(request.expects_svg);
    let upstream = request
        .into_upstream_document(Contract::CodexSubscription, false)
        .unwrap();
    assert!(upstream.get("previous_response_id").is_some());
    assert!(upstream.get("max_output_tokens").is_some());

    let usage = UsageConfig {
        image: Some(ImageUsageConfig {
            rates: HOST,
            expects_svg: true,
            author_rates: &[("synthetic-author", HOST)],
        }),
        ..TEXT
    };
    let mut stream = ResponseStream::new(true, usage);
    let observed = event(
        &mut stream,
        r#"{"type":"response.completed","response":{"id":"resp_img","status":"completed","usage":{"input_tokens":5,"output_tokens":3,"input_tokens_details":{"cached_tokens":0}},"svg_usage":{"model":"synthetic-author","input_tokens":2,"output_tokens":1,"total_tokens":3},"output":[{"type":"image_generation_call","status":"completed","result":"invalid=","usage":{"input_tokens":1,"output_tokens":4}}]}}"#,
    );
    let [host, combined] = observed.usage.as_slice() else {
        panic!("usage revisions missing")
    };
    assert_eq!((host.revision, host.estimated_micros), (0, 8));
    assert_eq!((combined.revision, combined.estimated_micros), (1, 16));
    assert_eq!((combined.input_tokens, combined.output_tokens), (5, 3));
    assert_eq!(
        (combined.image_input_tokens, combined.image_output_tokens),
        (Some(1), Some(4))
    );
    assert_eq!(
        (combined.svg_input_tokens, combined.svg_output_tokens),
        (Some(2), Some(1))
    );
    assert_eq!(
        observed.result,
        Err(EventFailure::Protocol(ProtocolError::new(
            502,
            "invalid_upstream_image"
        )))
    );
}

#[test]
fn image_masks_check_png_alpha_dimensions_and_chunk_integrity() {
    use base64::{Engine, engine::general_purpose::STANDARD};

    fn chunk(bytes: &mut Vec<u8>, kind: &[u8; 4], data: &[u8]) {
        bytes.extend((data.len() as u32).to_be_bytes());
        let start = bytes.len();
        bytes.extend(kind);
        bytes.extend(data);
        bytes.extend(crc32fast::hash(&bytes[start..]).to_be_bytes());
    }

    fn image(width: u32, color: u8, damage_crc: bool) -> String {
        let mut png = b"\x89PNG\r\n\x1a\n".to_vec();
        let mut header = width.to_be_bytes().to_vec();
        header.extend(1u32.to_be_bytes());
        header.extend([8, color, 0, 0, 0]);
        chunk(&mut png, b"IHDR", &header);
        // The boundary validates container integrity without decoding raster data.
        chunk(&mut png, b"IDAT", &[1]);
        chunk(&mut png, b"IEND", &[]);
        if damage_crc {
            *png.last_mut().unwrap() ^= 1;
        }
        format!("data:image/png;base64,{}", STANDARD.encode(png))
    }

    let input = image(2, 2, false);
    let configuration = Some(ImageModels {
        default_model: "synthetic-image",
        allowed_models: &["synthetic-image"],
    });
    for (mask, expected) in [
        (image(2, 6, false), None),
        (image(3, 6, false), Some("invalid_image_mask")),
        (image(2, 2, false), Some("invalid_image_mask")),
        (image(2, 6, true), Some("invalid_image")),
    ] {
        let body = format!(
            r#"{{"model":"synthetic","input":[{{"type":"input_image","image_url":"{input}"}}],"tools":[{{"type":"image_generation","input_image_mask":{{"image_url":"{mask}"}}}}]}}"#
        );
        let parsed = Request::parse(body.as_bytes(), Mode::Generation, configuration);
        assert_eq!(parsed.as_ref().err().map(|error| error.code), expected);
        if let Ok(request) = parsed {
            assert!(request.vision_input);
            assert_eq!(request.image_model.as_deref(), Some("synthetic-image"));
        }
    }
}

#[test]
fn retry_advice_checks_imf_fixdate_case_weekday_and_hop_by_hop() {
    for (header, valid) in [
        ("Wed, 31 Dec 1969 23:59:59 GMT", true),
        ("Thu, 01 Jan 1970 00:00:00 GMT", true),
        ("Sat, 01 Jan 0001 00:00:00 GMT", true),
        ("Fri, 01 Jan 1970 00:00:00 GMT", false),
        ("Thu, 01 jan 1970 00:00:00 GMT", false),
        ("Thu, 01 Jan 1970 00:00:60 GMT", false),
    ] {
        let failure = http_provider_failure(429, None, &[header], &[], false);
        assert_eq!(
            failure.client_retry_after.as_deref(),
            valid.then_some(header)
        );
        assert_eq!(failure.cooldown_seconds, None);
    }
    let failure = http_provider_failure(429, None, &["40"], &["close, retry-after"], false);
    assert_eq!(failure.client_retry_after, None);
    assert_eq!(failure.cooldown_seconds, Some(40));
}
