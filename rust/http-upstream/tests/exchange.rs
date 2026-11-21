use std::{io, sync::Arc, time::Duration};

use codexone_http_upstream::{
    Bytes, Error, ExchangeOptions, HttpUpstream, Instant, Proxy, Request, RequestBody,
    ResponseProgress, StatusCode, UPLOAD_CHUNK_BYTES,
};
use futures_util::stream;
use tokio::{
    io::{AsyncBufRead, AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader},
    net::{TcpListener, TcpSocket, TcpStream},
    sync::oneshot,
    time::{sleep, timeout},
};
use tokio_rustls::{
    TlsAcceptor,
    rustls::{RootCertStore, ServerConfig, pki_types::PrivatePkcs8KeyDer},
};

const TEST_DEADLINE: Duration = Duration::from_secs(5);
const FIRST_RESPONSE: Duration = Duration::from_millis(120);

async fn loopback() -> (TcpListener, String) {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let destination = format!("http://{}", listener.local_addr().unwrap());
    (listener, destination)
}

fn options(limit: usize) -> ExchangeOptions {
    ExchangeOptions::new(Instant::now() + TEST_DEADLINE, FIRST_RESPONSE, limit)
}

fn post(url: &str, body: RequestBody) -> Request<RequestBody> {
    Request::post(format!("{url}/responses?synthetic=1"))
        .header("content-type", "application/json")
        .body(body)
        .unwrap()
}

async fn read_heads(reader: &mut (impl AsyncBufRead + Unpin)) -> String {
    let mut headers = String::new();
    loop {
        let mut line = String::new();
        assert_ne!(reader.read_line(&mut line).await.unwrap(), 0);
        if line == "\r\n" {
            return headers;
        }
        headers.push_str(&line);
    }
}

async fn accept(listener: &TcpListener) -> BufReader<TcpStream> {
    let (io, _) = listener.accept().await.unwrap();
    BufReader::new(io)
}

async fn finish(server: tokio::task::JoinHandle<()>) {
    timeout(TEST_DEADLINE, server).await.unwrap().unwrap();
}

