use base64::{Engine, engine::general_purpose::STANDARD};
use codexone_http_upstream::{Bytes, CancellationToken};
use codexone_images::{ImageRequest, ImageRoute};
use http::{HeaderMap, HeaderValue, Method};

const PNG: &str = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGMQUDBgAAABBQBh3ab18QAAAABJRU5ErkJggg==";

fn parse(path: &str, media: &'static str, body: Bytes) -> Result<ImageRequest, &'static str> {
    let mut headers = HeaderMap::new();
    headers.insert("content-type", HeaderValue::from_static(media));
    ImageRequest::parse(
        ImageRoute::from_path(path).unwrap(),
        &Method::POST,
        &headers,
        body,
        Some("synthetic-image"),
        &["synthetic-image"],
        &CancellationToken::new(),
    )
    .map_err(|error| error.code)
}

const GENERATIONS: &str = "/v1/images/generations";
const EDITS: &str = "/v1/images/edits";

#[test]
fn checks_only_local_image_controls_and_accepts_provider_extensions() {
    let body = br#"{"model":"synthetic-image","service_tier":"priority","size":{"future":true},"quality":42,"n":-9,"future":{"b":1,"a":2},"output_format":"future", "stream":true}"#;
    let request = parse(GENERATIONS, "application/json", Bytes::from_static(body)).unwrap();
    assert_eq!(request.model(), "synthetic-image");
    assert_eq!(request.service_tier(), Some("priority"));
    assert!(request.streaming());
    let request = parse(
        GENERATIONS,
        "application/json",
        Bytes::from_static(br#"{"service_tier":null}"#),
    )
    .unwrap();
    assert_eq!(request.service_tier(), Some("other"));

    for (body, code) in [
        (
            r#"{"model":"synthetic-image","m\u006fdel":null}"#,
            "invalid_json",
        ),
        (r#"{"stream":false,"stream":true}"#, "invalid_json"),
        (r#"{"stream":"false"}"#, "invalid_request"),
        (r#"{"model":null}"#, "invalid_request"),
        (
            r#"{"model":"synthetic-other","images":false}"#,
            "model_not_allowed",
        ),
        (
            r#"{"images":["https://example.invalid/synthetic.png"]}"#,
            "invalid_image",
        ),
        (
            r#"{"images":[{"image_url":"https://example.invalid/synthetic.png"}]}"#,
            "invalid_image",
        ),
        (r#"{"mask":true}"#, "invalid_mask"),
        (
            r#"{"svg":{"model":"synthetic-author"}}"#,
            "unsupported_svg_model_selection",
        ),
        (r#"{"output_format":"gif","mask":null}"#, "invalid_mask"),
        (
            r#"{"output_format":"gif","stream":true}"#,
            "unsupported_image_format_combination",
        ),
        (
            r#"{"output_format":"gif","output_compression":null}"#,
            "unsupported_image_format_combination",
        ),
        (
            r#"{"output_format":"svg","prompt_rewriter":false}"#,
            "unsupported_image_format_combination",
        ),
        (
            r#"{"output_format":"svg","n":2}"#,
            "unsupported_image_format_combination",
        ),
    ] {
        assert_eq!(
            parse(
                GENERATIONS,
                "application/json",
                Bytes::from_static(body.as_bytes())
            )
            .err(),
            Some(code),
            "{body}"
        );
    }
    assert_eq!(
        parse(
            EDITS,
            "application/json",
            Bytes::from_static(br#"{"output_format":"svg"}"#)
        )
        .err(),
        Some("unsupported_image_format_combination")
    );
    assert!(
        parse(
            GENERATIONS,
            "application/json",
            Bytes::from_static(br#"{"output_format":"svg","n":1,"svg":null}"#)
        )
        .is_ok()
    );
    assert!(ImageRoute::from_path("/v1/unexpected/images/generations").is_none());
    assert!(ImageRoute::from_path("/v1/images/generations/").is_none());
}

#[test]
fn inline_png_jpeg_and_webp_check_container_and_declared_type() {
    let jpeg =
        include_bytes!("../../../Tests/CodexOneAdaptersTests/Fixtures/image-input/synthetic.jpg");
    let webp =
        include_bytes!("../../../Tests/CodexOneAdaptersTests/Fixtures/image-input/synthetic.webp");
    let png = STANDARD.decode(PNG).unwrap();
    for (media, bytes) in [
        ("png", png.as_slice()),
        ("jpeg", jpeg.as_slice()),
        ("webp", webp.as_slice()),
    ] {
        let guess = |bytes| {
            let body = format!(
                r#"{{"images":[{{"image_url":"data:image/{media};base64,{}"}}]}}"#,
                STANDARD.encode(bytes)
            );
            parse(EDITS, "application/json", body.into())
        };
        assert!(guess(bytes).is_ok(), "{media}");
        for length in 0..bytes.len() {
            assert!(guess(&bytes[..length]).is_err(), "{media} {length}");
        }
    }

    let wrong = format!(r#"{{"images":[{{"image_url":"data:image/jpeg;base64,{PNG}"}}]}}"#);
    assert_eq!(
        parse(EDITS, "application/json", wrong.into()).err(),
        Some("invalid_image_dimensions")
    );
    let mut broken = png;
    let check = broken.len() - 5;
    broken[check] ^= 1;
    let corrupt = format!(
        r#"{{"images":[{{"image_url":"data:image/png;base64,{}"}}]}}"#,
        STANDARD.encode(&broken)
    );
    assert_eq!(
        parse(EDITS, "application/json", corrupt.into()).err(),
        Some("invalid_image")
    );
}

#[test]
fn multipart_is_restricted_to_public_edits_and_rejects_duplicate_part_headers() {
    const MEDIA: &str = "multipart/form-data; boundary=\"synthetic\"";
    let good = Bytes::from_static(
        b"--synthetic\r\nContent-Disposition: form-data; name=\"prompt\"\r\n\r\nsynthetic\r\n--synthetic--\r\n",
    );
    assert!(parse(EDITS, MEDIA, good.clone()).is_ok());
    for route in [GENERATIONS, "/backend-api/codex/images/edits"] {
        assert_eq!(
            parse(route, MEDIA, good.clone()).err(),
            Some("unsupported_content_type")
        );
    }
    let duplicate = Bytes::from_static(
        b"--synthetic\r\nContent-Disposition: form-data; name=\"prompt\"\r\nContent-Type: text/plain\r\ncontent-type: text/plain\r\n\r\nsynthetic\r\n--synthetic--",
    );
    assert_eq!(
        parse(EDITS, MEDIA, duplicate).err(),
        Some("invalid_multipart")
    );
}

#[test]
fn encoding_and_turn_state_are_validated_on_the_original_request() {
    let route = ImageRoute::from_path(EDITS).unwrap();
    let mut headers = HeaderMap::new();
    headers.insert("content-type", "application/json".parse().unwrap());
    let parse = |method: &Method, headers: &HeaderMap| {
        ImageRequest::parse(
            route,
            method,
            headers,
            Bytes::from_static(b"{}"),
            Some("synthetic-image"),
            &["synthetic-image"],
            &CancellationToken::new(),
        )
    };
    assert_eq!(parse(&Method::GET, &headers).err().unwrap().status, 405);
    headers.insert("content-encoding", "identity".parse().unwrap());
    assert_eq!(parse(&Method::POST, &headers).err().unwrap().status, 415);
    headers.remove("content-encoding");
    headers.append("content-type", "application/json".parse().unwrap());
    assert_eq!(parse(&Method::POST, &headers).err().unwrap().status, 415);
    headers.remove("content-type");
    headers.insert("content-type", "application/json".parse().unwrap());
    headers.append("x-codex-turn-state", "synthetic".parse().unwrap());
    assert_eq!(
        parse(&Method::POST, &headers)
            .unwrap()
            .turn_state()
            .unwrap(),
        "synthetic"
    );
    headers.append("x-codex-turn-state", "second".parse().unwrap());
    assert_eq!(
        parse(&Method::POST, &headers).err().unwrap().code,
        "conflicting_turn_state"
    );
    headers.remove("x-codex-turn-state");
    headers.append("x-codex-turn-state", "synthetic".parse().unwrap());
    headers.insert(
        "connection",
        "keep-alive, x-codex-turn-state".parse().unwrap(),
    );
    assert_eq!(
        parse(&Method::POST, &headers).err().unwrap().code,
        "invalid_turn_state"
    );
}
