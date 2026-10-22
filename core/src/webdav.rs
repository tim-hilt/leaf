//! The WebDAV storage: the Cloud Provider for self-hosting (ADR-0010,
//! ADR-0017). Any WebDAV server works, e.g. `rclone serve webdav`.
//!
//! HTTPS only, Basic auth, blocking (no async runtime). Everything lives in a
//! `LeafPDF` folder inside the Server URL. Blobs are uploaded to a hidden
//! temporary name and then moved into place, so a half-written blob is never
//! visible under its final name.

use crate::storage::{Blob, Storage, check_name, unique_name};
use quick_xml::events::Event;
use quick_xml::reader::Reader;
use std::collections::HashSet;
use std::fmt;
use std::io::{self, Read};
use std::sync::Mutex;
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use ureq::http::{Request, Response};
use ureq::{Agent, Body, SendBody};

/// The folder in the Server URL that holds everything LeafPDF stores.
const FOLDER: &str = "LeafPDF";

/// Where blobs are uploaded before they are moved into place. Starts with a
/// dot, so it is no valid name and never listed.
const INCOMING: &str = ".incoming";

/// Why connecting to a WebDAV server failed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ConnectError {
    /// The server rejected the username or password.
    WrongCredentials,
    /// No answer: wrong host, no network, a broken certificate or a server
    /// that is down.
    Unreachable,
    /// The URL doesn't start with `https://`. The password would travel in
    /// plain text.
    NotHttps,
    /// The server answers, but not as a WebDAV server.
    NotWebDav,
}

/// The variant's name; clients word the message for the user.
impl fmt::Display for ConnectError {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        write!(f, "{self:?}")
    }
}

impl std::error::Error for ConnectError {}

/// The `LeafPDF` folder of a WebDAV server. A rejected login (HTTP 401) is an
/// `io::ErrorKind::PermissionDenied` error, anything else that fails to
/// connect is another kind.
pub struct WebDavStorage {
    agent: Agent,
    /// The Server URL, without a trailing slash.
    base: String,
    /// The URL of the `LeafPDF` folder inside it.
    root: String,
    /// The `Authorization` header value.
    auth: String,
    /// Directories known to exist, so a `put` doesn't ask for them each time.
    known_dirs: Mutex<HashSet<String>>,
}

impl fmt::Debug for WebDavStorage {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        // No credentials.
        f.debug_struct("WebDavStorage")
            .field("root", &self.root)
            .finish_non_exhaustive()
    }
}

/// The platform's TLS: the Security framework and the Device's trust store on
/// Apple (ADR-0023), rustls with the bundled public roots elsewhere.
fn tls_config() -> ureq::tls::TlsConfig {
    #[cfg(target_vendor = "apple")]
    return ureq::tls::TlsConfig::builder()
        .provider(ureq::tls::TlsProvider::NativeTls)
        .root_certs(ureq::tls::RootCerts::PlatformVerifier)
        .build();
    #[cfg(not(target_vendor = "apple"))]
    ureq::tls::TlsConfig::default()
}

impl WebDavStorage {
    /// Connects to the WebDAV server at `url` and checks the details. Creates
    /// the `LeafPDF` folder inside `url` if it's missing; uses it if not.
    pub fn connect(url: &str, username: &str, password: &str) -> Result<Self, ConnectError> {
        Self::connect_with(url, username, password, tls_config())
    }

    /// The storage of a server that was connected before, e.g. at the last
    /// launch. Contacts nobody, so it works offline; errors show on use.
    pub fn resume(url: &str, username: &str, password: &str) -> Result<Self, ConnectError> {
        Self::new(url, username, password, tls_config())
    }