#[tokio::test]
async fn fixed_json_preserves_bytes_and_waits_for_slow_upload() {
    const LENGTH: usize = 12 * 1024 * 1024;
    let (listener, destination) = loopback().await;
    let server = tokio::spawn(async move {
        let mut peer = accept(&listener).await;
        let headers = read_heads(&mut peer).await;
        assert!(headers.starts_with("POST /responses?synthetic=1 HTTP/1.1\r\n"));
        assert!(headers.contains(&format!("content-length: {LENGTH}\r\n")));
        sleep(FIRST_RESPONSE * 3).await;

        let mut buffer = [0; UPLOAD_CHUNK_BYTES];
        for _ in 0..LENGTH / buffer.len() {
            peer.read_exact(&mut buffer).await.unwrap();
            assert!(buffer.iter().all(|byte| *byte == b'x'));
        }
        peer.write_all(b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 11\r\n\r\n{\"ok\":true}")
            .await.unwrap();
    });

    let mut request = post(
        &destination,
        RequestBody::bytes(Bytes::from(vec![b'x'; LENGTH])),
    );
    request
        .headers_mut()
        .insert("content-length", "1".parse().unwrap());
    let response = HttpUpstream::default()
        .send(request, options(11))
        .await
        .unwrap();
    assert_eq!(response.headers()["content-type"], "application/json");
    assert_eq!(response.collect().await.unwrap(), "{\"ok\":true}");
    finish(server).await;
}

#[tokio::test]
async fn first_response_times_out_after_upload_even_with_headers() {
    let (listener, destination) = loopback().await;
    let server = tokio::spawn(async move {
        let mut peer = accept(&listener).await;
        read_heads(&mut peer).await;
        let mut request = [0; 2];
        peer.read_exact(&mut request).await.unwrap();
        assert_eq!(&request, b"{}");
        peer.write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n")
            .await
            .unwrap();
        assert_eq!(peer.read(&mut request).await.unwrap(), 0);
    });

    let response = HttpUpstream::default()
        .send(
            post(&destination, RequestBody::bytes(Bytes::from_static(b"{}"))),
            options(32),
        )
        .await
        .unwrap();
    assert_eq!(
        response.collect().await.unwrap_err(),
        Error::FirstResponseTimeout
    );
    finish(server).await;
}

#[tokio::test]
async fn early_success_allows_chunked_upload_and_sse_progress() {
    let (listener, destination) = loopback().await;
    let (ready, gate) = oneshot::channel();
    let server = tokio::spawn(async move {
        let mut peer = accept(&listener).await;
        let headers = read_heads(&mut peer).await;
        assert!(headers.contains("transfer-encoding: chunked\r\n"));
        assert!(headers.contains("content-encoding: zstd\r\n"));
        peer.write_all(b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Type: text/event-stream\r\n\r\n8\r\ndata:a\n\n\r\n")
            .await.unwrap();
        let mut wire = [0; 13];
        peer.read_exact(&mut wire).await.unwrap();
        assert_eq!(&wire, b"3\r\nabc\r\n0\r\n\r\n");
        sleep(FIRST_RESPONSE * 2).await;
        peer.write_all(b"8\r\ndata:b\n\n\r\n0\r\n\r\n")
            .await
            .unwrap();
    });

    let body = RequestBody::chunked(stream::once(async {
        gate.await.unwrap();
        Ok(Bytes::from_static(b"abc"))
    }));
    let mut request = post(&destination, body);
    request
        .headers_mut()
        .insert("content-encoding", "zstd".parse().unwrap());
    let mut config = options(16);
    config.response_progress = ResponseProgress::Explicit;
    config.response_idle_timeout = Some(Duration::from_secs(2));
    let mut response = HttpUpstream::default().send(request, config).await.unwrap();
    assert_eq!(response.headers()["content-type"], "text/event-stream");
    // The source can only finish after the early event has been delivered and marked.
    assert_eq!(response.next_chunk().await.unwrap().unwrap(), "data:a\n\n");
    response.mark_response_progress().unwrap();
    ready.send(()).unwrap();
    assert_eq!(response.collect().await.unwrap(), "data:b\n\n");
    finish(server).await;
}

#[tokio::test]
async fn early_error_cancels_the_upload_but_preserves_status_and_delayed_body() {
    let (listener, destination) = loopback().await;
    let (released, uploader_dropped) = oneshot::channel::<()>();
    let server = tokio::spawn(async move {
        let mut peer = accept(&listener).await;
        read_heads(&mut peer).await;
        peer.write_all(
            b"HTTP/1.1 413 Payload Too Large\r\nConnection: close\r\nContent-Length: 8\r\nRetry-After: 1\r\n\r\n",
        )
        .await
        .unwrap();
        assert!(uploader_dropped.await.is_err());
        sleep(FIRST_RESPONSE * 2).await;
        peer.write_all(b"rejected").await.unwrap();
    });

    let body = RequestBody::chunked(stream::once(async move {
        let _producer_lease = released;
        std::future::pending().await
    }));
    let response = HttpUpstream::default()
        .send(post(&destination, body), options(8))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::PAYLOAD_TOO_LARGE);
    assert_eq!(response.headers()["retry-after"], "1");
    assert_eq!(response.collect().await.unwrap(), "rejected");
    finish(server).await;
}

#[tokio::test]
async fn first_response_deadline_ignores_sse_comments() {
    let (listener, destination) = loopback().await;
    let server = tokio::spawn(async move {
        let mut peer = accept(&listener).await;
        read_heads(&mut peer).await;
        peer.write_all(b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\n:\n\n\r\n")
            .await
            .unwrap();
        assert_eq!(
            peer.read_u8().await.unwrap_err().kind(),
            io::ErrorKind::UnexpectedEof
        );
    });
    let mut config = options(32);
    config.response_progress = ResponseProgress::Explicit;
    let mut response = HttpUpstream::default()
        .send(post(&destination, RequestBody::default()), config)
        .await
        .unwrap();
    assert_eq!(response.next_chunk().await.unwrap().unwrap(), ":\n\n");
    assert_eq!(
        response.next_chunk().await.unwrap_err(),
        Error::FirstResponseTimeout
    );
    finish(server).await;
}

#[tokio::test]
async fn deadline_and_cancellation_close_incomplete_uploads() {
    for expected in [Error::DeadlineExceeded, Error::Cancelled] {
        let (listener, destination) = loopback().await;
        let mut config = options(32);
        config.deadline = Instant::now() + FIRST_RESPONSE * 3;
        let cancel = config.cancellation.clone();
        let server = tokio::spawn(async move {
            let mut peer = accept(&listener).await;
            let headers = read_heads(&mut peer).await;
            assert!(headers.contains("transfer-encoding: chunked\r\n"));
            if expected == Error::Cancelled {
                cancel.cancel();
            }
            assert_eq!(
                peer.read_u8().await.unwrap_err().kind(),
                io::ErrorKind::UnexpectedEof
            );
        });
        let body = RequestBody::chunked(stream::pending());
        assert_eq!(
            HttpUpstream::default()
                .send(post(&destination, body), config)
                .await
                .unwrap_err(),
            expected
        );
        finish(server).await;
    }
}

#[tokio::test]
async fn cancelled_idle_consumer_closes_the_socket() {
    let (listener, destination) = loopback().await;
    let server = tokio::spawn(async move {
        let mut peer = accept(&listener).await;
        read_heads(&mut peer).await;
        peer.write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 9\r\n\r\nbytes")
            .await
            .unwrap();
        assert_eq!(
            peer.read_u8().await.unwrap_err().kind(),
            io::ErrorKind::UnexpectedEof
        );
    });
    let config = options(32);
    let cancel = config.cancellation.clone();
    let mut response = HttpUpstream::default()
        .send(post(&destination, RequestBody::default()), config)
        .await
        .unwrap();
    cancel.cancel();
    finish(server).await;
    assert_eq!(response.next_chunk().await.unwrap_err(), Error::Cancelled);
}

#[tokio::test]
async fn body_limits_and_disconnects_preserve_errors_without_replay() {
    let samples = [
        (
            b"HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\n1234".as_slice(),
            3,
            Error::ResponseTooLarge,
        ),
        (
            b"HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\n12".as_slice(),
            32,
            Error::ResponseBody,
        ),
        (
            b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\n12\r\n".as_slice(),
            32,
            Error::ResponseBody,
        ),
    ];
    for (reply, limit, error) in samples {
        let (listener, destination) = loopback().await;
        let server = tokio::spawn(async move {
            let mut peer = accept(&listener).await;
            read_heads(&mut peer).await;
            peer.write_all(reply).await.unwrap();
            drop(peer);
            assert!(timeout(FIRST_RESPONSE, listener.accept()).await.is_err());
        });
        let response = HttpUpstream::default()
            .send(post(&destination, RequestBody::default()), options(limit))
            .await
            .unwrap();
        assert_eq!(response.collect().await.unwrap_err(), error);
        finish(server).await;
    }
}

#[tokio::test]
async fn tcp_retry_backoff_obeys_the_exchange_deadline_and_cancellation() {
    let socket = TcpSocket::new_v4().unwrap();
    socket.bind("127.0.0.1:0".parse().unwrap()).unwrap();
    let destination = format!("http://{}", socket.local_addr().unwrap());
    let client = HttpUpstream::default().with_connection_establishment_retry();

    let mut deadline = options(32);
    deadline.deadline = Instant::now() + Duration::from_millis(25);
    assert_eq!(
        client
            .send(post(&destination, RequestBody::default()), deadline)
            .await
            .unwrap_err(),
        Error::DeadlineExceeded
    );

    let options = options(32);
    let cancel = options.cancellation.clone();
    let (response, ()) = tokio::join!(
        client.send(post(&destination, RequestBody::default()), options),
        async {
            sleep(Duration::from_millis(25)).await;
            cancel.cancel();
        }
    );
    assert_eq!(response.unwrap_err(), Error::Cancelled);
}

#[tokio::test]
async fn disconnect_before_headers_never_replays_the_request() {
    let (listener, destination) = loopback().await;
    let server = tokio::spawn(async move {
        let mut peer = accept(&listener).await;
        read_heads(&mut peer).await;
        let mut body = [0; 2];
        peer.read_exact(&mut body).await.unwrap();
        assert_eq!(&body, b"{}");
        drop(peer);
        assert!(timeout(FIRST_RESPONSE, listener.accept()).await.is_err());
    });
    assert_eq!(
        HttpUpstream::default()
            .with_connection_establishment_retry()
            .send(
                post(&destination, RequestBody::bytes(Bytes::from_static(b"{}"))),
                options(32)
            )
            .await
            .unwrap_err(),
        Error::Transport
    );
    finish(server).await;
}

#[tokio::test]
async fn explicit_http_proxy_tunnels_without_forwarding_credentials_or_redirects() {
    let (listener, proxy_url) = loopback().await;
    let server = tokio::spawn(async move {
        let mut peer = accept(&listener).await;
        let headers = read_heads(&mut peer).await;
        assert!(headers.starts_with("CONNECT provider.example.invalid:80 HTTP/1.1\r\n"));
        assert!(!headers.contains("authorization:"));
        peer.write_all(b"HTTP/1.1 200 Connection Established\r\n\r\n")
            .await
            .unwrap();

        let headers = read_heads(&mut peer).await;
        assert!(headers.starts_with("POST /responses?synthetic=1 HTTP/1.1\r\n"));
        assert!(headers.contains("host: provider.example.invalid\r\n"));
        assert!(headers.contains("authorization: Bearer synthetic\r\n"));
        peer.write_all(b"HTTP/1.1 307 Temporary Redirect\r\nLocation: http://provider.example.invalid/other\r\nContent-Length: 0\r\n\r\n")
            .await.unwrap();
        assert!(timeout(FIRST_RESPONSE, listener.accept()).await.is_err());
    });
    let proxy = Proxy::parse(&proxy_url).unwrap();
    let mut request = post("http://provider.example.invalid", RequestBody::default());
    request
        .headers_mut()
        .insert("authorization", "Bearer synthetic".parse().unwrap());
    let response = HttpUpstream::new(Some(proxy))
        .send(request, options(8))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::TEMPORARY_REDIRECT);
    assert!(response.collect().await.unwrap().is_empty());
    finish(server).await;
}

#[tokio::test]
async fn https_uses_tls_with_verified_server_identity_directly_and_through_connect() {
    let rcgen::CertifiedKey { cert, signing_key } =
        rcgen::generate_simple_self_signed(vec!["localhost".to_string()]).unwrap();
    let key = PrivatePkcs8KeyDer::from(signing_key.serialize_der());
    let tls = ServerConfig::builder_with_provider(Arc::new(
        tokio_rustls::rustls::crypto::ring::default_provider(),
    ))
    .with_safe_default_protocol_versions()
    .unwrap()
    .with_no_client_auth()
    .with_single_cert(vec![cert.der().clone()], key.into())
    .unwrap();
    let mut roots = RootCertStore::empty();
    roots.add(cert.der().clone()).unwrap();
    let tls = TlsAcceptor::from(Arc::new(tls));

    for (tunnel, hostname) in [
        (false, "localhost"),
        (true, "localhost"),
        (false, "127.0.0.1"),
    ] {
        let (listener, proxy_url) = loopback().await;
        let port = listener.local_addr().unwrap().port();
        let destination = format!("https://{hostname}:{port}");
        let tls = tls.clone();
        let server = tokio::spawn(async move {
            let mut peer = accept(&listener).await;
            if tunnel {
                let headers = read_heads(&mut peer).await;
                assert!(headers.starts_with(&format!("CONNECT localhost:{port} HTTP/1.1\r\n")));
                assert!(headers.contains(&format!("host: localhost:{port}\r\n")));
                peer.write_all(b"HTTP/1.1 200 Connection Established\r\n\r\n")
                    .await
                    .unwrap();
            }
            let tls = tls.accept(peer).await;
            if hostname != "localhost" {
                assert!(tls.is_err());
                assert!(timeout(FIRST_RESPONSE, listener.accept()).await.is_err());
                return;
            }
            let mut peer = BufReader::new(tls.unwrap());
            assert!(
                read_heads(&mut peer)
                    .await
                    .starts_with("POST /responses?synthetic=1 HTTP/1.1\r\n")
            );
            peer.write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}")
                .await
                .unwrap();
        });

        let proxy = tunnel.then(|| Proxy::parse(&proxy_url).unwrap());
        let result = HttpUpstream::new(proxy)
            .with_connection_establishment_retry()
            .with_root_certificates(roots.clone())
            .send(post(&destination, RequestBody::default()), options(32))
            .await;
        if hostname == "localhost" {
            assert_eq!(result.unwrap().collect().await.unwrap(), "{}");
        } else {
            assert_eq!(result.unwrap_err(), Error::Tls);
        }
        finish(server).await;
    }
}

