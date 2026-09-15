//! Shared loopback mock HTTP server for the ai/translate provider tests.
//! Serves one response per connection (in order) and forwards each raw
//! request text to the test, so request shape can be asserted.

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};

/// Serve [responses] on a loopback port, one per connection; returns the
/// BASE endpoint (`http://127.0.0.1:{port}` -- append the request path) and
/// a receiver yielding each raw request text in order. JSON content type.
pub(crate) async fn mock_server(
    responses: Vec<(&'static str, String)>,
) -> (String, tokio::sync::mpsc::Receiver<String>) {
    mock_server_with(
        responses
            .into_iter()
            .map(|(status, body)| (status, "application/json", body))
            .collect(),
    )
    .await
}

/// [mock_server] with an explicit content type per response (SSE streams).
pub(crate) async fn mock_server_with(
    responses: Vec<(&'static str, &'static str, String)>,
) -> (String, tokio::sync::mpsc::Receiver<String>) {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let (tx, rx) = tokio::sync::mpsc::channel(responses.len().max(1));
    tokio::spawn(async move {
        for (status_line, content_type, body) in responses {
            let Ok((mut sock, _)) = listener.accept().await else {
                return;
            };
            let req = read_request(&mut sock).await;
            let _ = tx.send(req).await;
            let resp = format!(
                "HTTP/1.1 {status_line}\r\nContent-Type: {content_type}\r\n\
                 Content-Length: {}\r\nConnection: close\r\n\r\n{}",
                body.len(),
                body
            );
            let _ = sock.write_all(resp.as_bytes()).await;
        }
    });
    (format!("http://127.0.0.1:{port}"), rx)
}

/// Read the full HTTP request (headers + Content-Length body).
pub(crate) async fn read_request(sock: &mut TcpStream) -> String {
    let mut buf: Vec<u8> = Vec::new();
    let mut chunk = [0u8; 4096];
    loop {
        let n = sock.read(&mut chunk).await.unwrap();
        if n == 0 {
            break;
        }
        buf.extend_from_slice(&chunk[..n]);
        if let Some(sep) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
            let head = String::from_utf8_lossy(&buf[..sep]).to_string();
            let len = head
                .lines()
                .find_map(|l| {
                    l.to_ascii_lowercase()
                        .strip_prefix("content-length:")
                        .and_then(|v| v.trim().parse::<usize>().ok())
                })
                .unwrap_or(0);
            if buf.len() >= sep + 4 + len {
                break;
            }
        }
    }
    String::from_utf8_lossy(&buf).to_string()
}