    fn connect_with(
        url: &str,
        username: &str,
        password: &str,
        tls: ureq::tls::TlsConfig,
    ) -> Result<Self, ConnectError> {
        let storage = Self::new(url, username, password, tls)?;

        // The URL itself must be a WebDAV collection.
        let answer = storage
            .propfind(&storage.base, "0")
            .map_err(|e| match e.kind() {
                io::ErrorKind::PermissionDenied => ConnectError::WrongCredentials,
                _ => ConnectError::Unreachable,
            })?;
        match answer.status().as_u16() {
            207 => {}
            500..=599 => return Err(ConnectError::Unreachable),
            _ => return Err(ConnectError::NotWebDav),
        }

        // Its LeafPDF folder is there, or is created now.
        let status = storage
            .propfind(&storage.root, "0")
            .map_err(|_| ConnectError::Unreachable)?
            .status()
            .as_u16();
        match status {
            207 => {}
            404 => storage
                .make_dir(&storage.root)
                .map_err(|_| ConnectError::NotWebDav)?,
            _ => return Err(ConnectError::NotWebDav),
        }
        Ok(storage)
    }

    /// The storage for `url`, which must be https, without any request.
    fn new(
        url: &str,
        username: &str,
        password: &str,
        tls: ureq::tls::TlsConfig,
    ) -> Result<Self, ConnectError> {
        let url = url.trim();
        if !url
            .get(..8)
            .is_some_and(|scheme| scheme.eq_ignore_ascii_case("https://"))
        {
            return Err(ConnectError::NotHttps);
        }
        let config = Agent::config_builder()
            .https_only(true)
            // PROPFIND, MKCOL and MOVE.
            .allow_non_standard_methods(true)
            .http_status_as_error(false)
            .tls_config(tls)
            .timeout_connect(Some(Duration::from_secs(10)))
            .timeout_recv_response(Some(Duration::from_secs(30)))
            .build();
        let base = url.trim_end_matches('/').to_owned();
        Ok(Self {
            agent: Agent::new_with_config(config),
            root: format!("{base}/{FOLDER}"),
            base,
            auth: basic_auth(username, password),
            known_dirs: Mutex::default(),
        })
    }

    /// The URL of `name`, a `/`-separated path below the `LeafPDF` folder.
    fn url(&self, name: &str) -> String {
        let mut url = self.root.clone();
        for part in name.split('/').filter(|part| !part.is_empty()) {
            url.push('/');
            url.push_str(&encode(part));
        }
        url
    }

    /// Sends a request with `body`. Any answer is returned, whatever its
    /// status, except for a rejected login.
    fn send(
        &self,
        method: &str,
        url: &str,
        headers: &[(&str, &str)],
        body: SendBody,
    ) -> io::Result<Response<Body>> {
        let mut request = Request::builder()
            .method(method)
            .uri(url)
            .header("Authorization", &self.auth);
        for (name, value) in headers {
            request = request.header(*name, *value);
        }
        let request = request.body(body).map_err(io::Error::other)?;
        let response = self.agent.run(request).map_err(ureq::Error::into_io)?;
        if response.status().as_u16() == 401 {
            return Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "401 Unauthorized",
            ));
        }
        Ok(response)
    }

    fn call(&self, method: &str, url: &str, headers: &[(&str, &str)]) -> io::Result<u16> {
        let response = self.send(method, url, headers, SendBody::none())?;
        Ok(response.status().as_u16())
    }

    fn propfind(&self, url: &str, depth: &str) -> io::Result<Response<Body>> {
        const WANTED: &str = r#"<?xml version="1.0"?><propfind xmlns="DAV:"><prop><resourcetype/><getcontentlength/></prop></propfind>"#;
        let mut body = WANTED.as_bytes();
        self.send(
            "PROPFIND",
            url,
            &[("Depth", depth), ("Content-Type", "application/xml")],
            SendBody::from_reader(&mut body),
        )
    }

    /// Creates the directory at `url`; fine if it exists already.
    fn make_dir(&self, url: &str) -> io::Result<()> {
        match self.call("MKCOL", url, &[])? {
            200..=299 | 405 => Ok(()),
            status => Err(unexpected("MKCOL", status)),
        }
    }

    /// Creates `dir` and its parents, for those not known to exist.
    fn ensure_dirs(&self, dir: &str) -> io::Result<()> {
        let mut path = String::new();
        for part in dir.split('/') {
            if !path.is_empty() {
                path.push('/');
            }
            path.push_str(part);
            let known = self.known_dirs.lock().unwrap().contains(&path);
            if !known {
                self.make_dir(&self.url(&path))?;
                self.known_dirs.lock().unwrap().insert(path.clone());
            }
        }
        Ok(())
    }

    /// Deletes what is at `url`; fine if there is nothing.
    fn remove(&self, url: &str) -> io::Result<()> {
        match self.call("DELETE", url, &[])? {
            200..=299 | 404 => Ok(()),
            status => Err(unexpected("DELETE", status)),
        }
    }

    /// Uploads `data` to `temp`, then moves it over `name`.
    fn upload_and_move(&self, temp: &str, name: &str, data: &mut dyn Read) -> io::Result<()> {
        let uploaded = self.send("PUT", &self.url(temp), &[], SendBody::from_reader(data))?;
        match uploaded.status().as_u16() {
            200..=299 => {}
            status => return Err(unexpected("PUT", status)),
        }
        let destination = self.url(name);
        match self.call(
            "MOVE",
            &self.url(temp),
            &[("Destination", &destination), ("Overwrite", "T")],
        )? {
            200..=299 => Ok(()),
            status => Err(unexpected("MOVE", status)),
        }
    }
}

