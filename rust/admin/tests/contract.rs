use std::collections::BTreeMap;
use std::net::IpAddr;
use std::num::NonZeroU16;
use std::task::{Context, Poll, Waker};

use bytes::Bytes;
use codexone_admin::{AdminRouter, MAX_REQUEST_BYTES, ReadinessCheck, ReadinessReport, not_found};
use codexone_config::AdminWebBundle;
use http::{Method, Request, Response, StatusCode};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

const SECRET: &str = "synthetic-admin-session-credential-for-tests";
const HOST: &str = "127.0.0.1:19876";
const ORIGIN: &str = "http://127.0.0.1:19876";

fn router(
    address: Option<IpAddr>,
    origin: Option<&str>,
    bundle: Option<AdminWebBundle>,
    admin: bool,
) -> AdminRouter {
    AdminRouter::new(
        NonZeroU16::new(19876).unwrap(),
        address,
        admin.then(|| Sha256::digest(SECRET.as_bytes()).into()),
        origin,
        bundle,
    )
}

fn dispatch(
    router: &AdminRouter,
    request: Request<Bytes>,
    readiness: Option<ReadinessReport>,
) -> Response<Bytes> {
    let mut route = std::pin::pin!(router.route(&request, async || readiness.unwrap()));
    match route.as_mut().poll(&mut Context::from_waker(Waker::noop())) {
        Poll::Ready(response) => response.unwrap_or_else(not_found),
        Poll::Pending => panic!("test readiness is immediate"),
    }
}

fn request(method: &str, path: &str, headers: &[(&str, &str)], body: Bytes) -> Request<Bytes> {
    let mut request = Request::builder().method(method).uri(path);
    for (name, value) in headers {
        request = request.header(*name, *value);
    }
    request.body(body).unwrap()
}

fn login(router: &AdminRouter, host: &str, origin: &str, cookie: Option<&str>) -> Response<Bytes> {
    let mut headers = vec![
        ("host", host),
        ("origin", origin),
        ("content-type", "application/json"),
    ];
    if let Some(cookie) = cookie {
        headers.push(("cookie", cookie));
    }
    dispatch(
        router,
        request(
            "POST",
            "/api/session",
            &headers,
            json!({
                "username": "admin", "secret": SECRET
            })
            .to_string()
            .into(),
        ),
        None,
    )
}

fn document(response: &Response<Bytes>) -> Value {
    assert_eq!(response.headers()["cache-control"], "no-store");
    assert_eq!(response.headers()["connection"], "close");
    serde_json::from_slice(response.body()).unwrap()
}

fn error(response: &Response<Bytes>, status: u16, code: &str) -> String {
    assert_eq!(response.status(), status);
    assert!(!response.headers().contains_key("set-cookie"));
    let body = document(response);
    assert_eq!(body["error"]["code"], code);
    assert_eq!(body["error"]["message"], "Management request failed.");
    uuid::Uuid::parse_str(body["error"]["request_id"].as_str().unwrap())
        .unwrap()
        .to_string()
}

fn credentials(response: &Response<Bytes>, lan: bool) -> (String, String) {
    assert_eq!(response.status(), StatusCode::OK);
    let body = document(response);
    let csrf = body["csrf"].as_str().unwrap();
    assert_eq!(body["authenticated"], true);
    assert!(csrf.starts_with("ac1_") && csrf.len() == 47);

    let cookie = response.headers()["set-cookie"].to_str().unwrap();
    let (pair, attributes) = cookie.split_once("; Path=/; Max-Age=").unwrap();
    let (name, token) = pair.split_once('=').unwrap();
    assert_eq!(
        name,
        if lan {
            "codexone_admin"
        } else {
            "__Host-codexone_admin"
        }
    );
    assert!(token.starts_with("as1_") && token.len() == 47);
    assert!(!String::from_utf8_lossy(response.body()).contains(token));
    assert!(!String::from_utf8_lossy(response.body()).contains(SECRET));
    let (age, attributes) = attributes.split_once("; HttpOnly;").unwrap();
    assert!((1..=604800).contains(&age.parse::<u32>().unwrap()));
    assert_eq!(
        attributes,
        if lan {
            " SameSite=Strict"
        } else {
            " Secure; SameSite=Strict"
        }
    );

    (pair.to_owned(), csrf.to_owned())
}