#[tokio::test]
async fn response_is_backpressured_until_the_caller_pulls_again() {
    const LENGTH: usize = 12 * 1024 * 1024;
    let (listener, destination) = loopback().await;
    let (sent, mut fully_sent) = oneshot::channel();
    let server = tokio::spawn(async move {
        let mut peer = accept(&listener).await;
        read_heads(&mut peer).await;
        peer.write_all(format!("HTTP/1.1 200 OK\r\nContent-Length: {LENGTH}\r\n\r\n").as_bytes())
            .await
            .unwrap();
        let chunk = [b'x'; UPLOAD_CHUNK_BYTES];
        for _ in 0..LENGTH / chunk.len() {
            peer.write_all(&chunk).await.unwrap();
        }
        sent.send(()).unwrap();
    });

    let mut config = options(LENGTH);
    config.first_response_timeout = Duration::from_secs(2);
    let mut response = HttpUpstream::default()
        .send(post(&destination, RequestBody::default()), config)
        .await
        .unwrap();
    assert!(timeout(FIRST_RESPONSE, &mut fully_sent).await.is_err());
    let mut count = 0;
    while let Some(chunk) = response.next_chunk().await.unwrap() {
        assert!(chunk.iter().all(|byte| *byte == b'x'));
        count += chunk.len();
    }
    assert_eq!(count, LENGTH);
    fully_sent.await.unwrap();
    finish(server).await;
}

