//! What the Cloud Providers behind OAuth share (Google Drive, OneDrive): HTTP
//! on the platform's TLS, access tokens kept fresh for a public client, the
//! outcome of a request as a storage error, and the chunked-upload loop.
//!
//! Blocking, no async runtime. Request bodies are in memory, so a request
//! can be sent again after the access token expired.

use crate::percent::encode;
use crate::storage::RefreshTokenCallback;
use serde_json::Value;
use std::io::{self, Read};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use ureq::http::{Request, Response};
use ureq::{Agent, Body};

#[cfg(test)]
pub(crate) mod fake;

/// The platform's TLS: the Security framework and the Device's trust store on
/// Apple (ADR-0023), rustls with the bundled public roots elsewhere.
pub(crate) fn tls_config() -> ureq::tls::TlsConfig {
    #[cfg(target_vendor = "apple")]
    return ureq::tls::TlsConfig::builder()
        .provider(ureq::tls::TlsProvider::NativeTls)
        .root_certs(ureq::tls::RootCerts::PlatformVerifier)
        .build();
    #[cfg(not(target_vendor = "apple"))]
    ureq::tls::TlsConfig::default()
}

/// Where a Cloud Provider's API is and how uploads are cut.
pub(crate) struct Config {
    pub api: String,
    pub token_url: String,
    /// Whether http URLs work, which they do only in tests against a fake.
    allow_http: bool,
    /// Blobs up to this many bytes upload in one request, held in memory.
    pub simple_limit: usize,
    /// The size of a part of a chunked upload.
    pub chunk_size: usize,
}

impl Config {
    /// The provider's API at `api`, with its token endpoint at `token_url`.
    pub(crate) fn new(api: &str, token_url: &str, simple_limit: usize, chunk_size: usize) -> Self {
        Self {
            api: api.to_owned(),
            token_url: token_url.to_owned(),
            allow_http: false,
            simple_limit,
            chunk_size,
        }
    }

    /// A fake provider served at `base`, see `fake::Server`.
    #[cfg(test)]
    pub(crate) fn fake(base: &str, simple_limit: usize, chunk_size: usize) -> Self {
        let token_url = format!("{base}/token");
        let config = Self::new(base, &token_url, simple_limit, chunk_size);
        Self {
            allow_http: true,
            ..config
        }
    }
}

/// A request to a Cloud Provider's API on behalf of the user, authorized by an
/// OAuth access token that is refreshed from the refresh token when needed.
///
/// What a request answers is told apart like this, so callers can tell a
/// problem to fix from being offline:
/// - rejected or revoked access: `PermissionDenied`
/// - no space left: `QuotaExceeded` (or `StorageFull`), see `storage::is_full`
/// - rate limits, server errors and network failures: other kinds
///
/// Any other answer (404, a chunk's 308, ...) is returned for the caller.
pub(crate) struct OAuthClient {
    agent: Agent,
    token_url: String,
    client_id: String,
    tokens: Mutex<Tokens>,
    on_new_refresh_token: Arc<dyn RefreshTokenCallback>,
}

struct Tokens {
    /// None until the first request.
    access: Option<String>,
    /// The latest one: the provider may rotate it.
    refresh: String,
}

impl OAuthClient {
    /// A client of a public OAuth client `client_id` (PKCE, no secret) that
    /// holds `refresh_token`, and reports each new one to `on_new_refresh_token`.
    /// Contacts nobody. Only https URLs work, except in tests.
    pub(crate) fn new(
        config: &Config,
        client_id: &str,
        refresh_token: &str,
        on_new_refresh_token: Arc<dyn RefreshTokenCallback>,
    ) -> Self {
        let agent = Agent::config_builder()
            .https_only(!config.allow_http)
            .http_status_as_error(false)
            // A resumable upload answers 308 for "send the next chunk".
            .max_redirects(0)
            .max_redirects_will_error(false)
            .tls_config(tls_config())
            .timeout_connect(Some(Duration::from_secs(10)))
            .timeout_recv_response(Some(Duration::from_secs(30)))
            .build();
        Self {
            agent: Agent::new_with_config(agent),
            token_url: config.token_url.clone(),
            client_id: client_id.to_owned(),
            tokens: Mutex::new(Tokens {
                access: None,
                refresh: refresh_token.to_owned(),
            }),
            on_new_refresh_token,
        }
    }