fn unexpected(method: &str, status: u16) -> io::Error {
    io::Error::other(format!("{method} answered with status {status}"))
}

impl Storage for WebDavStorage {
    fn put(&self, name: &str, data: &mut dyn Read) -> io::Result<()> {
        check_name(name)?;
        if let Some((parent, _)) = name.rsplit_once('/') {
            self.ensure_dirs(parent)?;
        }
        self.ensure_dirs(INCOMING)?;
        // The temporary names of all Devices share one directory.
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_or(0, |t| t.as_nanos());
        let temp = format!("{INCOMING}/{nanos}-{}", unique_name());
        let result = self.upload_and_move(&temp, name, data);
        if result.is_err() {
            let _ = self.remove(&self.url(&temp));
        }
        result
    }

    fn get(&self, name: &str) -> io::Result<Option<Box<dyn Read + Send>>> {
        check_name(name)?;
        let response = self.send("GET", &self.url(name), &[], SendBody::none())?;
        match response.status().as_u16() {
            200..=299 => Ok(Some(Box::new(response.into_body().into_reader()))),
            404 => Ok(None),
            status => Err(unexpected("GET", status)),
        }
    }

    fn list(&self, dir: &str) -> io::Result<Vec<Blob>> {
        if !dir.is_empty() {
            check_name(dir)?;
        }
        let response = self.propfind(&self.url(dir), "1")?;
        match response.status().as_u16() {
            207 => {}
            404 => return Ok(Vec::new()),
            status => return Err(unexpected("PROPFIND", status)),
        }
        let mut xml = String::new();
        response
            .into_body()
            .into_reader()
            .read_to_string(&mut xml)?;
        parse_listing(&xml).map_err(io::Error::other)
    }

    fn delete(&self, name: &str) -> io::Result<()> {
        check_name(name)?;
        self.remove(&self.url(name))
    }
}