#[tokio::test]
async fn upload_idle_expiry_also_covers_a_stalled_initial_chunk() {
    let (listener, destination) = loopback().await;
    let server = tokio::spawn(async move {
        let mut peer = accept(&listener).await;
        read_heads(&mut peer).await;
        assert_eq!(
            peer.read_u8().await.unwrap_err().kind(),
            io::ErrorKind::UnexpectedEof
        );
    });
    let mut config = options(32);
    config.upload_idle_timeout = Some(FIRST_RESPONSE);
    assert_eq!(
        HttpUpstream::default()
            .send(
                post(&destination, RequestBody::chunked(stream::pending())),
                config
            )
            .await
            .unwrap_err(),
        Error::ProgressTimeout
    );
    finish(server).await;
}

#[tokio::test]
async fn refused_proxy_tunnel_cannot_fall_back_to_the_provider() {
    let (listener, proxy_url) = loopback().await;
    let (provider, destination) = loopback().await;
    let server = tokio::spawn(async move {
        let mut peer = accept(&listener).await;
        let headers = read_heads(&mut peer).await;
        assert!(headers.starts_with("CONNECT "));
        peer.write_all(b"HTTP/1.1 407 Proxy Authentication Required\r\nContent-Length: 0\r\n\r\n")
            .await
            .unwrap();
        let (proxy_retry, direct_fallback) = tokio::join!(
            timeout(FIRST_RESPONSE, listener.accept()),
            timeout(FIRST_RESPONSE, provider.accept()),
        );
        assert!(proxy_retry.is_err() && direct_fallback.is_err());
    });
    let client = HttpUpstream::new(Some(Proxy::parse(&proxy_url).unwrap()))
        .with_connection_establishment_retry();
    assert_eq!(
        client
            .send(post(&destination, RequestBody::default()), options(8))
            .await
            .unwrap_err(),
        Error::ProxyAuthenticationRequired
    );
    finish(server).await;
}

#[test]
fn proxy_configuration_requires_a_plain_authority_and_explicit_port() {
    assert!(Proxy::parse("http://[::1]:8080/").is_ok());
    assert_eq!(
        format!(
            "{:?}",
            Proxy::parse("http://proxy.example.invalid:80").unwrap()
        ),
        "Proxy(redacted)"
    );
    for invalid in [
        "https://proxy.example.invalid:80",
        "http://proxy.example.invalid",
        "http://proxy.example.invalid:0",
        "http://proxy.example.invalid:65536",
        "http://proxy.example.invalid:80/path",
        "http://proxy.example.invalid:80?query",
        "http://proxy.example.invalid:80#fragment",
        "http://synthetic@proxy.example.invalid:80",
    ] {
        assert_eq!(Proxy::parse(invalid).unwrap_err(), Error::InvalidProxy);
    }
}