    /// Sends a request with `body`. After a 401 the access token is refreshed
    /// and the request sent once more.
    pub(crate) fn send(
        &self,
        method: &str,
        url: &str,
        headers: &[(&str, &str)],
        body: &[u8],
    ) -> io::Result<Response<Body>> {
        let token = self.access_token()?;
        let mut response = self.send_with(Some(&token), method, url, headers, body)?;
        if response.status().as_u16() == 401 {
            let token = self.refresh(&token)?;
            response = self.send_with(Some(&token), method, url, headers, body)?;
        }
        check(response)
    }

    /// The JSON answer to a request that must succeed, with `body` as JSON.
    pub(crate) fn json(&self, method: &str, url: &str, body: Option<&Value>) -> io::Result<Value> {
        let body = body.map(Value::to_string).unwrap_or_default();
        let headers = [("Content-Type", "application/json; charset=UTF-8")];
        let response = self.send(method, url, &headers, body.as_bytes())?;
        succeeded(method, &response)?;
        read_json(response)
    }

    /// Sends a request to a URL the provider has handed out for one job, like
    /// an upload or a download. It is authorized already, and may refuse a
    /// token on top, so none is sent. Answers are told apart as for `send`.
    pub(crate) fn send_to_handed_out_url(
        &self,
        method: &str,
        url: &str,
        headers: &[(&str, &str)],
        body: &[u8],
    ) -> io::Result<Response<Body>> {
        check(self.send_with(None, method, url, headers, body)?)
    }

    fn send_with(
        &self,
        token: Option<&str>,
        method: &str,
        url: &str,
        headers: &[(&str, &str)],
        body: &[u8],
    ) -> io::Result<Response<Body>> {
        let mut request = Request::builder().method(method).uri(url);
        if let Some(token) = token {
            request = request.header("Authorization", format!("Bearer {token}"));
        }
        for (name, value) in headers {
            request = request.header(*name, *value);
        }
        let request = request.body(body).map_err(io::Error::other)?;
        self.agent.run(request).map_err(ureq::Error::into_io)
    }

    fn access_token(&self) -> io::Result<String> {
        let mut tokens = self.tokens.lock().unwrap();
        match &tokens.access {
            Some(access) => Ok(access.clone()),
            None => self.renew(&mut tokens),
        }
    }

    /// A fresh access token to replace `stale`, unless another request has
    /// replaced it already.
    fn refresh(&self, stale: &str) -> io::Result<String> {
        let mut tokens = self.tokens.lock().unwrap();
        match &tokens.access {
            Some(access) if access != stale => Ok(access.clone()),
            _ => self.renew(&mut tokens),
        }
    }

    fn renew(&self, tokens: &mut Tokens) -> io::Result<String> {
        let form = format!(
            "client_id={}&grant_type=refresh_token&refresh_token={}",
            encode(&self.client_id),
            encode(&tokens.refresh)
        );
        let request = Request::builder()
            .method("POST")
            .uri(&self.token_url)
            .header("Content-Type", "application/x-www-form-urlencoded")
            .body(form.as_bytes())
            .map_err(io::Error::other)?;
        let mut response = self.agent.run(request).map_err(ureq::Error::into_io)?;
        let status = response.status().as_u16();
        match status {
            200 => {}
            // The refresh token was revoked or expired, or the client is unknown.
            400 | 401 | 403 => return Err(denied(status)),
            _ => return Err(failed(status)),
        }
        let answer = response
            .body_mut()
            .read_to_string()
            .map_err(io::Error::other)?;
        let answer: serde_json::Value = serde_json::from_str(&answer)?;
        let access = answer["access_token"]
            .as_str()
            .ok_or_else(|| io::Error::other("the token endpoint gave no access token"))?
            .to_owned();
        match answer["refresh_token"].as_str() {
            Some(rotated) if rotated != tokens.refresh => {
                tokens.refresh = rotated.to_owned();
                self.on_new_refresh_token.new_refresh_token(rotated);
            }
            _ => {}
        }
        tokens.access = Some(access.clone());
        Ok(access)
    }
}

