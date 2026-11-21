use std::{future::Future, time::Duration};

use base64::{Engine, engine::general_purpose::STANDARD};
use codexone_http_upstream::{Bytes, ExchangeOptions, HttpUpstream, Instant};
use codexone_images::{
    ExecutionOutcome, ImageEvidence, ImageExchange, ImageOutput, ImageRates, ImageRequest,
    ImageRoute, MAX_RESPONSE_BYTES, PriceCompleteness, TokenRates, UsageCompleteness,
};
use codexone_wire::JsonValue;
use http::{HeaderMap, Method, Uri};
use tokio::{
    io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader},
    net::{TcpListener, TcpStream},
    task::JoinHandle,
    time::{sleep, timeout},
};

const PNG: &str = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGMQUDBgAAABBQBh3ab18QAAAABJRU5ErkJggg==";
const JSON: &str = "application/json";
const SSE: &str = "text/event-stream";
const GENERATION: &str = "/v1/images/generations";
const CASE_DEADLINE: Duration = Duration::from_secs(8);

const RATES: ImageRates<'static> = ImageRates {
    render: TokenRates {
        input_micros_per_million: 2_000_000,
        output_micros_per_million: 3_000_000,
    },
    authors: &[(
        "synthetic-author",
        TokenRates {
            input_micros_per_million: 500_000,
            output_micros_per_million: 1_000_000,
        },
    )],
};

fn options() -> ExchangeOptions {
    let mut options = ExchangeOptions::new(
        Instant::now() + CASE_DEADLINE,
        Duration::from_secs(3),
        MAX_RESPONSE_BYTES,
    );
    options.upload_idle_timeout = Some(Duration::from_secs(4));
    options.response_idle_timeout = Some(Duration::from_secs(4));
    options
}

fn headers(media: &str) -> HeaderMap {
    let mut headers = HeaderMap::new();
    headers.insert("content-type", media.parse().unwrap());
    headers.insert("authorization", "Bearer synthetic-client".parse().unwrap());
    headers.insert(
        "chatgpt-account-id",
        "synthetic-untrusted-account".parse().unwrap(),
    );
    headers.insert(
        "x-openai-actor-authorization",
        "synthetic-gate".parse().unwrap(),
    );
    headers.insert(
        "x-codex-image-turn-id",
        "synthetic-image-turn".parse().unwrap(),
    );
    headers.insert(
        "x-codex-turn-state",
        "synthetic-inbound-state".parse().unwrap(),
    );
    headers.insert("cookie", "synthetic=private".parse().unwrap());
    headers.insert("connection", "x-codex-drop".parse().unwrap());
    headers.insert("x-codex-drop", "synthetic-hop".parse().unwrap());
    headers
}

async fn start(
    port: &Uri,
    route: &str,
    media: &str,
    body: impl Into<Bytes>,
    options: ExchangeOptions,
) -> Result<ImageExchange<'static>, codexone_images::ImageError> {
    let headers = headers(media);
    let request = ImageRequest::parse(
        ImageRoute::from_path(route).unwrap(),
        &Method::POST,
        &headers,
        body.into(),
        Some("synthetic-image"),
        &["synthetic-image"],
        &options.cancellation,
    )?;
    let mut account = HeaderMap::new();
    account.insert(
        "authorization",
        "Bearer synthetic-upstream".parse().unwrap(),
    );
    ImageExchange::start(
        request,
        &HttpUpstream::default(),
        port,
        &headers,
        &account,
        options,
        RATES,
    )
    .await
}

async fn loopback<F, W>(serve: F) -> (Uri, JoinHandle<()>)
where
    F: FnOnce(BufReader<TcpStream>) -> W + Send + 'static,
    W: Future<Output = ()> + Send,
{
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = format!("http://{}/synthetic-base", listener.local_addr().unwrap())
        .parse()
        .unwrap();
    let task = tokio::spawn(async move {
        let (socket, _) = listener.accept().await.unwrap();
        serve(BufReader::new(socket)).await;
        assert!(
            timeout(Duration::from_millis(25), listener.accept())
                .await
                .is_err(),
            "request was replayed"
        );
    });
    (port, task)
}