/// The blobs in a `PROPFIND` answer: its files, but no directories (the
/// listed one included) and no hidden files.
fn parse_listing(xml: &str) -> Result<Vec<Blob>, quick_xml::Error> {
    #[derive(PartialEq)]
    enum Reading {
        Nothing,
        Href,
        Length,
    }
    let mut reader = Reader::from_str(xml);
    let mut blobs = Vec::new();
    let (mut href, mut size, mut is_dir) = (String::new(), 0, false);
    let mut reading = Reading::Nothing;
    let mut text = String::new();
    loop {
        match reader.read_event()? {
            Event::Start(tag) | Event::Empty(tag) => match tag.local_name().as_ref() {
                "response" => (href, size, is_dir) = (String::new(), 0, false),
                "href" => (reading, text) = (Reading::Href, String::new()),
                "getcontentlength" => (reading, text) = (Reading::Length, String::new()),
                "collection" => is_dir = true,
                _ => {}
            },
            Event::Text(t) if reading != Reading::Nothing => text.push_str(&t.xml10_content()),
            Event::CData(t) if reading != Reading::Nothing => text.push_str(&t.xml10_content()),
            Event::GeneralRef(r) if reading != Reading::Nothing => {
                match (r.resolve_char_ref()?, &*r) {
                    (Some(c), _) => text.push(c),
                    (None, "amp") => text.push('&'),
                    (None, "lt") => text.push('<'),
                    (None, "gt") => text.push('>'),
                    (None, "quot") => text.push('"'),
                    (None, "apos") => text.push('\''),
                    _ => {}
                }
            }
            Event::End(tag) => match tag.local_name().as_ref() {
                "href" => (href, reading) = (decode(&text), Reading::Nothing),
                // A missing size (a 404 `propstat`) stays as it was.
                "getcontentlength" => {
                    size = text.trim().parse().unwrap_or(size);
                    reading = Reading::Nothing;
                }
                "response" => {
                    let name = href.trim_end_matches('/').rsplit('/').next().unwrap_or("");
                    if !is_dir && !name.is_empty() && !name.starts_with('.') {
                        blobs.push(Blob {
                            name: name.to_owned(),
                            size,
                        });
                    }
                }
                _ => {}
            },
            Event::Eof => return Ok(blobs),
            _ => {}
        }
    }
}

/// Percent-encodes a path segment: everything but unreserved characters.
fn encode(part: &str) -> String {
    let mut out = String::with_capacity(part.len());
    for byte in part.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' => {
                out.push(byte as char);
            }
            _ => out.push_str(&format!("%{byte:02X}")),
        }
    }
    out
}