fn denied(status: u16) -> io::Error {
    io::Error::new(
        io::ErrorKind::PermissionDenied,
        format!("access refused, status {status}"),
    )
}

fn failed(status: u16) -> io::Error {
    io::Error::other(format!("status {status}"))
}

/// `response`, unless its status is one of those that are errors for any request.
fn check(mut response: Response<Body>) -> io::Result<Response<Body>> {
    let status = response.status().as_u16();
    let body = if status == 403 {
        response.body_mut().read_to_string().unwrap_or_default()
    } else {
        String::new()
    };
    refuse(status, &body).map(|()| response)
}

/// The error a request's `status` and `body` stand for, if any.
fn refuse(status: u16, body: &str) -> io::Result<()> {
    match status {
        401 => Err(denied(status)),
        403 => {
            // The body says why: a full quota or too many requests are not a
            // lost permission.
            let reason = body.to_lowercase();
            if reason.contains("quota") {
                Err(io::Error::new(
                    io::ErrorKind::QuotaExceeded,
                    "quota exceeded",
                ))
            } else if ["ratelimit", "dailylimit", "activitylimit"]
                .iter()
                .any(|throttled| reason.contains(throttled))
            {
                Err(failed(status))
            } else {
                Err(denied(status))
            }
        }
        507 => Err(io::Error::new(
            io::ErrorKind::StorageFull,
            "507 Insufficient Storage",
        )),
        429 | 500..=599 => Err(failed(status)),
        _ => Ok(()),
    }
}

/// The error for an answer the caller didn't expect.
pub(crate) fn unexpected(what: &str, status: u16) -> io::Error {
    io::Error::other(format!("{what} answered with status {status}"))
}

/// An error unless `response` has a 2xx status.
pub(crate) fn succeeded(what: &str, response: &Response<Body>) -> io::Result<()> {
    match response.status().as_u16() {
        200..=299 => Ok(()),
        status => Err(unexpected(what, status)),
    }
}

/// The JSON in the body of `response`.
pub(crate) fn read_json(mut response: Response<Body>) -> io::Result<Value> {
    let answer = response
        .body_mut()
        .read_to_string()
        .map_err(io::Error::other)?;
    Ok(serde_json::from_str(&answer)?)
}

/// `name` split into its directory (`""` for the root) and the blob's own name.
pub(crate) fn split(name: &str) -> (&str, &str) {
    name.rsplit_once('/').unwrap_or(("", name))
}

/// The first `limit` bytes of `data` at most, read to tell small blobs, which
/// are held in memory and uploaded in one request, from large ones. More
/// than `limit` bytes means `data` has more to give.
pub(crate) fn read_head(data: &mut dyn Read, limit: usize) -> io::Result<Vec<u8>> {
    let mut head = Vec::new();
    data.take(limit as u64 + 1).read_to_end(&mut head)?;
    Ok(head)
}

/// A part of an upload.
pub(crate) struct Chunk<'a> {
    /// Where the bytes start in the whole.
    pub offset: u64,
    pub bytes: &'a [u8],
    /// The size of the whole, known only for the last chunk.
    pub total: Option<u64>,
}

impl Chunk<'_> {
    /// The `Content-Range` header of the chunk, for a whole of `total` bytes,
    /// if that is known.
    pub(crate) fn content_range(&self, total: Option<u64>) -> String {
        let total = total.map_or("*".to_owned(), |total| total.to_string());
        if self.bytes.is_empty() {
            return format!("bytes */{total}");
        }
        let last = self.offset + self.bytes.len() as u64 - 1;
        format!("bytes {}-{last}/{total}", self.offset)
    }
}