#[test]
fn health_and_system_use_the_swift_dto_and_current_readiness() {
    let loopback = router(None, None, None, false);
    let get =
        |router, path, report| dispatch(router, request("GET", path, &[], Bytes::new()), report);
    let live = get(&loopback, "/health/live", None);
    assert_eq!(live.status(), 200);
    assert_eq!(document(&live), json!({"status": "alive"}));

    let fixture: Value = serde_json::from_str(include_str!(
        "../../../Tests/CodexOneAdaptersTests/Fixtures/system-status.json"
    ))
    .unwrap();
    let system = get(
        &loopback,
        "/api/system",
        Some(ReadinessReport::unconfigured()),
    );
    assert_eq!(system.status(), 200);
    assert_eq!(document(&system), fixture);
    let ready = get(
        &loopback,
        "/health/ready?probe=1",
        Some(ReadinessReport::unconfigured()),
    );
    assert_eq!(ready.status(), 503);
    assert_eq!(document(&ready), fixture);

    let lan = router(Some("192.168.1.10".parse().unwrap()), None, None, false);
    let report = || ReadinessReport {
        checks: vec![ReadinessCheck {
            name: "synthetic_check".into(),
            ready: true,
        }],
    };
    let ready = get(&lan, "/health/ready", Some(report()));
    assert_eq!(ready.status(), 200);
    assert_eq!(document(&ready)["transportMode"], "loopback");
    assert_eq!(document(&ready)["ready"], true);
    assert_eq!(
        document(&get(&lan, "/api/system", Some(report())))["transportMode"],
        "lan_http"
    );
    assert_eq!(get(&loopback, "/api/session", None).status(), 404);
    assert_eq!(get(&loopback, "/", None).status(), 404);
}

#[test]
fn spa_serves_an_exact_snapshot_with_swift_security_headers() {
    let bundle = AdminWebBundle {
        index: b"<!doctype html><title>Synthetic</title>".to_vec(),
        assets: BTreeMap::from([
            ("entry-h-Ab12_cd9.js".to_owned(), vec![b'x'; 1024 * 1024]),
            ("entry.css".to_owned(), b"body { color: black; }".to_vec()),
            ("entry-h-short.js".to_owned(), b"// synthetic".to_vec()),
        ]),
    };
    let router = router(None, None, Some(bundle), false);
    let get = |path| dispatch(&router, request("GET", path, &[], Bytes::new()), None);
    for (path, content_type, cache) in [
        ("/", "text/html", "no-store"),
        ("/index.html", "text/html", "no-store"),
        ("/assets/entry.css", "text/css", "no-store"),
        ("/assets/entry-h-short.js", "text/javascript", "no-store"),
        (
            "/assets/entry-h-Ab12_cd9.js?probe=1",
            "text/javascript",
            "public, max-age=31536000, immutable",
        ),
    ] {
        let response = get(path);
        assert_eq!(response.status(), 200);
        assert_eq!(
            response.headers()["content-type"],
            format!("{content_type}; charset=utf-8")
        );
        assert_eq!(response.headers()["cache-control"], cache);
        assert_eq!(response.headers()["x-content-type-options"], "nosniff");
        assert_eq!(response.headers()["referrer-policy"], "no-referrer");
        assert_eq!(response.headers()["x-frame-options"], "DENY");
        assert_eq!(
            response.headers()["content-security-policy"],
            "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; font-src 'self'; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'"
        );
    }
    let encoded = get("/assets//%65ntry.css/");
    assert_eq!(encoded.status(), 200);
    assert_eq!(encoded.body(), get("/assets/entry.css").body());
    let bytes = get("/assets/entry-h-Ab12_cd9.js");
    assert_eq!(bytes.body().len(), 1024 * 1024);
    assert!(bytes.body().iter().all(|byte| *byte == b'x'));
    for path in [
        "/admin",
        "/assets/../index.html",
        "/assets/%2e%2e%2findex.html",
        "/assets/missing-h-Ab12_cd9.js",
    ] {
        let response = get(path);
        assert_eq!(response.status(), 404);
        assert_eq!(response.headers()["cache-control"], "no-store");
    }
}

