use codexone_wire::{JsonError, JsonObject, JsonValue, MAX_JSON_DEPTH};
use std::collections::HashMap;

#[test]
fn edits_preserve_nested_order_and_existing_member_positions() {
    let raw = br#"{"z":0,"a":{"y":1,"b":{"q":2,"c":3}},"tools":[{"parameters":{"properties":{"zeta":{},"alpha":{},"middle":{}}}}]}"#;
    let mut value = JsonValue::decode(raw).unwrap();
    assert_eq!(value.encode(true), raw);

    let object = value.as_object_mut().unwrap();
    object.insert("z", JsonValue::Number(4.into()));
    object.remove("a").unwrap();
    object.insert("new", JsonValue::Bool(true));
    assert_eq!(
        value.encode(true),
        br#"{"z":4,"tools":[{"parameters":{"properties":{"zeta":{},"alpha":{},"middle":{}}}}],"new":true}"#,
    );

    let mut object = JsonObject::from_unordered(HashMap::from([
        ("z".into(), JsonValue::Null),
        ("a".into(), JsonValue::Bool(true)),
        ("m".into(), JsonValue::Number(1.into())),
    ]));
    assert_eq!(
        JsonValue::Object(object.clone()).encode(true),
        br#"{"a":true,"m":1,"z":null}"#,
    );
    object.retain(|_, value| !matches!(value, JsonValue::Number(_)));
    assert_eq!(
        JsonValue::Object(object.clone()).encode(true),
        br#"{"a":true,"z":null}"#,
    );
    assert_eq!(
        JsonValue::Object(object),
        JsonValue::decode(br#"{"z":null,"a":true}"#).unwrap(),
    );
}

#[test]
fn first_values_win_and_duplicate_policy_applies_only_to_selected_root_keys() {
    let raw = br#"{"model":"synthetic","mo\u0064el":"ignored","nested":{"model":1,"model":[2]},"future":null,"future":{"new":1}}"#;
    assert_eq!(
        JsonValue::decode(raw).unwrap().encode(false),
        br#"{"model":"synthetic","nested":{"model":1},"future":null}"#,
    );
    assert_eq!(
        JsonValue::decode_rejecting_duplicates(raw, &["model"]),
        Err(JsonError::InvalidJson),
    );
    assert!(
        JsonValue::decode_rejecting_duplicates(
            br#"{"nested":{"model":1,"model":2},"future":1,"future":2}"#,
            &["model"]
        )
        .is_ok()
    );
    assert_eq!(
        JsonValue::decode(br#"{"z":1,"z":[1e9999,"\uD800"]}"#)
            .unwrap()
            .encode(false),
        br#"{"z":1}"#,
    );
    assert_eq!(
        JsonValue::decode(br#"{"z":1,"z":{"\uD800":1}}"#),
        Err(JsonError::InvalidJson),
    );
}

#[test]
fn canonical_unicode_comparison_preserves_received_spelling() {
    let raw = r#"{"e\u0301":{"z":1,"a":2},"é":{"x":3}}"#;
    let value = JsonValue::decode(raw.as_bytes()).unwrap();
    assert_eq!(
        value.encode(false),
        "{\"e\u{0301}\":{\"z\":1,\"a\":2}}".as_bytes()
    );
    assert_eq!(value.get("é").unwrap().get("z").unwrap().as_i64(), Some(1));
    assert_eq!(
        JsonValue::decode_rejecting_duplicates(raw.as_bytes(), &["é"]),
        Err(JsonError::InvalidJson),
    );
    assert_eq!(
        JsonValue::decode(r#"{"é":"e\u0301"}"#.as_bytes()).unwrap(),
        JsonValue::decode(r#"{"e\u0301":"é"}"#.as_bytes()).unwrap(),
    );
}

#[test]
fn accepts_swift_input_encodings_and_produces_utf8() {
    let raw = r#"{"z":{"y":1,"a":2},"合成":"😀"}"#;
    let utf16le: Vec<_> = raw.encode_utf16().flat_map(u16::to_le_bytes).collect();
    let utf16be: Vec<_> = raw.encode_utf16().flat_map(u16::to_be_bytes).collect();
    let utf32le: Vec<_> = raw
        .chars()
        .flat_map(|scalar| (scalar as u32).to_le_bytes())
        .collect();
    let utf32be: Vec<_> = raw
        .chars()
        .flat_map(|scalar| (scalar as u32).to_be_bytes())
        .collect();
    for (bom, encoded) in [
        (&b"\xef\xbb\xbf"[..], raw.as_bytes()),
        (&b"\xff\xfe"[..], &utf16le),
        (&b"\xfe\xff"[..], &utf16be),
        (&b""[..], &utf32le),
        (&b"\0\0\xfe\xff"[..], &utf32be),
    ] {
        for prefix in [bom, &[]] {
            assert_eq!(
                JsonValue::decode(&[prefix, encoded].concat())
                    .unwrap()
                    .encode(true),
                raw.as_bytes(),
            );
        }
    }
    assert_eq!(
        JsonValue::decode(&[b"\xff\xfe\0\0".as_slice(), &utf32le].concat()),
        Err(JsonError::InvalidJson),
    );

    let utf16le: Vec<_> = r#"{"output_format":"png","output_fo\u0072mat":"gif"}"#
        .encode_utf16()
        .flat_map(u16::to_le_bytes)
        .collect();
    assert_eq!(
        JsonValue::decode_rejecting_duplicates(&utf16le, &["output_format"]),
        Err(JsonError::InvalidJson),
    );
}

#[test]
fn legacy_utf32le_marker_uses_swift_fallback_order_and_checks_selected_root_keys() {
    fn legacy_utf32le(text: &str) -> Vec<u8> {
        let mut encoded = b"\xfe\xff\0\0".to_vec();
        encoded.extend(
            text.chars()
                .flat_map(|scalar| (scalar as u32).to_le_bytes()),
        );
        encoded
    }

    let raw = legacy_utf32le(
        r#"{"z":{"y":1,"b":2},"model":"synthetic","future":null,"future":[1],"a":{"model":1,"model":2}}"#,
    );
    let value = JsonValue::decode_rejecting_duplicates(&raw, &["model"]).unwrap();
    assert_eq!(
        value.encode(false),
        br#"{"a":{"model":1},"future":null,"model":"synthetic","z":{"b":2,"y":1}}"#,
    );

    let duplicate = legacy_utf32le(r#"{"z":1,"model":"synthetic","mo\u0064el":"ignored"}"#);
    assert_eq!(
        JsonValue::decode(&duplicate).unwrap().encode(false),
        br#"{"model":"synthetic","z":1}"#,
    );
    assert_eq!(
        JsonValue::decode_rejecting_duplicates(&duplicate, &["model"]),
        Err(JsonError::InvalidJson),
    );

    let mut truncated = legacy_utf32le(r#"{"z":1}"#);
    truncated.pop();
    assert_eq!(JsonValue::decode(&truncated), Err(JsonError::InvalidJson));
}

#[test]
fn depth_preflight_matches_swift_at_the_boundary() {
    for depth in [MAX_JSON_DEPTH - 1, MAX_JSON_DEPTH, MAX_JSON_DEPTH + 1] {
        let raw = format!(
            "{}0{}",
            r#"{"z":"[\"","a":"#.repeat(depth),
            "}".repeat(depth)
        );
        if depth <= MAX_JSON_DEPTH {
            assert_eq!(
                JsonValue::decode(raw.as_bytes()).unwrap().encode(true),
                raw.as_bytes()
            );
        } else {
            assert_eq!(JsonValue::decode(raw.as_bytes()), Err(JsonError::TooDeep));
        }
    }
    // This UTF-16 input exercises the separate Foundation structural cap after
    // the Swift byte preflight has misread the UTF-16 escaped quote.
    for depth in [512, 513] {
        let raw = format!(
            r#"["a\"b",{}0{}]"#,
            "[".repeat(depth - 1),
            "]".repeat(depth - 1)
        );
        let encoded: Vec<_> = raw.encode_utf16().flat_map(u16::to_le_bytes).collect();
        if depth == 512 {
            assert_eq!(
                JsonValue::decode(&encoded).unwrap().encode(false),
                raw.as_bytes()
            );
        } else {
            assert_eq!(JsonValue::decode(&encoded), Err(JsonError::InvalidJson));
        }
    }
}

#[test]
fn writer_matches_swift_decimal_and_escaping_bytes() {
    let fixtures = [
        ("1.2500", "1.25"),
        ("-0", "0"),
        ("1e30", "1000000000000000000000000000000"),
        ("1e-30", "0.000000000000000000000000000001"),
        (
            "340282366920938463463374607431768211456",
            "340282366920938463463374607431768211450",
        ),
        (
            "0.99999999999999999999999999999999999999999999",
            "0.99999999999999999999999999999999999999",
        ),
        ("{\"a\":1,}", "{\"a\":1}"),
        ("[1,]", "[1]"),
    ];
    for (raw, expected) in fixtures {
        assert_eq!(
            JsonValue::decode(raw.as_bytes()).unwrap().encode(true),
            expected.as_bytes()
        );
    }
    let string = JsonValue::decode(r#""a/b\\c\n\u0000\u001F\u2028😀""#.as_bytes()).unwrap();
    assert_eq!(
        string.encode(true),
        "\"a\\/b\\\\c\\n\\u0000\\u001f\u{2028}😀\"".as_bytes()
    );
    assert_eq!(
        string.encode(false),
        "\"a/b\\\\c\\n\\u0000\\u001f\u{2028}😀\"".as_bytes()
    );

    for integer in [i64::MIN, 0, 10, i64::MAX] {
        let value = JsonValue::decode(integer.to_string().as_bytes()).unwrap();
        assert_eq!(value.as_i64(), Some(integer));
        assert_eq!(value, JsonValue::Number(integer.into()));
    }
    for raw in ["9223372036854775808", "0.1", "1e100", "true", "\"1\""] {
        assert_eq!(JsonValue::decode(raw.as_bytes()).unwrap().as_i64(), None);
    }
}

#[test]
fn malformed_selected_values_are_rejected() {
    for raw in [
        &b""[..],
        b"[",
        b"01",
        b"+1",
        b"NaN",
        b"1e128",
        b"1e-129",
        b"1.0e-128",
        b"1e9999",
        b"{\"a\":undefined}",
        b"{\"a\":1}false",
        b"{\"a\" 1}",
        b"[1,,2]",
        br#""\uD800""#,
        br#""\uDC00""#,
        br#""\x00""#,
        b"\"\xff\"",
        b"\"\x01\"",
        b"[/*synthetic*/1]",
        b"true false",
        b"\xff\xfe\x7b",
        b"\0\0\xfe\xff\0\x11\0\0",
    ] {
        assert_eq!(
            JsonValue::decode(raw),
            Err(JsonError::InvalidJson),
            "{raw:?}"
        );
    }
}