/// Reverses percent-encoding; invalid escapes stay as they are.
fn decode(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        let escaped = (bytes[i] == b'%')
            .then(|| bytes.get(i + 1..i + 3))
            .flatten()
            .and_then(|hex| std::str::from_utf8(hex).ok())
            .and_then(|hex| u8::from_str_radix(hex, 16).ok());
        match escaped {
            Some(byte) => {
                out.push(byte);
                i += 3;
            }
            None => {
                out.push(bytes[i]);
                i += 1;
            }
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// The `Authorization` header value for Basic auth (RFC 7617).
fn basic_auth(username: &str, password: &str) -> String {
    const DIGITS: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let input = format!("{username}:{password}");
    let mut out = String::from("Basic ");
    for group in input.as_bytes().chunks(3) {
        let n = group
            .iter()
            .enumerate()
            .fold(0u32, |n, (i, b)| n | u32::from(*b) << (16 - 8 * i));
        for i in 0..4 {
            if i <= group.len() {
                out.push(DIGITS[(n >> (18 - 6 * i) & 63) as usize] as char);
            } else {
                out.push('=');
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::library::{ImportResult, Library};
    use crate::storage::contract::{Scratch, storage_contract_tests};
    use std::fs;
    use std::net::TcpListener;
    use std::process::{Child, Command, Stdio};
    use std::thread::sleep;

    const USER: &str = "reader";
    const PASSWORD: &str = "s3cret";

    /// An `rclone serve` process on localhost with a fresh self-signed
    /// certificate, serving a directory. None when rclone or openssl isn't
    /// installed, so tests skip. The certificate is short-lived because Apple's
    /// TLS refuses long validity periods.
    struct Rclone {
        child: Child,
        url: String,
        cert: String,
        dir: Scratch,
        _certs: Scratch,
    }

    impl Rclone {
        fn start(protocol: &str) -> Option<Self> {
            let installed = |tool: &str, arg: &str| {
                Command::new(tool)
                    .arg(arg)
                    .stdout(Stdio::null())
                    .status()
                    .is_ok_and(|status| status.success())
            };
            if !installed("rclone", "version") || !installed("openssl", "version") {
                eprintln!("skipped: rclone or openssl is not installed");
                return None;
            }
            let port = TcpListener::bind("127.0.0.1:0")
                .unwrap()
                .local_addr()
                .unwrap()
                .port();
            let dir = Scratch::new("webdav-served");
            let certs = Scratch::new("webdav-certs");
            let cert = certs.0.join("localhost.crt");
            let key = certs.0.join("localhost.key");
            let made = Command::new("openssl")
                .args(["req", "-x509", "-newkey", "ec", "-pkeyopt"])
                .args(["ec_paramgen_curve:prime256v1", "-nodes", "-days", "30"])
                .args(["-subj", "/CN=localhost"])
                .args(["-addext", "subjectAltName=DNS:localhost,IP:127.0.0.1"])
                .args(["-addext", "extendedKeyUsage=serverAuth"])
                .arg("-keyout")
                .arg(&key)
                .arg("-out")
                .arg(&cert)
                .stderr(Stdio::null())
                .status()
                .unwrap();
            assert!(made.success(), "openssl could not make a certificate");
            let child = Command::new("rclone")
                .args(["serve", protocol])
                .arg(&dir.0)
                .args(["--addr", &format!("127.0.0.1:{port}")])
                .args(["--user", USER, "--pass", PASSWORD])
                .arg("--cert")
                .arg(&cert)
                .arg("--key")
                .arg(&key)
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn()
                .unwrap();
            let server = Self {
                child,
                url: format!("https://127.0.0.1:{port}"),
                cert: fs::read_to_string(&cert).unwrap(),
                dir,
                _certs: certs,
            };
            for _ in 0..200 {
                if std::net::TcpStream::connect(("127.0.0.1", port)).is_ok() {
                    return Some(server);
                }
                sleep(Duration::from_millis(25));
            }
            panic!("rclone did not start");
        }

        fn webdav() -> Option<Self> {
            Self::start("webdav")
        }

        fn connect(&self) -> Result<WebDavStorage, ConnectError> {
            self.connect_as(USER, PASSWORD)
        }

        fn connect_as(&self, user: &str, pass: &str) -> Result<WebDavStorage, ConnectError> {
            let tls = trusting(&self.cert);
            WebDavStorage::connect_with(&self.url, user, pass, tls)
        }

        fn stop(&mut self) {
            let _ = self.child.kill();
            let _ = self.child.wait();
        }
    }

    impl Drop for Rclone {
        fn drop(&mut self) {
            self.stop();
        }
    }

    fn trusting(cert: &str) -> ureq::tls::TlsConfig {
        let der = pem_to_der(cert);
        let roots = ureq::tls::RootCerts::new_with_certs(&[
            ureq::tls::Certificate::from_der(&der).to_owned()
        ]);
        ureq::tls::TlsConfig::builder()
            .provider(tls_config().provider())
            .root_certs(roots)
            .build()
    }

    /// The DER bytes of the one certificate in `pem`.
    fn pem_to_der(pem: &str) -> Vec<u8> {
        let body: String = pem.lines().filter(|l| !l.starts_with("-----")).collect();
        let mut out = Vec::new();
        let mut bits = 0u32;
        let mut count = 0;
        for c in body.bytes().filter(|c| *c != b'=') {
            let value = match c {
                b'A'..=b'Z' => c - b'A',
                b'a'..=b'z' => c - b'a' + 26,
                b'0'..=b'9' => c - b'0' + 52,
                b'+' => 62,
                _ => 63,
            };
            bits = bits << 6 | u32::from(value);
            count += 6;
            if count >= 8 {
                count -= 8;
                out.push((bits >> count) as u8);
            }
        }
        out
    }

    fn webdav_storage() -> Option<(Rclone, WebDavStorage)> {
        let server = Rclone::webdav()?;
        let storage = server.connect().unwrap();
        Some((server, storage))
    }

    mod webdav_storage {
        use super::*;
        storage_contract_tests!(webdav_storage);
    }

    #[test]
    fn basic_auth_is_base64_of_user_and_password() {
        // RFC 7617's example, and each padding length.
        assert_eq!(
            basic_auth("Aladdin", "open sesame"),
            "Basic QWxhZGRpbjpvcGVuIHNlc2FtZQ=="
        );
        assert_eq!(basic_auth("a", "b"), "Basic YTpi");
        assert_eq!(basic_auth("ab", "c"), "Basic YWI6Yw==");
        assert_eq!(basic_auth("a", ""), "Basic YTo=");
    }

    #[test]
    fn listing_gives_files_but_no_directories_hidden_files_or_the_listed_directory() {
        let xml = r#"<?xml version="1.0" encoding="utf-8"?>
            <D:multistatus xmlns:D="DAV:">
              <D:response><D:href>/dav/LeafPDF/v1/</D:href>
                <D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop></D:propstat>
              </D:response>
              <D:response><D:href>/dav/LeafPDF/v1/a%20b&amp;c</D:href>
                <D:propstat><D:prop><D:resourcetype/><D:getcontentlength>12</D:getcontentlength></D:prop></D:propstat>
              </D:response>
              <response xmlns="DAV:"><href>https://host/dav/LeafPDF/v1/sub/</href>
                <propstat><prop><resourcetype><collection></collection></resourcetype></prop></propstat>
              </response>
              <D:response><D:href>/dav/LeafPDF/v1/.hidden</D:href>
                <D:propstat><D:prop><D:getcontentlength>3</D:getcontentlength></D:prop></D:propstat>
              </D:response>
              <D:response><D:href>/dav/LeafPDF/v1/x</D:href>
                <D:propstat><D:prop><D:getcontentlength>7</D:getcontentlength></D:prop></D:propstat>
                <D:propstat><D:prop><D:foo/></D:prop><D:status>HTTP/1.1 404 Not Found</D:status></D:propstat>
              </D:response>
            </D:multistatus>"#;

        let blobs = parse_listing(xml).unwrap();

        let expected = [("a b&c", 12), ("x", 7)];
        let listed: Vec<_> = blobs.iter().map(|b| (b.name.as_str(), b.size)).collect();
        assert_eq!(listed, expected);
    }

    #[test]
    fn names_are_percent_encoded_in_urls() {
        assert_eq!(encode("a b/ü"), "a%20b%2F%C3%BC");
        assert_eq!(decode("a%20b%2f%C3%BC%zz%"), "a b/ü%zz%");
    }

    #[test]
    fn connecting_needs_an_https_url() {
        for url in [
            "http://example.com",
            "example.com",
            "ftp://x",
            "",
            "https:/x",
        ] {
            let error = WebDavStorage::connect(url, "u", "p").unwrap_err();
            assert_eq!(error, ConnectError::NotHttps, "{url:?}");
        }
    }

    #[test]
    fn resuming_needs_an_https_url_but_contacts_no_server() {
        assert_eq!(
            WebDavStorage::resume("http://example.com", "u", "p").unwrap_err(),
            ConnectError::NotHttps
        );
        // Nobody listens there: resuming works offline, using it fails.
        let storage = WebDavStorage::resume("https://127.0.0.1:1", "u", "p").unwrap();
        assert!(storage.list("").is_err());
    }

    #[test]
    fn connecting_to_nothing_is_unreachable() {
        let port = TcpListener::bind("127.0.0.1:0")
            .unwrap()
            .local_addr()
            .unwrap()
            .port();
        let url = format!("https://127.0.0.1:{port}");
        let error = WebDavStorage::connect(&url, "u", "p").unwrap_err();
        assert_eq!(error, ConnectError::Unreachable);
    }

    #[test]
    fn connecting_with_a_wrong_password_or_user_is_wrong_credentials() {
        let Some(server) = Rclone::webdav() else {
            return;
        };
        for (user, pass) in [(USER, "nope"), ("nobody", PASSWORD), ("", "")] {
            let error = server.connect_as(user, pass).unwrap_err();
            assert_eq!(error, ConnectError::WrongCredentials, "{user:?}");
        }
    }

    #[test]
    fn connecting_to_a_server_that_is_no_webdav_server_is_not_webdav() {
        let Some(server) = Rclone::start("http") else {
            return;
        };
        assert_eq!(server.connect().unwrap_err(), ConnectError::NotWebDav);
    }

    #[test]
    fn a_certificate_nobody_vouches_for_is_unreachable() {
        let Some(server) = Rclone::webdav() else {
            return;
        };
        let error = WebDavStorage::connect(&server.url, USER, PASSWORD).unwrap_err();
        assert_eq!(error, ConnectError::Unreachable);
    }

    #[test]
    fn connecting_creates_the_leafpdf_folder_and_reuses_it() {
        let Some(server) = Rclone::webdav() else {
            return;
        };
        let folder = server.dir.0.join(FOLDER);
        assert!(!folder.exists());

        let first = server.connect().unwrap();
        assert!(folder.is_dir());
        first.put("v1/blob", &mut &b"kept"[..]).unwrap();

        let second = server.connect().unwrap();
        assert_eq!(
            crate::storage::get_bytes(&second, "v1/blob")
                .unwrap()
                .unwrap(),
            b"kept"
        );
        assert_eq!(fs::read(folder.join("v1/blob")).unwrap(), b"kept");
    }

    #[test]
    fn a_url_with_a_path_keeps_everything_inside_it() {
        let Some(server) = Rclone::webdav() else {
            return;
        };
        fs::create_dir(server.dir.0.join("my files")).unwrap();

        let url = format!("{}/my%20files/", server.url);
        let storage =
            WebDavStorage::connect_with(&url, USER, PASSWORD, trusting(&server.cert)).unwrap();
        storage.put("blob", &mut &b"x"[..]).unwrap();

        assert!(server.dir.0.join("my files/LeafPDF/blob").is_file());
    }

    #[test]
    fn rejected_credentials_during_use_differ_from_being_offline() {
        let Some((mut server, mut storage)) = webdav_storage() else {
            return;
        };
        storage.put("blob", &mut &b"x"[..]).unwrap();

        // The password changed on the server.
        storage.auth = basic_auth(USER, "changed");
        for error in [
            storage.list("").unwrap_err(),
            storage.get("blob").map(|_| ()).unwrap_err(),
            storage.put("other", &mut &b"y"[..]).unwrap_err(),
            storage.delete("blob").unwrap_err(),
        ] {
            assert_eq!(error.kind(), io::ErrorKind::PermissionDenied);
        }

        // The server went away.
        storage.auth = basic_auth(USER, PASSWORD);
        server.stop();
        let error = storage.list("").unwrap_err();
        assert_ne!(error.kind(), io::ErrorKind::PermissionDenied);
    }

    #[test]
    fn two_libraries_sync_their_documents_and_files_through_webdav() {
        let Some(server) = Rclone::webdav() else {
            return;
        };
        let home = Scratch::new("webdav-devices");
        let open = |device: &str| Library::open(home.0.join(device).join("library")).unwrap();
        let (a, b) = (open("a"), open("b"));
        let source = home.0.join("Paper.pdf");
        fs::write(&source, b"%PDF-paper bytes").unwrap();
        let ImportResult::Imported(imported) = a.import(&source, |_, _| {}).unwrap() else {
            panic!("not imported");
        };

        a.sync(&server.connect().unwrap()).unwrap();
        b.sync(&server.connect().unwrap()).unwrap();

        let documents = b.documents().unwrap();
        assert_eq!(documents.len(), 1);
        assert_eq!(documents[0].id, imported.id);
        assert_eq!(fs::read(&documents[0].path).unwrap(), b"%PDF-paper bytes");
        assert_eq!(documents[0].path.file_name().unwrap(), "Paper.pdf");
    }
}