#[test]
fn login_validates_shape_before_issuing_any_session() {
    let router = router(None, None, None, true);
    let headers = [
        ("host", HOST),
        ("origin", ORIGIN),
        ("content-type", "application/json"),
    ];
    let post = |body| {
        dispatch(
            &router,
            request("POST", "/api/session", &headers, body),
            None,
        )
    };
    let mut ids = Vec::new();
    for payload in [
        json!({"secret": SECRET}),
        json!({"username": false, "secret": SECRET}),
        json!({"username": "Admin", "secret": SECRET}),
        json!({"username": "admin", "secret": "wrong-credential"}),
    ] {
        ids.push(error(
            &post(payload.to_string().into()),
            401,
            "invalid_admin_credential",
        ));
    }
    ids.sort_unstable();
    ids.dedup();
    assert_eq!(ids.len(), 4);

    for payload in [
        json!({"username":"admin", "secret": SECRET, "extra": true}).to_string(),
        json!({"username":"admin", "secret": 0}).to_string(),
        String::from("{"),
    ] {
        error(&post(payload.into()), 400, "invalid_command");
    }

    let first_valid =
        format!(r#"{{"username":"admin","secret":"{SECRET}","secret":"synthetic-wrong-secret"}}"#);
    credentials(&post(first_valid.into()), false);
    let first_invalid =
        format!(r#"{{"username":"admin","secret":"synthetic-wrong-secret","secret":"{SECRET}"}}"#);
    error(&post(first_invalid.into()), 401, "invalid_admin_credential");
    let nested = format!(
        r#"{{"username":{}0{},"secret":"{SECRET}"}}"#,
        "[".repeat(64),
        "]".repeat(64)
    );
    error(&post(nested.into()), 400, "json_too_deep");

    let oversized = post(vec![b'x'; MAX_REQUEST_BYTES + 1].into());
    assert_eq!(oversized.status(), 413);
    assert_eq!(document(&oversized)["error"]["code"], "request_too_large");
    let compressed_headers = [headers.as_slice(), &[("content-encoding", "gzip")]].concat();
    let compressed = request("POST", "/api/session", &compressed_headers, "{}".into());
    error(&dispatch(&router, compressed, None), 400, "invalid_command");
}

#[test]
fn session_requests_validate_origin_cookie_and_csrf_then_revoke() {
    let router = router(None, Some("https://admin.example"), None, true);
    let origin = "https://admin.example";
    let host = "ADMIN.example";
    let (cookie, csrf) = credentials(&login(&router, host, origin, None), false);
    let send = |method, headers: &[(&str, &str)]| {
        dispatch(
            &router,
            request(method, "/api/session", headers, Bytes::new()),
            None,
        )
    };
    let browser = [("host", host), ("cookie", &cookie)];
    assert_eq!(
        credentials(&send("GET", &browser), false),
        (cookie.clone(), csrf.clone())
    );
    let head = send("HEAD", &browser);
    assert_eq!(head.status(), 200);
    assert!(head.body().is_empty());
    assert_eq!(head.headers()["content-length"], "79");
    assert!(
        head.headers()["set-cookie"]
            .to_str()
            .unwrap()
            .starts_with(&cookie)
    );
    // The trusted loopback reverse-proxy Host is allowed, with the configured public Origin.
    assert_eq!(
        credentials(
            &send(
                "GET",
                &[("host", HOST), ("cookie", &cookie), ("origin", origin)]
            ),
            false
        )
        .1,
        csrf
    );
    error(
        &send(
            "GET",
            &[
                ("host", "other.example"),
                ("cookie", &cookie),
                ("x-forwarded-host", host),
            ],
        ),
        403,
        "invalid_management_host",
    );
    error(
        &send(
            "GET",
            &[("host", host), ("host", host), ("cookie", &cookie)],
        ),
        403,
        "invalid_management_host",
    );
    error(
        &send(
            "GET",
            &[
                ("host", host),
                ("cookie", &cookie),
                ("origin", "https://other.example"),
                ("x-forwarded-host", host),
                ("x-forwarded-proto", "https"),
            ],
        ),
        403,
        "invalid_management_origin",
    );
    error(
        &send(
            "GET",
            &[
                ("host", host),
                ("cookie", &cookie),
                ("origin", origin),
                ("origin", origin),
            ],
        ),
        403,
        "invalid_management_origin",
    );
    error(
        &send(
            "GET",
            &[
                ("host", host),
                ("cookie", &cookie),
                ("sec-fetch-site", "cross-site"),
            ],
        ),
        403,
        "invalid_management_origin",
    );
    error(
        &send(
            "GET",
            &[("host", host), ("cookie", &cookie), ("cookie", &cookie)],
        ),
        401,
        "invalid_admin_credential",
    );
    error(
        &send(
            "GET",
            &[("host", host), ("cookie", &format!("{cookie}; {cookie}"))],
        ),
        401,
        "invalid_admin_credential",
    );
    error(&send("DELETE", &browser), 403, "invalid_management_origin");
    error(
        &send(
            "DELETE",
            &[("host", host), ("cookie", &cookie), ("origin", origin)],
        ),
        403,
        "invalid_csrf",
    );
    error(
        &send(
            "DELETE",
            &[
                ("host", host),
                ("cookie", &cookie),
                ("origin", origin),
                ("x-codexone-csrf", &csrf),
                ("x-codexone-csrf", &csrf),
            ],
        ),
        403,
        "invalid_csrf",
    );

    let logout = send(
        "DELETE",
        &[
            ("host", host),
            ("cookie", &cookie),
            ("origin", origin),
            ("x-codexone-csrf", &csrf),
        ],
    );
    assert_eq!(logout.status(), 200);
    assert_eq!(document(&logout), json!({"authenticated": false}));
    assert_eq!(
        logout.headers()["set-cookie"],
        "__Host-codexone_admin=; Path=/; Max-Age=0; HttpOnly; Secure; SameSite=Strict"
    );
    error(&send("GET", &browser), 401, "invalid_admin_credential");
}

#[test]
fn capacity_replacement_revocation_and_restart_hold_for_lan_sessions() {
    let host = "[fd00::10]:19876";
    let origin = "http://[fd00::10]:19876";
    let make_router = || router(Some("fd00::10".parse().unwrap()), Some(origin), None, true);
    let router = make_router();
    let get = |router: &AdminRouter, cookie: &str| {
        dispatch(
            router,
            request(
                "GET",
                "/api/session",
                &[
                    ("host", host),
                    ("cookie", cookie),
                    ("sec-fetch-site", "same-origin"),
                ],
                Bytes::new(),
            ),
            None,
        )
    };
    let (first, _) = credentials(&login(&router, host, origin, None), true);
    for _ in 1..16 {
        assert_eq!(login(&router, host, origin, None).status(), 200);
    }
    error(
        &login(&router, host, origin, None),
        503,
        "management_unavailable",
    );
    let (replacement, csrf) = credentials(&login(&router, host, origin, Some(&first)), true);
    error(&get(&router, &first), 401, "invalid_admin_credential");
    assert_eq!(get(&router, &replacement).status(), 200);
    error(
        &get(&make_router(), &replacement),
        401,
        "invalid_admin_credential",
    );

    let logout = dispatch(
        &router,
        request(
            "DELETE",
            "/api/session",
            &[
                ("host", host),
                ("origin", origin),
                ("cookie", &replacement),
                ("x-codexone-csrf", &csrf),
            ],
            Bytes::new(),
        ),
        None,
    );
    assert_eq!(
        logout.headers()["set-cookie"],
        "codexone_admin=; Path=/; Max-Age=0; HttpOnly; SameSite=Strict"
    );
    let (survivor, _) = credentials(&login(&router, host, origin, None), true);
    router.revoke_sessions();
    error(&get(&router, &survivor), 401, "invalid_admin_credential");
    credentials(&login(&router, host, origin, Some(&survivor)), true);
}

#[test]
fn application_guard_enforces_headless_and_browser_credential_boundaries() {
    let router = router(None, None, None, true);
    let bearer = format!("Bearer {SECRET}");
    let call = |method, headers: &[(&str, &str)]| {
        let request = request(method, "/api/placeholder", headers, Bytes::new());
        match router.authorize(request.method(), request.headers()) {
            Ok(authorization) => {
                let mut response = Response::new(Bytes::new());
                authorization.apply(&mut response);
                response
            }
            Err(response) => *response,
        }
    };
    let headless = call("POST", &[("authorization", &bearer)]);
    assert_eq!(headless.status(), 200);
    assert_eq!(headless.headers()["cache-control"], "no-store");
    assert!(!headless.headers().contains_key("set-cookie"));
    error(
        &call(
            "POST",
            &[("authorization", &bearer), ("authorization", &bearer)],
        ),
        401,
        "invalid_admin_credential",
    );
    for field in [
        ("origin", ORIGIN),
        ("cookie", "synthetic=x"),
        ("sec-fetch-site", "same-origin"),
    ] {
        error(
            &call("GET", &[("authorization", &bearer), field]),
            403,
            "mixed_browser_credentials",
        );
    }

    let (cookie, csrf) = credentials(&login(&router, HOST, ORIGIN, None), false);
    let read = [("host", HOST), ("cookie", &cookie)];
    assert_eq!(call("GET", &read).status(), 200);
    error(
        &call(
            "PUT",
            &[("host", HOST), ("cookie", &cookie), ("origin", ORIGIN)],
        ),
        403,
        "invalid_csrf",
    );
    let write = call(
        "PUT",
        &[
            ("host", HOST),
            ("cookie", &cookie),
            ("origin", ORIGIN),
            ("x-codexone-csrf", &csrf),
        ],
    );
    assert_eq!(write.status(), 200);
    assert!(
        write.headers()["set-cookie"]
            .to_str()
            .unwrap()
            .starts_with(&cookie)
    );
}

#[test]
fn methods_outside_the_contract_are_left_to_the_product_router() {
    let router = router(None, None, None, true);
    for (method, path) in [
        (Method::PATCH, "/api/session"),
        (Method::POST, "/health/live"),
        (Method::GET, "/api/keys"),
        (Method::GET, "/api/overview/live"),
    ] {
        assert_eq!(
            dispatch(
                &router,
                request(method.as_str(), path, &[], Bytes::new()),
                None
            )
            .status(),
            404
        );
    }
}
