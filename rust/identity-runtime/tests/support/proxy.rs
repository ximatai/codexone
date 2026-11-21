use std::{
    fs::{self, File},
    time::{SystemTime, UNIX_EPOCH},
};

use codexone_http_upstream::Proxy;
use tokio::io::{AsyncRead, AsyncWrite};
use tokio_rustls::{
    TlsAcceptor,
    rustls::{RootCertStore, ServerConfig, crypto::ring, pki_types::PrivatePkcs8KeyDer},
};

use super::*;

const CODE: &str = "synthetic-proxy-auth-code";
const INITIAL_REFRESH: &str = "synthetic-proxy-refresh-initial";
const ROTATED_REFRESH: &str = "synthetic-proxy-refresh-rotated";
const PROVIDER_MARKER: &str = "synthetic-private-quota-marker";
const AUTHORITIES: [&str; 3] = [
    "auth.openai.com:443",
    "auth.openai.com:443",
    "chatgpt.com:443",
];

#[tokio::test]
async fn subscription_identity_uses_https_connect_for_exchange_refresh_and_quota() {
    let proxy = listener().await;
    let target = listener().await;
    let proxy_url = format!("http://{}", proxy.local_addr().unwrap());
    let target_addr = target.local_addr().unwrap();
    let rcgen::CertifiedKey { cert, signing_key } =
        rcgen::generate_simple_self_signed(vec!["auth.openai.com".into(), "chatgpt.com".into()])
            .unwrap();
    let key = PrivatePkcs8KeyDer::from(signing_key.serialize_der());
    let server = ServerConfig::builder_with_provider(Arc::new(ring::default_provider()))
        .with_safe_default_protocol_versions()
        .unwrap()
        .with_no_client_auth()
        .with_single_cert(vec![cert.der().clone()], key.into())
        .unwrap();
    let tls = TlsAcceptor::from(Arc::new(server));
    let mut roots = RootCertStore::empty();
    roots.add(cert.der().clone()).unwrap();
    let fixture = Fixture::with_provider(|_| {
        SubscriptionProvider::production(Some(Proxy::parse(&proxy_url).unwrap()))
            .with_test_roots(roots)
    });
    let log_path = fixture.directory.path().join("trace.log");
    let subscriber = tracing_subscriber::fmt()
        .with_ansi(false)
        .with_writer(Mutex::new(File::create(&log_path).unwrap()))
        .finish();
    let _tracing = tracing::subscriber::set_default(subscriber);
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs() as i64;
    let mut initial = token_doc("synthetic/account", now + 300, Some(NONCE));
    initial["refresh_token"] = json!(INITIAL_REFRESH);
    let mut refreshed = token_doc("synthetic/account", now + 7200, None);
    refreshed["refresh_token"] = json!(ROTATED_REFRESH);

    let tunnels = tokio::spawn(async move {
        let mut wire = Vec::new();
        for authority in AUTHORITIES {
            let (mut upstream, _) = proxy.accept().await.unwrap();
            let connect = read_request(&mut upstream).await;
            assert!(
                connect.head.to_ascii_lowercase()
                    == format!("connect {authority} http/1.1\r\nhost: {authority}\r\n\r\n"),
                "CONNECT contains an unexpected authority or header"
            );
            assert!(connect.body.is_empty());
            let mut downstream = TcpStream::connect(target_addr).await.unwrap();
            upstream
                .write_all(b"HTTP/1.1 200 Connection Established\r\n\r\n")
                .await
                .unwrap();
            let (from_client, to_client) = upstream.split();
            let (from_target, to_target) = downstream.split();
            let (request_wire, response_wire) =
                tokio::join!(relay(from_client, to_target), relay(from_target, to_client));
            wire.extend([request_wire, response_wire]);
        }
        assert!(
            timeout(Duration::from_millis(50), proxy.accept())
                .await
                .is_err()
        );
        wire
    });

    let target_access = refreshed["access_token"].as_str().unwrap().to_owned();
    let secret_values = [
        CODE.to_owned(),
        VERIFIER.to_owned(),
        NONCE.to_owned(),
        INITIAL_REFRESH.to_owned(),
        ROTATED_REFRESH.to_owned(),
        PROVIDER_MARKER.to_owned(),
        initial["access_token"].as_str().unwrap().to_owned(),
        initial["id_token"].as_str().unwrap().to_owned(),
        target_access.clone(),
    ];
    let target = tokio::spawn(async move {
        for (index, authority) in AUTHORITIES.into_iter().enumerate() {
            let (socket, _) = target.accept().await.unwrap();
            let mut socket = tls.accept(socket).await.unwrap();
            let host = authority.strip_suffix(":443").unwrap();
            assert_eq!(socket.get_ref().1.server_name(), Some(host));
            let request = read_request(&mut socket).await;
            let headers = request.head.to_ascii_lowercase();
            assert!(headers.contains(&format!("host: {host}\r\n")));
            assert!(!headers.contains("proxy-authorization:"));
            match index {
                0 => {
                    assert!(request.head.starts_with("POST /oauth/token HTTP/1.1\r\n"));
                    assert!(!headers.contains("authorization:"));
                    assert!(request.body.contains(&format!("code={CODE}")));
                    assert!(request.body.contains(&format!("code_verifier={VERIFIER}")));
                    reply(&mut socket, 200, &initial).await;
                }
                1 => {
                    assert!(request.head.starts_with("POST /oauth/token HTTP/1.1\r\n"));
                    assert!(!headers.contains("authorization:"));
                    let body: Value = serde_json::from_str(&request.body).unwrap();
                    assert_eq!(body["grant_type"], "refresh_token");
                    assert!(body["refresh_token"] == INITIAL_REFRESH);
                    reply(&mut socket, 200, &refreshed).await;
                }
                _ => {
                    assert!(
                        request
                            .head
                            .starts_with("GET /backend-api/wham/usage HTTP/1.1\r\n")
                    );
                    assert!(
                        request
                            .head
                            .lines()
                            .find_map(|line| line.strip_prefix("authorization: Bearer "))
                            == Some(target_access.as_str())
                    );
                    assert!(request.body.is_empty());
                    reply(
                        &mut socket,
                        200,
                        &json!({
                            "account_id": "synthetic/account",
                            "rate_limit": {"allowed": true},
                            "private_marker": PROVIDER_MARKER
                        }),
                    )
                    .await;
                }
            }
        }
        assert!(
            timeout(Duration::from_millis(50), target.accept())
                .await
                .is_err()
        );
    });

    let verified = timeout(WAIT, fixture.provider.authorize(CODE, VERIFIER, NONCE))
        .await
        .unwrap()
        .unwrap();
    let account = fixture
        .governance
        .seal_verified(Target::Create, verified)
        .await
        .unwrap();
    fixture
        .governance
        .set_account_mode(account.id.clone(), account.revision, AccountMode::Enabled)
        .await
        .unwrap();
    let observation = timeout(WAIT, fixture.runtime.observe_account(&account.id))
        .await
        .unwrap()
        .unwrap();
    assert!(observation.quota.unwrap().limits[0].allowed.unwrap());
    assert_eq!(fixture.current().await.credential_version, 2);

    timeout(WAIT, target).await.unwrap().unwrap();
    let wire = timeout(WAIT, tunnels).await.unwrap().unwrap();
    let trace = fs::read_to_string(log_path).unwrap();
    assert!(trace.contains("proactive_refresh_result"));
    for secret in secret_values {
        assert!(
            !trace.contains(&secret),
            "identity trace contains fixture secret"
        );
        assert!(
            wire.iter().all(|flow| !flow
                .windows(secret.len())
                .any(|chunk| chunk == secret.as_bytes())),
            "CONNECT wire contains fixture secret"
        );
    }
}

async fn relay(mut from: impl AsyncRead + Unpin, mut to: impl AsyncWrite + Unpin) -> Vec<u8> {
    let mut capture = Vec::new();
    let mut chunk = [0; 4096];
    loop {
        let count = from.read(&mut chunk).await.unwrap();
        if count == 0 {
            break;
        }
        assert!(capture.len() + count <= 64 * 1024);
        to.write_all(&chunk[..count]).await.unwrap();
        capture.extend_from_slice(&chunk[..count]);
    }
    to.shutdown().await.unwrap();
    capture
}