/// Reads `data` in chunks of `size` bytes and hands each to `send`, in order,
/// until the last, which is also the only one that may be shorter, or even
/// empty. Stops at the first error: an interrupted upload is not resumed,
/// the caller starts over.
pub(crate) fn upload_chunks(
    data: &mut dyn Read,
    size: usize,
    mut send: impl FnMut(Chunk) -> io::Result<()>,
) -> io::Result<()> {
    // One byte more than a chunk tells whether it is the last.
    let mut buffer = Vec::with_capacity(size + 1);
    let mut offset = 0;
    loop {
        let missing = (size + 1 - buffer.len()) as u64;
        data.take(missing).read_to_end(&mut buffer)?;
        if buffer.len() <= size {
            let total = Some(offset + buffer.len() as u64);
            return send(Chunk {
                offset,
                bytes: &buffer,
                total,
            });
        }
        send(Chunk {
            offset,
            bytes: &buffer[..size],
            total: None,
        })?;
        buffer.drain(..size);
        offset += size as u64;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn chunks(data: &[u8], size: usize) -> Vec<(u64, Vec<u8>, Option<u64>)> {
        let mut seen = Vec::new();
        upload_chunks(&mut &data[..], size, |c| {
            seen.push((c.offset, c.bytes.to_vec(), c.total));
            Ok(())
        })
        .unwrap();
        seen
    }

    #[test]
    fn data_is_cut_into_chunks_and_the_last_one_knows_the_total() {
        assert_eq!(
            chunks(b"abcdefg", 3),
            [
                (0, b"abc".to_vec(), None),
                (3, b"def".to_vec(), None),
                (6, b"g".to_vec(), Some(7)),
            ]
        );
    }

    #[test]
    fn a_chunk_says_where_it_belongs_in_the_whole() {
        let chunk = |offset, bytes| Chunk {
            offset,
            bytes,
            total: None,
        };
        assert_eq!(chunk(0, b"abc").content_range(None), "bytes 0-2/*");
        assert_eq!(chunk(3, b"d").content_range(Some(4)), "bytes 3-3/4");
        assert_eq!(chunk(4, b"").content_range(Some(4)), "bytes */4");
    }

    #[test]
    fn data_that_fills_the_chunks_exactly_ends_with_a_full_chunk() {
        assert_eq!(
            chunks(b"abcdef", 3),
            [(0, b"abc".to_vec(), None), (3, b"def".to_vec(), Some(6))]
        );
        assert_eq!(chunks(b"abc", 3), [(0, b"abc".to_vec(), Some(3))]);
    }

    #[test]
    fn no_data_is_one_empty_chunk() {
        assert_eq!(chunks(b"", 3), [(0, Vec::new(), Some(0))]);
    }

    #[test]
    fn a_failing_chunk_or_source_stops_the_upload() {
        let mut sent = 0;
        let result = upload_chunks(&mut &b"abcdefgh"[..], 3, |_| {
            sent += 1;
            Err(io::Error::other("lost"))
        });
        assert!(result.is_err());
        assert_eq!(sent, 1);

        struct Breaks(bool);
        impl Read for Breaks {
            fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
                if std::mem::replace(&mut self.0, true) {
                    return Err(io::Error::other("lost"));
                }
                buf[..4].fill(b'x');
                Ok(4)
            }
        }
        let mut sent = 0;
        let result = upload_chunks(&mut Breaks(false), 3, |_| {
            sent += 1;
            Ok(())
        });
        assert!(result.is_err());
        assert_eq!(sent, 1);
    }

    #[test]
    fn rejected_access_is_denied_a_full_quota_is_full_and_the_rest_reads_as_offline() {
        use io::ErrorKind::PermissionDenied;
        let kind = |status, body| refuse(status, body).unwrap_err().kind();
        assert_eq!(kind(401, ""), PermissionDenied);
        assert_eq!(
            kind(403, r#"{"reason":"insufficientPermissions"}"#),
            PermissionDenied
        );
        assert_eq!(
            kind(403, r#"{"error":{"code":"quotaLimitReached"}}"#),
            io::ErrorKind::QuotaExceeded
        );
        assert_eq!(
            kind(403, r#"{"reason":"storageQuotaExceeded"}"#),
            io::ErrorKind::QuotaExceeded
        );
        assert!(crate::storage::is_full(&refuse(507, "").unwrap_err()));
        for (status, body) in [
            (403, r#"{"reason":"userRateLimitExceeded"}"#),
            (403, r#"{"error":{"code":"activityLimitReached"}}"#),
            (429, ""),
            (500, ""),
            (503, ""),
        ] {
            let error = refuse(status, body).unwrap_err();
            assert_eq!(error.kind(), io::ErrorKind::Other, "{status}");
        }
        for status in [200, 204, 308, 400, 404, 409] {
            assert!(refuse(status, "").is_ok(), "{status}");
        }
    }
}
