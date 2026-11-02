//! What the local fakes of a Cloud Provider's API share, for tests: an HTTP
//! server on a free port, and the OAuth token endpoint with the access and
//! refresh tokens it hands out.

use crate::storage::RefreshTokenCallback;
use serde_json::{Value, json};
use std::collections::{HashMap, HashSet};
use std::fmt::Write as _;
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{SocketAddr, TcpListener, TcpStream};
use std::sync::atomic::{AtomicBool, Ordering::Relaxed};
use std::sync::{Arc, Mutex};
use std::thread;

pub(crate) struct Request {
    pub method: String,
    /// Percent-decoded.
    pub path: String,
    pub query: HashMap<String, String>,
    /// Names in lower case.
    pub headers: HashMap<String, String>,
    pub body: Vec<u8>,
}

pub(crate) struct Reply {
    pub status: u16,
    pub headers: Vec<(&'static str, String)>,
    pub body: Vec<u8>,
}

pub(crate) fn reply(status: u16, body: Value) -> Reply {
    Reply {
        status,
        headers: vec![("Content-Type", "application/json".to_owned())],
        body: body.to_string().into_bytes(),
    }
}

pub(crate) fn nothing(status: u16) -> Reply {
    Reply {
        status,
        headers: Vec::new(),
        body: Vec::new(),
    }
}

/// Keeps the refresh tokens it is told about.
#[derive(Default)]
pub(crate) struct Recorder(pub Mutex<Vec<String>>);

impl RefreshTokenCallback for Recorder {
    fn new_refresh_token(&self, token: &str) {
        self.0.lock().unwrap().push(token.to_owned());
    }
}

/// The OAuth side of a fake provider.
pub(crate) struct Auth {
    client: String,
    /// The access tokens that work.
    tokens: HashSet<String>,
    issued: u64,
    /// The refresh token that works.
    refresh: String,
    /// The next refresh gives this one, which replaces the old.
    pub rotate_to: Option<String>,
    revoked: bool,
    /// What the authorization code exchange answers to, if the user consented.
    pub consent: Option<Consent>,
}

/// A consent to the provider's page: the authorization code its redirect
/// carries, and what exchanging that code answers.
pub(crate) struct Consent {
    pub code: String,
    /// The PKCE verifier the exchange has to prove.
    pub verifier: String,
    pub redirect_uri: String,
    /// The scope the token response grants.
    pub scope: String,
    /// The refresh token the token response gives, if any.
    pub refresh: Option<String>,
}

impl Auth {
    pub fn new(client: &str, refresh: &str) -> Self {
        Self {
            client: client.to_owned(),
            tokens: HashSet::new(),
            issued: 0,
            refresh: refresh.to_owned(),
            rotate_to: None,
            revoked: false,
            consent: None,
        }
    }

    /// The access tokens given so far stop working, as after an hour.
    pub fn expire_access_tokens(&mut self) {
        self.tokens.clear();
    }

    /// The refresh token stops working too.
    pub fn revoke(&mut self) {
        self.revoked = true;
        self.expire_access_tokens();
    }

    fn allows(&self, request: &Request) -> bool {
        let bearer = request.headers.get("authorization");
        let bearer = bearer.and_then(|value| value.strip_prefix("Bearer "));
        bearer.is_some_and(|token| self.tokens.contains(token))
    }

    /// The answer to a token request, a refresh or an authorization code
    /// exchange, `form` being the request's body.
    fn token(&mut self, form: &str) -> Reply {
        let form: HashMap<_, _> = form
            .split('&')
            .filter_map(|pair| pair.split_once('='))
            .map(|(key, value)| (key, crate::percent::decode(value)))
            .collect();
        let field = |name| form.get(name).map_or("", String::as_str);
        let refused = reply(400, json!({"error": "invalid_grant"}));
        if self.revoked || field("client_id") != self.client {
            return refused;
        }
        // What the answer says beyond the access token.
        let mut extra = serde_json::Map::new();
        match field("grant_type") {
            "refresh_token" if field("refresh_token") == self.refresh => {
                if let Some(rotated) = self.rotate_to.take() {
                    extra.insert("refresh_token".into(), json!(rotated));
                    self.refresh = rotated;
                }
            }
            "authorization_code" => {
                let Some(consent) = &self.consent else {
                    return refused;
                };
                let proven = field("code") == consent.code
                    && field("code_verifier") == consent.verifier
                    && field("redirect_uri") == consent.redirect_uri;
                if !proven {
                    return refused;
                }
                extra.insert("scope".into(), json!(consent.scope));
                if let Some(refresh) = &consent.refresh {
                    extra.insert("refresh_token".into(), json!(refresh));
                }
            }
            _ => return refused,
        }
        self.issued += 1;
        let token = format!("access-{}", self.issued);
        self.tokens.insert(token.clone());
        let mut answer = json!({"access_token": token, "expires_in": 3600, "token_type": "Bearer"});
        answer.as_object_mut().unwrap().extend(extra);
        reply(200, answer)
    }
}

/// A fake provider's API: what it answers to requests that carry a working
/// access token.
pub(crate) trait Api: Send + 'static {
    fn auth(&mut self) -> &mut Auth;