async fn finish(server: JoinHandle<()>) {
    timeout(CASE_DEADLINE, server).await.unwrap().unwrap();
}

async fn read_headers(peer: &mut BufReader<TcpStream>) -> String {
    let mut headers = String::new();
    loop {
        let mut line = String::new();
        assert_ne!(peer.read_line(&mut line).await.unwrap(), 0);
        if line == "\r\n" {
            break;
        }
        headers.push_str(&line);
    }
    headers
}

fn body_size(headers: &str) -> usize {
    headers
        .lines()
        .find_map(|line| line.strip_prefix("content-length: "))
        .unwrap()
        .parse()
        .unwrap()
}

async fn read_request(peer: &mut BufReader<TcpStream>) -> (String, Vec<u8>) {
    let headers = read_headers(peer).await;
    let mut body = vec![0; body_size(&headers)];
    peer.read_exact(&mut body).await.unwrap();
    (headers, body)
}

async fn write_headers(
    peer: &mut BufReader<TcpStream>,
    status: u16,
    media: &str,
    length: usize,
    extra: &str,
) {
    let head = format!(
        "HTTP/1.1 {status} Synthetic\r\nContent-Type: {media}\r\nContent-Length: {length}\r\nx-codex-imagegen-request-id: synthetic-provider-request\r\nx-codex-turn-state: synthetic-provider-state\r\nset-cookie: synthetic=private\r\n{extra}\r\n"
    );
    peer.write_all(head.as_bytes()).await.unwrap();
}

async fn reply(peer: &mut BufReader<TcpStream>, status: u16, media: &str, body: &[u8]) {
    write_headers(peer, status, media, body.len(), "").await;
    peer.write_all(body).await.unwrap();
}

async fn begin(exchange: &mut ImageExchange<'_>) -> HeaderMap {
    match exchange.next().await {
        Ok(Some(ImageOutput::Begin(headers))) => headers,
        Err(error) => panic!("reply did not commit: {error:?}"),
        _ => panic!("expected response headers"),
    }
}

async fn read_body(exchange: &mut ImageExchange<'_>) -> Vec<u8> {
    let mut all = Vec::new();
    while let Some(output) = exchange.next().await.unwrap() {
        let ImageOutput::Body(body) = output else {
            panic!("headers sent again")
        };
        all.extend_from_slice(&body);
    }
    all
}

fn complete(image: &str, usage: &str) -> String {
    format!(
        r#"{{"created":1,"future":true,"service_tier":"default","data":[{{"b64_json":"{image}"}}],"usage":{usage}}}"#
    )
}

fn usage(input: i64, output: i64) -> String {
    format!(
        r#"{{"input_tokens":{input},"output_tokens":{output},"input_tokens_details":{{"text_tokens":1,"image_tokens":1}}}}"#
    )
}

#[tokio::test]
async fn generation_sends_original_bytes_and_maps_usage_under_both_prefixes() {
    const RAW: &[u8] = br#"{ "prompt":"synthetic", "service_tier":"priority", "model":"synthetic-image", "future":{"b":5,"a":2} }"#;
    for route in [GENERATION, "/backend-api/codex/images/generations"] {
        let body = complete(PNG, &usage(2, 3));
        let expected = body.clone();
        let (port, server) = loopback(move |mut peer| async move {
            let (heads, body_in) = read_request(&mut peer).await;
            assert!(heads.starts_with("POST /backend-api/codex/images/generations HTTP/1.1\r\n"));
            assert!(heads.contains("accept: application/json\r\n"));
            assert!(heads.contains("authorization: Bearer synthetic-upstream\r\n"));
            assert!(heads.contains("x-codex-image-turn-id: synthetic-image-turn\r\n"));
            assert!(heads.contains("x-codex-turn-state: synthetic-inbound-state\r\n"));
            for missing in [
                "chatgpt-account-id",
                "x-openai-actor-authorization",
                "cookie",
                "x-codex-drop",
                "content-encoding",
            ] {
                assert!(!heads.contains(missing), "{heads}");
            }
            assert_eq!(body_in, RAW);
            reply(&mut peer, 200, JSON, body.as_bytes()).await;
        })
        .await;
        let mut exchange = start(&port, route, JSON, RAW, options()).await.unwrap();
        let reply = begin(&mut exchange).await;
        assert_eq!(
            reply["x-codex-imagegen-request-id"],
            "synthetic-provider-request"
        );
        assert_eq!(reply["x-codex-turn-state"], "synthetic-provider-state");
        assert!(!reply.contains_key("set-cookie"));
        assert_eq!(read_body(&mut exchange).await, expected.as_bytes());
        let evidence = exchange.close().await;
        assert!(
            evidence.completed
                && evidence.observed_application
                && evidence.first_event_at.is_some()
        );
        assert_eq!(evidence.actual_service_tier.as_deref(), Some("default"));
        let usage = evidence.usage.unwrap();
        assert_eq!(usage.images, 1);
        assert_eq!(
            (usage.image_input_tokens, usage.image_output_tokens),
            (Some(2), Some(3))
        );
        assert_eq!(
            (
                usage.image_input_text_tokens,
                usage.image_input_image_tokens
            ),
            (Some(1), Some(1))
        );
        assert_eq!(usage.estimated_micros, 13);
        assert_eq!(usage.completeness, UsageCompleteness::Complete);
        assert_eq!(usage.price_completeness, PriceCompleteness::Complete);
        finish(server).await;
    }
}