    /// Whether `request` needs no access token, like an upload to a URL the
    /// provider has handed out.
    fn is_public(&self, _request: &Request) -> bool {
        false
    }

    /// The answer to `request`. `base` is the server's own address, for
    /// links to itself.
    fn route(&mut self, request: &Request, base: &str) -> Reply;
}

/// An API served over plain HTTP on a free port, until dropped. The token
/// endpoint is at `/token`; any other request without a working access token
/// is answered with 401.
pub(crate) struct Server<S> {
    pub base: String,
    pub state: Arc<Mutex<S>>,
    addr: SocketAddr,
    stop: Arc<AtomicBool>,
}

impl<S: Api> Server<S> {
    pub fn start(api: S) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let base = format!("http://{addr}");
        let state = Arc::new(Mutex::new(api));
        let stop = Arc::new(AtomicBool::new(false));
        let (served, halt, address) = (state.clone(), stop.clone(), base.clone());
        thread::spawn(move || {
            for stream in listener.incoming() {
                if halt.load(Relaxed) {
                    break;
                }
                let (Ok(mut stream), served, address) = (stream, served.clone(), address.clone())
                else {
                    continue;
                };
                thread::spawn(move || {
                    let Some(request) = read_request(&stream) else {
                        return;
                    };
                    let answer = answer(&mut *served.lock().unwrap(), &request, &address);
                    let mut head = format!("HTTP/1.1 {} X\r\n", answer.status);
                    for (name, value) in &answer.headers {
                        _ = write!(head, "{name}: {value}\r\n");
                    }
                    _ = write!(
                        head,
                        "Content-Length: {}\r\nConnection: close\r\n\r\n",
                        answer.body.len()
                    );
                    let _ = stream.write_all(head.as_bytes());
                    let _ = stream.write_all(&answer.body);
                });
            }
        });
        Self {
            base,
            state,
            addr,
            stop,
        }
    }
}

impl<S> Drop for Server<S> {
    fn drop(&mut self) {
        self.stop.store(true, Relaxed);
        let _ = TcpStream::connect(self.addr);
    }
}

fn answer(api: &mut impl Api, request: &Request, base: &str) -> Reply {
    if request.path == "/token" {
        return api.auth().token(&String::from_utf8_lossy(&request.body));
    }
    if !api.is_public(request) && !api.auth().allows(request) {
        return reply(401, json!({"error": {"code": 401}}));
    }
    api.route(request, base)
}

fn read_request(stream: &TcpStream) -> Option<Request> {
    let mut input = BufReader::new(stream);
    let mut line = String::new();
    input.read_line(&mut line).ok()?;
    let mut parts = line.split_whitespace();
    let (method, target) = (parts.next()?.to_owned(), parts.next()?.to_owned());
    let (path, query) = target.split_once('?').unwrap_or((&target, ""));
    let query = query
        .split('&')
        .filter_map(|pair| pair.split_once('='))
        .map(|(key, value)| (key.to_owned(), crate::percent::decode(value)))
        .collect();
    let mut headers = HashMap::new();
    loop {
        line.clear();
        input.read_line(&mut line).ok()?;
        let Some((name, value)) = line.trim_end().split_once(':') else {
            break;
        };
        headers.insert(name.to_lowercase(), value.trim().to_owned());
    }
    let length = headers
        .get("content-length")
        .and_then(|l| l.parse().ok())
        .unwrap_or(0);
    let mut body = vec![0; length];
    input.read_exact(&mut body).ok()?;
    Some(Request {
        method,
        path: crate::percent::decode(path),
        query,
        headers,
        body,
    })
}