#[tokio::test]
async fn multipart_streaming_edit_converts_to_json_then_synthesizes_sse_after_validation() {
    let mut form = b"--synthetic\r\nContent-Disposition: form-data; name=\"image[]\"; filename=\"synthetic.png\"\r\nContent-Type: image/png\r\n\r\n".to_vec();
    form.extend(STANDARD.decode(PNG).unwrap());
    for (key, text) in [
        ("n", "2"),
        ("prompt", "synthetic edit"),
        ("stream", "true"),
        ("future", "preserved"),
    ] {
        form.extend(
            format!(
                "\r\n--synthetic\r\nContent-Disposition: form-data; name=\"{key}\"\r\n\r\n{text}"
            )
            .bytes(),
        );
    }
    form.extend(b"\r\n--synthetic--\r\n");
    let (port, server) = loopback(|mut peer| async move {
        let (head, body) = read_request(&mut peer).await;
        assert!(head.starts_with("POST /backend-api/codex/images/edits HTTP/1.1\r\n"));
        assert!(head.contains("accept: application/json\r\n"));
        let encoded = format!("data:image/png;base64,{PNG}");
        let body = JsonValue::decode(&body).unwrap();
        assert_eq!(body.get("model").unwrap().as_str(), Some("synthetic-image"));
        assert_eq!(body.get("stream").unwrap().as_bool(), Some(false));
        assert_eq!(body.get("n").unwrap().as_i64(), Some(2));
        assert_eq!(body.get("future").unwrap().as_str(), Some("preserved"));
        assert_eq!(body.get("images").unwrap().as_array().unwrap()[0].get("image_url").unwrap().as_str(), Some(encoded.as_str()));
        let reply_body = format!(r#"{{"created":1,"data":[{{"b64_json":"{PNG}"}},{{"b64_json":"Yg==","revised_prompt":"synthetic"}}],"usage":{}}}"#, usage(2, 3));
        reply(&mut peer, 200, "application/json; charset=utf-8", reply_body.as_bytes()).await;
    }).await;
    let mut exchange = start(
        &port,
        "/v1/images/edits",
        "multipart/form-data; boundary=synthetic",
        form,
        options(),
    )
    .await
    .unwrap();
    assert_eq!(begin(&mut exchange).await["content-type"], SSE);
    let data = read_body(&mut exchange).await;
    let events: Vec<_> = data
        .split(|&byte| byte == b'\n')
        .filter_map(|line| line.strip_prefix(b"data: "))
        .filter(|line| *line != b"[DONE]")
        .map(|line| JsonValue::decode(line).unwrap())
        .collect();
    assert_eq!(events.len(), 2);
    for event in &events {
        assert_eq!(
            event.get("type").unwrap().as_str(),
            Some("image_edit.completed")
        );
        assert_eq!(event.get("created_at").unwrap().as_i64(), Some(1));
    }
    assert!(events[0].get("usage").is_none());
    assert_eq!(
        events[1]
            .get("usage")
            .unwrap()
            .get("output_tokens")
            .unwrap()
            .as_i64(),
        Some(3)
    );
    assert!(data.ends_with(b"data: [DONE]\n\n"));
    let evidence = exchange.close().await;
    assert_eq!(evidence.usage.unwrap().images, 2);
    finish(server).await;
}

fn terminal(index: u64, image: &str, usage: &str, added: &str) -> String {
    format!(
        "event: image_generation.completed\r\ndata: {{\"type\":\"image_generation.completed\",\"image_index\":{index},\"created_at\":1,\"b64_json\":\"{image}\",\"usage\":{usage}{added}}}\r\n\r\n"
    )
}

#[tokio::test]
async fn stream_relay_preserves_complete_frames_and_aggregation_uses_cumulative_evidence() {
    let preview = b": synthetic comment\r\n\r\nevent: future\ndata: {\"type\":\"image_generation.future\",\"future\":true}\n\n";
    let first = terminal(
        0,
        PNG,
        &usage(3, 7),
        r#","svg_usage":{"model":"synthetic-author","input_tokens":10,"output_tokens":20,"reasoning_tokens":4}"#,
    );
    let second = terminal(
        1,
        "Yg==",
        &usage(4, 5),
        r#","svg_usage":{"model":"synthetic-author","input_tokens":1,"output_tokens":2}"#,
    );
    let payload = [
        preview.as_slice(),
        first.as_bytes(),
        second.as_bytes(),
        b"data: [DONE]\n\n",
    ]
    .concat();
    for streaming in [false, true] {
        let provided = payload.clone();
        let (port, server) = loopback(move |mut peer| async move {
            let (head, _) = read_request(&mut peer).await;
            let media = if streaming { SSE } else { JSON };
            assert!(head.contains(&format!("accept: {media}\r\n")));
            write_headers(&mut peer, 200, SSE, provided.len(), "").await;
            for bytes in provided.chunks(23) {
                peer.write_all(bytes).await.unwrap();
                tokio::task::yield_now().await;
            }
        })
        .await;
        let request = format!(r#"{{"stream":{streaming}}}"#);
        let mut exchange = start(&port, GENERATION, JSON, request, options())
            .await
            .unwrap();
        let headers = begin(&mut exchange).await;
        let result = read_body(&mut exchange).await;
        if streaming {
            assert_eq!(headers["content-type"], SSE);
            assert_eq!(result, payload);
        } else {
            assert_eq!(headers["content-type"], JSON);
            let data = JsonValue::decode(&result).unwrap();
            assert_eq!(data.get("created").unwrap().as_i64(), Some(1));
            assert_eq!(data.get("data").unwrap().as_array().unwrap().len(), 2);
            assert_eq!(
                data.get("usage")
                    .unwrap()
                    .get("output_tokens")
                    .unwrap()
                    .as_i64(),
                Some(7)
            );
        }
        let evidence = exchange.close().await;
        assert!(evidence.completed);
        let usage = evidence.usage.unwrap();
        assert_eq!(usage.revision, 3);
        assert_eq!(usage.images, 2);
        assert_eq!(
            (usage.image_input_tokens, usage.image_output_tokens),
            (Some(4), Some(7))
        );
        assert_eq!(
            (
                usage.svg_input_tokens,
                usage.svg_output_tokens,
                usage.svg_reasoning_tokens
            ),
            (Some(10), Some(20), Some(4))
        );
        assert_eq!(usage.estimated_micros, 54);
        assert_eq!(usage.completeness, UsageCompleteness::Complete);
        finish(server).await;
    }
}

#[tokio::test]
async fn bad_or_duplicate_completion_keeps_verified_usage_and_uncommitted_json() {
    for (index, image, suffix, expected, images) in [
        (0, "Yg==", "", "invalid_upstream_image", 1),
        (1, "Yh==", "", "invalid_upstream_image", 1),
        (1, "Yg==", "data: {", "incomplete_upstream_event", 2),
    ] {
        let first = terminal(0, PNG, &usage(2, 3), "");
        let second = terminal(index, image, &usage(4, 7), "");
        let (port, server) = loopback(move |mut peer| async move {
            read_request(&mut peer).await;
            let stream = format!("{first}{second}{suffix}");
            reply(&mut peer, 200, SSE, stream.as_bytes()).await;
        })
        .await;
        let mut exchange = start(&port, GENERATION, JSON, "{}", options())
            .await
            .unwrap();
        let error = exchange.next().await.err().unwrap();
        assert_eq!(error.code, expected);
        assert_eq!(error.outcome, ExecutionOutcome::Indeterminate);
        assert!(!exchange.evidence().completed);
        let observed = exchange.close().await.usage.unwrap();
        assert_eq!(observed.images, images);
        assert_eq!(observed.image_output_tokens, Some(7));
        assert_eq!(observed.completeness, UsageCompleteness::Complete);
        finish(server).await;
    }
}

#[tokio::test]
async fn provider_error_frames_are_replaced_only_after_assembly_and_zero_requires_refusal_proof() {
    let error_frame = b"data: {\"type\":\"error\",\"status\":422,\"error\":{\"type\":\"invalid_request_error\",\"code\":\"synthetic_failure\",\"param\":\"prompt\",\"message\":\"synthetic acct-private user-synthetic@example.invalid\",\"private\":\"synthetic private body\"}}\r\n\r\n";
    let preview = b"data: {\"type\":\"image_generation.partial_image\",\"b64_json\":\"YQ==\"}\n\n";
    for earlier_frame in [false, true] {
        let (port, server) = loopback(move |mut peer| async move {
            read_request(&mut peer).await;
            write_headers(
                &mut peer,
                200,
                SSE,
                error_frame.len() + if earlier_frame { preview.len() } else { 0 },
                "",
            )
            .await;
            if earlier_frame {
                peer.write_all(preview).await.unwrap();
            }
            let cut = error_frame
                .windows(12)
                .position(|segment| segment == b"acct-private")
                .unwrap()
                + 12;
            peer.write_all(&error_frame[..cut]).await.unwrap();
            sleep(Duration::from_millis(10)).await;
            peer.write_all(&error_frame[cut..]).await.unwrap();
        })
        .await;
        let mut exchange = start(&port, GENERATION, JSON, r#"{"stream":true}"#, options())
            .await
            .unwrap();
        assert_eq!(begin(&mut exchange).await["content-type"], SSE);
        if earlier_frame {
            let Some(ImageOutput::Body(frame)) = exchange.next().await.unwrap() else {
                panic!()
            };
            assert_eq!(frame, preview.as_slice());
        }
        let error = exchange
            .next()
            .await
            .err()
            .expect("the split provider error must never be forwarded");
        assert_eq!(error.status, 422);
        let downstream = error.sse("synthetic-request");
        let downstream = std::str::from_utf8(&downstream).unwrap();
        assert!(downstream.starts_with("event: error\n"));
        for retained in [
            "invalid_request_error",
            "synthetic_failure",
            "prompt",
            "[redacted]",
            "synthetic-request",
        ] {
            assert!(downstream.contains(retained));
        }
        for redacted in ["acct-private", "example.invalid", "synthetic private body"] {
            assert!(!downstream.contains(redacted));
        }
        let evidence = exchange.close().await;
        assert_eq!(evidence.usage.is_none(), earlier_frame);
        if !earlier_frame {
            assert!(evidence.usage.unwrap().provider_rejected_before_output);
        }
        finish(server).await;
    }
}

#[tokio::test]
async fn provider_4xx_headers_certify_zero_even_when_the_error_body_is_lost() {
    let (port, server) = loopback(|mut peer| async move {
        read_request(&mut peer).await;
        write_headers(&mut peer, 429, JSON, 150, "Retry-After: 9000\r\n").await;
        peer.write_all(b"{").await.unwrap();
    })
    .await;
    let mut exchange = start(&port, GENERATION, JSON, "{}", options())
        .await
        .unwrap();
    assert_eq!(exchange.upstream_status(), Some(429));
    assert!(
        exchange
            .evidence()
            .usage
            .as_ref()
            .unwrap()
            .provider_rejected_before_output
    );
    let error = exchange.next().await.err().unwrap();
    assert_eq!(error.outcome, ExecutionOutcome::RejectedBeforeOutput);
    assert_eq!(error.status, 429);
    assert_eq!(error.retry_after.as_deref(), Some("9000"));
    assert_eq!(error.account_cooldown(1), Some(3600));
    assert_eq!(
        exchange.close().await.usage.unwrap().image_output_tokens,
        Some(0)
    );
    finish(server).await;
}

#[tokio::test]
async fn json_body_validity_and_ledger_facts_are_independent() {
    for (name, body, code, images, complete_usage) in [
        (
            "invalid image",
            complete("Yh==", &usage(2, 3)),
            "invalid_upstream_image",
            0,
            true,
        ),
        (
            "failed result",
            complete(PNG, &usage(2, 3)).replace("\"created\"", "\"status\":\"failed\",\"created\""),
            "upstream_execution_failed",
            1,
            true,
        ),
        (
            "nonterminal result",
            complete(PNG, &usage(2, 3))
                .replace("\"created\"", "\"status\":\"in_progress\",\"created\""),
            "execution_indeterminate",
            1,
            false,
        ),
        (
            "wrong gif",
            complete(PNG, &usage(2, 3)),
            "invalid_upstream_image_format",
            1,
            true,
        ),
    ] {
        let (port, server) = loopback(move |mut peer| async move {
            read_request(&mut peer).await;
            reply(&mut peer, 200, JSON, body.as_bytes()).await;
        })
        .await;
        let request = if name == "wrong gif" {
            r#"{"output_format":"gif"}"#
        } else {
            "{}"
        };
        let mut exchange = start(&port, GENERATION, JSON, request, options())
            .await
            .unwrap();
        assert_eq!(exchange.next().await.err().unwrap().code, code, "{name}");
        let evidence = exchange.close().await;
        assert!(!evidence.completed, "{name}");
        let usage = evidence.usage.unwrap();
        assert_eq!(usage.images, images, "{name}");
        assert_eq!(
            usage.completeness == UsageCompleteness::Complete,
            complete_usage,
            "{name}"
        );
        assert_eq!(usage.image_output_tokens, Some(3), "{name}");
        finish(server).await;
    }
}

#[tokio::test]
async fn first_response_clock_begins_after_local_upload_even_when_provider_reads_slowly() {
    let first_response = Duration::from_millis(180);
    let (port, server) = loopback(move |mut peer| async move {
        let head = read_headers(&mut peer).await;
        let length = body_size(&head);
        assert!(length > 10 * 1024 * 1024);
        sleep(first_response * 3).await;
        let mut remaining = length;
        let mut buffer = [0; 64 * 1024];
        while remaining > 0 {
            let read = remaining.min(buffer.len());
            peer.read_exact(&mut buffer[..read]).await.unwrap();
            remaining -= read;
        }
        reply(&mut peer, 200, JSON, complete(PNG, &usage(2, 3)).as_bytes()).await;
    })
    .await;
    let request = format!(
        r#"{{"model":"synthetic-image","prompt":"{}"}}"#,
        "a".repeat(12 * 1024 * 1024)
    );
    let mut options = options();
    options.first_response_timeout = first_response;
    let mut exchange = start(&port, GENERATION, JSON, request, options)
        .await
        .unwrap();
    begin(&mut exchange).await;
    read_body(&mut exchange).await;
    assert!(exchange.close().await.completed);
    finish(server).await;
}

#[tokio::test]
async fn headers_comments_and_unknown_events_do_not_advance_first_response() {
    for streaming in [false, true] {
        let budget = Duration::from_millis(170);
        let (port, server) = loopback(move |mut peer| async move {
            read_request(&mut peer).await;
            let frame = b": synthetic comment\r\n\r\ndata: {\"type\":\"image_generation.future\",\"b64_json\":\"YQ==\"}\n\ndata: {\"type\":\"image_generation.partial_image\",\"b64_json\":\"\"}\n\n";
            write_headers(&mut peer, 200, SSE, frame.len() * 40, "").await;
            for _ in 0..40 {
                if peer.write_all(frame).await.is_err() { return; }
                sleep(Duration::from_millis(20)).await;
            }
            panic!("upstream did not close after the first-response deadline");
        }).await;
        let mut options = options();
        options.first_response_timeout = budget;
        let mut exchange = start(
            &port,
            GENERATION,
            JSON,
            format!(r#"{{"stream":{streaming}}}"#),
            options,
        )
        .await
        .unwrap();
        if streaming {
            begin(&mut exchange).await;
        }
        let error = loop {
            match exchange.next().await {
                Ok(Some(ImageOutput::Body(_))) if streaming => {}
                Err(error) => break error,
                _ => panic!("upstream produced unexpected output"),
            }
        };
        assert_eq!(error.status, 504);
        assert_eq!(error.code, "execution_first_response_timeout");
        assert!(exchange.evidence().observed_application);
        assert!(exchange.close().await.usage.is_none());
        finish(server).await;
    }
}

#[tokio::test]
async fn downstream_cancel_and_upstream_truncation_preserve_last_evidence_without_replay() {
    for downstream_cancel in [false, true] {
        let terminal = terminal(0, PNG, &usage(2, 3), "");
        let (port, server) = loopback(move |mut peer| async move {
            read_request(&mut peer).await;
            write_headers(&mut peer, 200, SSE, terminal.len() + 20, "").await;
            peer.write_all(terminal.as_bytes()).await.unwrap();
            if downstream_cancel {
                let mut probe = [0];
                assert_eq!(peer.read(&mut probe).await.unwrap(), 0);
            }
        })
        .await;
        let options = options();
        let cancel = options.cancellation.clone();
        let mut exchange = start(&port, GENERATION, JSON, r#"{"stream":true}"#, options)
            .await
            .unwrap();
        begin(&mut exchange).await;
        assert!(matches!(
            exchange.next().await.unwrap(),
            Some(ImageOutput::Body(_))
        ));
        assert_eq!(
            exchange.evidence().usage.as_ref().unwrap().completeness,
            UsageCompleteness::Partial
        );
        if downstream_cancel {
            cancel.cancel();
        }
        let error = exchange.next().await.err().unwrap();
        assert_eq!(error.outcome, ExecutionOutcome::Indeterminate);
        assert_eq!(error.code, "execution_indeterminate");
        assert_eq!(error.cancelled, downstream_cancel);
        let ImageEvidence {
            completed, usage, ..
        } = exchange.close().await;
        assert!(!completed);
        let usage = usage.unwrap();
        assert_eq!(usage.image_output_tokens, Some(3));
        assert_eq!(usage.completeness, UsageCompleteness::Complete);
        finish(server).await;
    }
}

#[tokio::test]
async fn json_response_byte_cap_is_enforced_before_begin() {
    let (port, server) = loopback(|mut peer| async move {
        read_request(&mut peer).await;
        write_headers(&mut peer, 200, JSON, MAX_RESPONSE_BYTES + 1, "").await;
        let chunk = [b' '; 64 * 1024];
        for _ in 0..MAX_RESPONSE_BYTES / chunk.len() {
            peer.write_all(&chunk).await.unwrap();
        }
        peer.write_all(b" ").await.unwrap();
    })
    .await;
    let mut exchange = start(&port, GENERATION, JSON, "{}", options())
        .await
        .unwrap();
    assert_eq!(
        exchange.next().await.err().unwrap().code,
        "upstream_response_too_large"
    );
    assert!(exchange.close().await.usage.is_none());
    finish(server).await;
}

#[tokio::test]
async fn extended_output_formats_validate_only_the_header_and_keep_missing_author_usage_partial() {
    for (format, image, completeness) in [
        (
            "gif",
            STANDARD.encode(b"GIF89a synthetic"),
            UsageCompleteness::Complete,
        ),
        (
            "svg",
            STANDARD.encode(b"\xef\xbb\xbf <?xml version=\"1.0\"?> <!-- synthetic --> <svg/>"),
            UsageCompleteness::Partial,
        ),
        (
            "synthetic-future",
            STANDARD.encode(b"synthetic opaque result"),
            UsageCompleteness::Complete,
        ),
    ] {
        let out = complete(&image, &usage(2, 3));
        let expected = out.clone();
        let (port, server) = loopback(move |mut peer| async move {
            let (head, body) = read_request(&mut peer).await;
            assert!(head.contains("accept: application/json\r\n"));
            let input = JsonValue::decode(&body).unwrap();
            assert_eq!(input.get("output_format").unwrap().as_str(), Some(format));
            assert!(input.get("stream").is_none());
            reply(&mut peer, 200, JSON, out.as_bytes()).await;
        })
        .await;
        let request = format!(r#"{{"output_format":"{format}"}}"#);
        let mut exchange = start(&port, GENERATION, JSON, request, options())
            .await
            .unwrap();
        assert_eq!(begin(&mut exchange).await["content-type"], JSON);
        assert_eq!(read_body(&mut exchange).await, expected.as_bytes());
        let usage = exchange.close().await.usage.unwrap();
        assert_eq!(usage.completeness, completeness);
        if format == "svg" {
            assert_eq!(usage.price_completeness, PriceCompleteness::Partial);
            assert!(usage.missing_reasons.contains(&"svg_input_unavailable"));
        }
        finish(server).await;
    }
}

#[tokio::test]
async fn legacy_edit_passthrough_carries_invalid_result_evidence() {
    let (port, server) = loopback(|mut peer| async move {
        read_request(&mut peer).await;
        reply(&mut peer, 200, JSON, b"synthetic invalid JSON").await;
    })
    .await;
    let mut exchange = start(
        &port,
        "/backend-api/codex/images/edits",
        JSON,
        "{}",
        options(),
    )
    .await
    .unwrap();
    assert_eq!(begin(&mut exchange).await["content-type"], JSON);
    assert_eq!(read_body(&mut exchange).await, b"synthetic invalid JSON");
    let evidence = exchange.close().await;
    assert!(evidence.invalid_legacy_result);
    assert!(!evidence.completed);
    assert!(evidence.usage.is_none());
    finish(server).await;
}

#[tokio::test]
async fn recognized_preview_switches_to_idle_deadline_without_turning_eof_into_success() {
    let preview = b"data: {\"type\":\"image_generation.partial_image\",\"b64_json\":\"YQ==\"}\n\n";
    let (port, server) = loopback(move |mut peer| async move {
        read_request(&mut peer).await;
        write_headers(&mut peer, 200, SSE, preview.len() + 50, "").await;
        peer.write_all(preview).await.unwrap();
        let mut probe = [0];
        assert_eq!(peer.read(&mut probe).await.unwrap(), 0);
    })
    .await;
    let mut options = options();
    options.first_response_timeout = Duration::from_secs(3);
    options.response_idle_timeout = Some(Duration::from_millis(100));
    let mut exchange = start(&port, GENERATION, JSON, "{}", options).await.unwrap();
    let error = exchange.next().await.err().unwrap();
    assert_eq!(error.code, "execution_progress_timeout");
    assert!(exchange.evidence().observed_application);
    assert!(exchange.close().await.usage.is_none());
    finish(server).await;
}

#[tokio::test]
async fn item_scoped_svg_evidence_remains_a_lower_bound_across_completions() {
    let (port, server) = loopback(|mut peer| async move {
        read_request(&mut peer).await;
        let stream = format!(
            concat!(
                "data: {{\"type\":\"image_generation.completed\",\"image_index\":0,\"created\":1,",
                "\"data\":[{{\"b64_json\":\"YQ==\",\"svg_usage\":{{\"model\":\"synthetic-author\",",
                "\"input_tokens\":10,\"output_tokens\":20}}}}],\"usage\":{}}}\n\n",
                "data: {{\"type\":\"image_generation.completed\",\"image_index\":1,\"created\":1,",
                "\"data\":[{{\"b64_json\":\"Yg==\"}}],\"usage\":{}}}\n\n"
            ),
            usage(2, 3),
            usage(2, 3)
        );
        reply(&mut peer, 200, SSE, stream.as_bytes()).await;
    })
    .await;
    let mut exchange = start(&port, GENERATION, JSON, "{}", options())
        .await
        .unwrap();
    begin(&mut exchange).await;
    read_body(&mut exchange).await;
    let usage = exchange.close().await.usage.unwrap();
    assert_eq!(usage.images, 2);
    assert_eq!(usage.svg_output_tokens, Some(20));
    assert_eq!(usage.completeness, UsageCompleteness::Partial);
    assert!(usage.missing_reasons.contains(&"svg_usage_ambiguous"));
    finish(server).await;
}
