//! The Google Drive storage: a Cloud Provider (ADR-0010) that keeps everything
//! in one folder of the user's Drive.
//!
//! Scope `drive.file` (ADR-0011), so only files LeafPDF created are visible.
//! Drive has no paths: names map to IDs through the folder hierarchy below the
//! root folder. Small blobs upload in one request, bigger ones through a
//! resumable upload, which is never resumed: an interrupted `put` starts over
//! the next time. Deletes are permanent (ADR-0016).

use crate::cloud_http::{OAuthClient, unexpected, upload_chunks};
use crate::percent::encode;
use crate::storage::{Blob, RefreshTokenCallback, Storage, check_name, unique_name};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::fmt;
use std::io::{self, Read};
use std::sync::{Arc, Mutex};
use ureq::Body;
use ureq::http::Response;

const API: &str = "https://www.googleapis.com";
const TOKEN_URL: &str = "https://oauth2.googleapis.com/token";
/// The folder in My Drive that holds everything.
const APP_FOLDER: &str = "LeafPDF";
const FOLDER_MIME: &str = "application/vnd.google-apps.folder";

/// Blobs up to this many bytes upload in one request. They are held in memory.
const SIMPLE_LIMIT: usize = 5 << 20;
/// The size of a part of a resumable upload. Drive wants a multiple of 256 KiB.
const CHUNK_SIZE: usize = 8 << 20;

/// Where the API is and how uploads are cut. Tests point it at a fake.
struct Config {
    api: String,
    token_url: String,
    allow_http: bool,
    simple_limit: usize,
    chunk_size: usize,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            api: API.to_owned(),
            token_url: TOKEN_URL.to_owned(),
            allow_http: false,
            simple_limit: SIMPLE_LIMIT,
            chunk_size: CHUNK_SIZE,
        }
    }
}

/// A file or folder in Drive.
struct Item {
    id: String,
    name: String,
    size: u64,
    /// RFC 3339 in UTC, so it sorts as text.
    created: String,
}

/// The `LeafPDF` folder of a Google Drive and everything below it.
///
/// Errors tell why a request failed, see `cloud_http::OAuthClient`: revoked
/// access is `PermissionDenied`, a full Drive is `QuotaExceeded`.
pub struct GoogleDriveStorage {
    oauth: OAuthClient,
    api: String,
    simple_limit: usize,
    chunk_size: usize,
    /// The ID of the folder that is `""`.
    root: String,
    /// Folders known to exist, by path below the root, so a request doesn't
    /// look them up each time.
    folders: Mutex<HashMap<String, String>>,
}

impl fmt::Debug for GoogleDriveStorage {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        // No credentials.
        f.debug_struct("GoogleDriveStorage")
            .field("root", &self.root)
            .finish_non_exhaustive()
    }
}

impl GoogleDriveStorage {
    /// Connects to the Drive of the user who owns `refresh_token`, a token of
    /// the public OAuth client `client_id`, and returns the storage with the
    /// user's account (email, empty if Drive doesn't tell). See `resume`.
    /// Rotated refresh tokens are reported to `on_new_refresh_token`.
    pub fn connect(
        client_id: &str,
        refresh_token: &str,
        on_new_refresh_token: Arc<dyn RefreshTokenCallback>,
    ) -> io::Result<(Self, String)> {
        let config = Config::default();
        Self::connect_with(client_id, refresh_token, on_new_refresh_token, config)
    }

    /// The storage of a Drive that was connected before, e.g. at the last
    /// launch. Looks up the `LeafPDF` folder in My Drive's root by name, so a
    /// renamed or trashed one isn't found, and creates it if missing. Of
    /// several, the oldest counts, then the lowest ID.
    pub fn resume(
        client_id: &str,
        refresh_token: &str,
        on_new_refresh_token: Arc<dyn RefreshTokenCallback>,
    ) -> io::Result<Self> {
        let config = Config::default();
        Self::resume_with(client_id, refresh_token, on_new_refresh_token, config)
    }

    fn connect_with(
        client_id: &str,
        refresh_token: &str,
        on_new_refresh_token: Arc<dyn RefreshTokenCallback>,
        config: Config,
    ) -> io::Result<(Self, String)> {
        let storage = Self::resume_with(client_id, refresh_token, on_new_refresh_token, config)?;
        // Needs no scope beyond `drive.file`.
        let url = format!("{}/drive/v3/about?fields=user(emailAddress)", storage.api);
        let about = storage.json("GET", &url, None)?;
        let account = about["user"]["emailAddress"].as_str().unwrap_or_default();
        Ok((storage, account.to_owned()))
    }

    fn resume_with(
        client_id: &str,
        refresh_token: &str,
        on_new_refresh_token: Arc<dyn RefreshTokenCallback>,
        config: Config,
    ) -> io::Result<Self> {
        // Until the folder is found, the root is My Drive's, by Drive's alias.
        let mut storage = Self::at(
            client_id,
            refresh_token,
            "root",
            on_new_refresh_token,
            config,
        );
        let found = storage.items("root", true, Some(APP_FOLDER))?.into_iter();
        storage.root = match found.map(|folder| folder.id).next() {
            Some(id) => id,
            None => storage.make_folder("root", APP_FOLDER)?,
        };
        Ok(storage)
    }

    /// The storage in the folder `root`, without any request.
    fn at(
        client_id: &str,
        refresh_token: &str,
        root: &str,
        on_new_refresh_token: Arc<dyn RefreshTokenCallback>,
        config: Config,
    ) -> Self {
        Self {
            oauth: OAuthClient::new(
                &config.token_url,
                client_id,
                refresh_token,
                on_new_refresh_token,
                config.allow_http,
            ),
            api: config.api,
            simple_limit: config.simple_limit,
            chunk_size: config.chunk_size,
            root: root.to_owned(),
            folders: Mutex::default(),
        }
    }

    /// The JSON answer to a request that must succeed.
    fn json(&self, method: &str, url: &str, body: Option<&Value>) -> io::Result<Value> {
        let body = body.map(Value::to_string).unwrap_or_default();
        let headers = [("Content-Type", "application/json; charset=UTF-8")];
        let mut response = self.oauth.send(method, url, &headers, body.as_bytes())?;
        succeeded(method, &response)?;
        let answer = response
            .body_mut()
            .read_to_string()
            .map_err(io::Error::other)?;
        Ok(serde_json::from_str(&answer)?)
    }

    /// The not trashed folders, or the other files, directly in the folder
    /// `parent`, with that `name` if given. The oldest comes first, which is
    /// the one that counts if there are several of one name.
    fn items(&self, parent: &str, folders: bool, name: Option<&str>) -> io::Result<Vec<Item>> {
        let operator = if folders { "=" } else { "!=" };
        let mut query = format!(
            "'{parent}' in parents and trashed = false and mimeType {operator} '{FOLDER_MIME}'"
        );
        if let Some(name) = name {
            let name = name.replace('\\', "\\\\").replace('\'', "\\'");
            query.push_str(&format!(" and name = '{name}'"));
        }
        let fields = "nextPageToken,files(id,name,size,createdTime)";
        let mut items = Vec::new();
        let mut page = String::new();
        loop {
            let url = format!(
                "{}/drive/v3/files?pageSize=1000&q={}&fields={}&pageToken={}",
                self.api,
                encode(&query),
                encode(fields),
                encode(&page)
            );
            let answer = self.json("GET", &url, None)?;
            for file in answer["files"].as_array().into_iter().flatten() {
                let text = |key| file[key].as_str().unwrap_or_default().to_owned();
                items.push(Item {
                    id: text("id"),
                    name: text("name"),
                    // A string; missing for files that aren't blobs.
                    size: file["size"]
                        .as_str()
                        .and_then(|s| s.parse().ok())
                        .unwrap_or(0),
                    created: text("createdTime"),
                });
            }
            match answer["nextPageToken"].as_str() {
                Some(next) => page = next.to_owned(),
                None => break,
            }
        }
        items.sort_by(|a, b| (&a.created, &a.id).cmp(&(&b.created, &b.id)));
        Ok(items)
    }

    /// The ID of directory `dir`, created if `create`. None if it isn't there.
    fn folder(&self, dir: &str, create: bool) -> io::Result<Option<String>> {
        let mut id = self.root.clone();
        let mut path = String::new();
        for part in dir.split('/').filter(|part| !part.is_empty()) {
            if !path.is_empty() {
                path.push('/');
            }
            path.push_str(part);
            let known = self.folders.lock().unwrap().get(&path).cloned();
            id = match known {
                Some(known) => known,
                None => {
                    let found = self.items(&id, true, Some(part))?.into_iter().next();
                    let found = match found {
                        Some(found) => found.id,
                        None if create => self.make_folder(&id, part)?,
                        None => return Ok(None),
                    };
                    self.folders
                        .lock()
                        .unwrap()
                        .insert(path.clone(), found.clone());
                    found
                }
            };
        }
        Ok(Some(id))
    }

    /// Creates folder `name` in `parent`, and returns the ID of the one to use:
    /// another Device may have created it at the same moment. Then the oldest
    /// wins, and a loser deletes its folder, which is still empty.
    fn make_folder(&self, parent: &str, name: &str) -> io::Result<String> {
        let url = format!("{}/drive/v3/files?fields=id", self.api);
        let made = self.json(
            "POST",
            &url,
            Some(&json!({"name": name, "mimeType": FOLDER_MIME, "parents": [parent]})),
        )?;
        let mine = made["id"].as_str().unwrap_or_default().to_owned();
        let winner = self.items(parent, true, Some(name))?.into_iter().next();
        match winner {
            Some(winner) if winner.id != mine => {
                self.remove(&mine)?;
                Ok(winner.id)
            }
            _ => Ok(mine),
        }
    }

    /// Deletes file or folder `id` for good; fine if it's gone.
    fn remove(&self, id: &str) -> io::Result<()> {
        let url = format!("{}/drive/v3/files/{id}", self.api);
        let response = self.oauth.send("DELETE", &url, &[], &[])?;
        match response.status().as_u16() {
            200..=299 | 404 => Ok(()),
            status => Err(unexpected("DELETE", status)),
        }
    }

    /// Uploads `bytes` in one request, as a new blob `name` in `parent`, or
    /// over the file `existing`.
    fn upload_whole(
        &self,
        parent: &str,
        name: &str,
        existing: Option<&str>,
        bytes: &[u8],
    ) -> io::Result<()> {
        let upload = format!("{}/upload/drive/v3/files", self.api);
        let response = match existing {
            Some(id) => self.oauth.send(
                "PATCH",
                &format!("{upload}/{id}?uploadType=media"),
                &[("Content-Type", "application/octet-stream")],
                bytes,
            )?,
            None => {
                let boundary = format!("leafpdf-{}", unique_name());
                let metadata = json!({"name": name, "parents": [parent]});
                let mut body = format!(
                    "--{boundary}\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n{metadata}\r\n\
                     --{boundary}\r\nContent-Type: application/octet-stream\r\n\r\n"
                )
                .into_bytes();
                body.extend_from_slice(bytes);
                body.extend_from_slice(format!("\r\n--{boundary}--").as_bytes());
                let content_type = format!("multipart/related; boundary={boundary}");
                self.oauth.send(
                    "POST",
                    &format!("{upload}?uploadType=multipart&fields=id"),
                    &[("Content-Type", &content_type)],
                    &body,
                )?
            }
        };
        succeeded("upload", &response)
    }

    /// Uploads everything `data` yields through a resumable upload.
    fn upload_in_chunks(
        &self,
        parent: &str,
        name: &str,
        existing: Option<&str>,
        data: &mut dyn Read,
    ) -> io::Result<()> {
        let upload = format!("{}/upload/drive/v3/files", self.api);
        let (method, url, metadata) = match existing {
            Some(id) => (
                "PATCH",
                format!("{upload}/{id}?uploadType=resumable"),
                json!({}),
            ),
            None => (
                "POST",
                format!("{upload}?uploadType=resumable&fields=id"),
                json!({"name": name, "parents": [parent]}),
            ),
        };
        let headers = [("Content-Type", "application/json; charset=UTF-8")];
        let started = self
            .oauth
            .send(method, &url, &headers, metadata.to_string().as_bytes())?;
        succeeded("upload", &started)?;
        let session = started
            .headers()
            .get("location")
            .and_then(|location| location.to_str().ok())
            .ok_or_else(|| io::Error::other("the upload has no session"))?
            .to_owned();

        upload_chunks(data, self.chunk_size, |chunk| {
            let total = chunk
                .total
                .map_or("*".to_owned(), |total| total.to_string());
            let range = if chunk.bytes.is_empty() {
                format!("bytes */{total}")
            } else {
                let last = chunk.offset + chunk.bytes.len() as u64 - 1;
                format!("bytes {}-{last}/{total}", chunk.offset)
            };
            let response =
                self.oauth
                    .send("PUT", &session, &[("Content-Range", &range)], chunk.bytes)?;
            match (response.status().as_u16(), chunk.total) {
                (308, None) | (200 | 201, Some(_)) => Ok(()),
                (status, _) => Err(unexpected("upload", status)),
            }
        })
    }
}

/// An error unless `response` has a 2xx status.
fn succeeded(what: &str, response: &Response<Body>) -> io::Result<()> {
    match response.status().as_u16() {
        200..=299 => Ok(()),
        status => Err(unexpected(what, status)),
    }
}

/// `name` split into its directory (`""` for the root) and the blob's own name.
fn split(name: &str) -> (&str, &str) {
    name.rsplit_once('/').unwrap_or(("", name))
}

impl Storage for GoogleDriveStorage {
    fn put(&self, name: &str, data: &mut dyn Read) -> io::Result<()> {
        check_name(name)?;
        let (dir, leaf) = split(name);
        // A source that fails does so before Drive hears of the blob.
        let mut head = Vec::new();
        data.take(self.simple_limit as u64 + 1)
            .read_to_end(&mut head)?;

        let parent = self.folder(dir, true)?.unwrap_or_default();
        let existing = self.items(&parent, false, Some(leaf))?.into_iter().next();
        let existing = existing.as_ref().map(|item| item.id.as_str());
        if head.len() <= self.simple_limit {
            self.upload_whole(&parent, leaf, existing, &head)
        } else {
            self.upload_in_chunks(&parent, leaf, existing, &mut (&head[..]).chain(data))
        }
    }

    fn get(&self, name: &str) -> io::Result<Option<Box<dyn Read + Send>>> {
        check_name(name)?;
        let (dir, leaf) = split(name);
        let Some(parent) = self.folder(dir, false)? else {
            return Ok(None);
        };
        let Some(file) = self.items(&parent, false, Some(leaf))?.into_iter().next() else {
            return Ok(None);
        };
        let url = format!("{}/drive/v3/files/{}?alt=media", self.api, file.id);
        let response = self.oauth.send("GET", &url, &[], &[])?;
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
        let Some(parent) = self.folder(dir, false)? else {
            return Ok(Vec::new());
        };
        let mut blobs: Vec<Blob> = Vec::new();
        for item in self.items(&parent, false, None)? {
            // Oldest first, so a duplicate of a name is the one `get` reads.
            if !item.name.starts_with('.') && !blobs.iter().any(|blob| blob.name == item.name) {
                blobs.push(Blob {
                    name: item.name,
                    size: item.size,
                });
            }
        }
        Ok(blobs)
    }

    fn delete(&self, name: &str) -> io::Result<()> {
        check_name(name)?;
        let (dir, leaf) = split(name);
        let Some(parent) = self.folder(dir, false)? else {
            return Ok(());
        };
        for item in self.items(&parent, false, Some(leaf))? {
            self.remove(&item.id)?;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::library::{ImportResult, Library};
    use crate::storage::contract::{Scratch, put_bytes, storage_contract_tests};
    use crate::storage::{get_bytes, is_full};
    use std::collections::HashSet;
    use std::fs;
    use std::io::{BufRead, BufReader, Write};
    use std::net::{SocketAddr, TcpListener, TcpStream};
    use std::sync::Arc;
    use std::sync::atomic::{AtomicBool, Ordering::Relaxed};
    use std::thread;
    use std::time::{SystemTime, UNIX_EPOCH};

    const CLIENT: &str = "client-id";
    const REFRESH: &str = "refresh-token";
    const ROOT: &str = "root-folder";
    const ACCOUNT: &str = "reader@example.com";

    struct Stored {
        id: String,
        name: String,
        parent: String,
        folder: bool,
        data: Vec<u8>,
        created: u64,
        trashed: bool,
    }

    /// Keeps the refresh tokens it is told about.
    #[derive(Default)]
    struct Recorder(Mutex<Vec<String>>);

    impl RefreshTokenCallback for Recorder {
        fn new_refresh_token(&self, token: &str) {
            self.0.lock().unwrap().push(token.to_owned());
        }
    }

    /// An upload that waits for its chunks: a new file, or the content of `update`.
    struct Upload {
        update: Option<String>,
        name: String,
        parent: String,
        received: Vec<u8>,
    }

    #[derive(Default)]
    struct State {
        items: Vec<Stored>,
        uploads: HashMap<String, Upload>,
        /// The access tokens that work.
        tokens: HashSet<String>,
        counter: u64,
        /// The refresh token that works.
        refresh: String,
        /// The next refresh gives this one, which replaces the old.
        rotate_to: Option<String>,
        revoked: bool,
        /// Drive is full: nothing can be created or changed.
        full: bool,
        /// Another Device creates a `LeafPDF` folder just before this one's.
        race: bool,
        /// Every API request fails like this: status and reason.
        outage: Option<(u16, &'static str)>,
    }

    struct Request {
        method: String,
        path: String,
        query: HashMap<String, String>,
        headers: HashMap<String, String>,
        body: Vec<u8>,
    }

    struct Reply {
        status: u16,
        headers: Vec<(&'static str, String)>,
        body: Vec<u8>,
    }

    fn reply(status: u16, body: Value) -> Reply {
        Reply {
            status,
            headers: vec![("Content-Type", "application/json".to_owned())],
            body: body.to_string().into_bytes(),
        }
    }

    fn nothing(status: u16) -> Reply {
        Reply {
            status,
            headers: Vec::new(),
            body: Vec::new(),
        }
    }

    fn find(haystack: &[u8], needle: &[u8]) -> Option<usize> {
        haystack
            .windows(needle.len())
            .position(|part| part == needle)
    }

    /// The text after `prefix` in `query`, up to the next unescaped quote.
    fn quoted(query: &str, prefix: &str) -> Option<String> {
        let rest = &query[query.find(prefix)? + prefix.len()..];
        let (mut out, mut chars) = (String::new(), rest.chars());
        while let Some(c) = chars.next() {
            match c {
                '\\' => out.extend(chars.next()),
                '\'' => return Some(out),
                c => out.push(c),
            }
        }
        None
    }

    impl State {
        fn next_id(&mut self) -> String {
            self.counter += 1;
            format!("id{}", self.counter)
        }

        fn add(&mut self, name: &str, parent: &str, folder: bool, data: Vec<u8>) -> String {
            let created = self.counter + 1;
            self.add_at(name, parent, folder, data, created, false)
        }

        fn add_at(
            &mut self,
            name: &str,
            parent: &str,
            folder: bool,
            data: Vec<u8>,
            created: u64,
            trashed: bool,
        ) -> String {
            let id = self.next_id();
            self.items.push(Stored {
                id: id.clone(),
                name: name.to_owned(),
                parent: parent.to_owned(),
                folder,
                data,
                created,
                trashed,
            });
            id
        }

        /// A finished upload.
        fn store(&mut self, upload: Upload) -> Reply {
            let id = match upload.update {
                Some(id) => {
                    match self.items.iter_mut().find(|item| item.id == id) {
                        Some(item) => item.data = upload.received,
                        None => return nothing(404),
                    }
                    id
                }
                None => self.add(&upload.name, &upload.parent, false, upload.received),
            };
            reply(200, json!({ "id": id }))
        }

        fn files(&self, request: &Request) -> Reply {
            const PAGE: usize = 2;
            let query = &request.query["q"];
            let parent = quoted(&query[query.find('\'').unwrap()..], "'").unwrap();
            let name = quoted(query, "name = '");
            let folders = query.contains(&format!("mimeType = '{FOLDER_MIME}'"));
            let found: Vec<_> = self
                .items
                .iter()
                .filter(|i| i.parent == parent && i.folder == folders)
                .filter(|i| !i.trashed || !query.contains("trashed = false"))
                .filter(|i| name.as_ref().is_none_or(|name| *name == i.name))
                .collect();
            let start = request
                .query
                .get("pageToken")
                .and_then(|t| t.parse().ok())
                .unwrap_or(0);
            let page = found.iter().skip(start).take(PAGE);
            let files: Vec<_> = page
                .map(|i| {
                    let created = format!("2024-01-01T00:00:{:02}.000Z", i.created);
                    let mut file = json!({"id": i.id, "name": i.name, "createdTime": created});
                    if !i.folder {
                        file["size"] = json!(i.data.len().to_string());
                    }
                    file
                })
                .collect();
            let mut answer = json!({ "files": files });
            if start + PAGE < found.len() {
                answer["nextPageToken"] = json!((start + PAGE).to_string());
            }
            reply(200, answer)
        }

        /// Starts a resumable upload, for a new file or the content of `update`.
        fn start_session(&mut self, request: &Request, update: Option<&str>, base: &str) -> Reply {
            let metadata: Value = serde_json::from_slice(&request.body).unwrap();
            let id = self.next_id();
            self.uploads.insert(
                id.clone(),
                Upload {
                    update: update.map(str::to_owned),
                    name: metadata["name"].as_str().unwrap_or_default().to_owned(),
                    parent: metadata["parents"][0]
                        .as_str()
                        .unwrap_or_default()
                        .to_owned(),
                    received: Vec::new(),
                },
            );
            let mut answer = nothing(200);
            answer
                .headers
                .push(("Location", format!("{base}/upload/session/{id}")));
            answer
        }

        /// A create with metadata and content in one multipart request.
        fn multipart(&mut self, request: &Request) -> Reply {
            let content_type = &request.headers["content-type"];
            let boundary = format!("--{}", content_type.split("boundary=").nth(1).unwrap());
            let body = &request.body[..];
            let at =
                |needle: &str, from: usize| from + find(&body[from..], needle.as_bytes()).unwrap();
            let json_start = at("\r\n\r\n", 0) + 4;
            let json_end = at(&format!("\r\n{boundary}"), json_start);
            let metadata: Value = serde_json::from_slice(&body[json_start..json_end]).unwrap();
            let data_start = at("\r\n\r\n", json_end) + 4;
            let data_end = at(&format!("\r\n{boundary}--"), data_start);
            self.store(Upload {
                update: None,
                name: metadata["name"].as_str().unwrap().to_owned(),
                parent: metadata["parents"][0].as_str().unwrap().to_owned(),
                received: body[data_start..data_end].to_vec(),
            })
        }

        fn chunk(&mut self, id: &str, request: &Request) -> Reply {
            let Some(upload) = self.uploads.get_mut(id) else {
                return nothing(404);
            };
            let range = request.headers["content-range"]
                .strip_prefix("bytes ")
                .unwrap()
                .to_owned();
            let (span, total) = range.split_once('/').unwrap();
            let start = span
                .split('-')
                .next()
                .unwrap()
                .parse()
                .unwrap_or(upload.received.len());
            if start != upload.received.len() {
                return nothing(400);
            }
            upload.received.extend_from_slice(&request.body);
            let received = upload.received.len();
            match total.parse::<usize>() {
                Ok(total) if total == received => {
                    let upload = self.uploads.remove(id).unwrap();
                    self.store(upload)
                }
                Ok(_) => nothing(400),
                Err(_) => {
                    let mut answer = nothing(308);
                    answer
                        .headers
                        .push(("Range", format!("bytes=0-{}", received - 1)));
                    answer
                }
            }
        }

        fn route(&mut self, request: &Request, base: &str) -> Reply {
            if request.path == "/token" {
                return self.token(&String::from_utf8_lossy(&request.body));
            }
            let bearer = request.headers.get("authorization");
            let bearer = bearer.and_then(|value| value.strip_prefix("Bearer "));
            if !bearer.is_some_and(|token| self.tokens.contains(token)) {
                return reply(401, json!({"error": {"code": 401}}));
            }
            if let Some((status, reason)) = self.outage {
                return reply(status, json!({"error": {"errors": [{"reason": reason}]}}));
            }
            if self.full && request.method != "GET" && request.method != "DELETE" {
                let reason = "storageQuotaExceeded";
                return reply(403, json!({"error": {"errors": [{"reason": reason}]}}));
            }
            let path: Vec<_> = request.path.trim_matches('/').split('/').collect();
            let upload_type = request.query.get("uploadType").map(String::as_str);
            match (request.method.as_str(), &path[..], upload_type) {
                ("GET", ["drive", "v3", "files"], _) => self.files(request),
                ("GET", ["drive", "v3", "about"], _) => {
                    reply(200, json!({"user": {"emailAddress": ACCOUNT}}))
                }
                ("POST", ["drive", "v3", "files"], _) => {
                    let folder: Value = serde_json::from_slice(&request.body).unwrap();
                    let name = folder["name"].as_str().unwrap();
                    let parent = folder["parents"][0].as_str().unwrap();
                    if std::mem::take(&mut self.race) {
                        self.add(name, parent, true, Vec::new());
                    }
                    let id = self.add(name, parent, true, Vec::new());
                    reply(200, json!({ "id": id }))
                }
                ("GET", ["drive", "v3", "files", id], _) => {
                    match self.items.iter().find(|item| item.id == *id) {
                        Some(item) => Reply {
                            status: 200,
                            headers: Vec::new(),
                            body: item.data.clone(),
                        },
                        None => nothing(404),
                    }
                }
                ("DELETE", ["drive", "v3", "files", id], _) => {
                    let before = self.items.len();
                    self.items.retain(|item| item.id != *id);
                    nothing(if self.items.len() < before { 204 } else { 404 })
                }
                ("POST", ["upload", "drive", "v3", "files"], Some("multipart")) => {
                    self.multipart(request)
                }
                ("POST", ["upload", "drive", "v3", "files"], Some("resumable")) => {
                    self.start_session(request, None, base)
                }
                ("PATCH", ["upload", "drive", "v3", "files", id], Some("media")) => {
                    self.store(Upload {
                        update: Some((*id).to_owned()),
                        name: String::new(),
                        parent: String::new(),
                        received: request.body.clone(),
                    })
                }
                ("PATCH", ["upload", "drive", "v3", "files", id], Some("resumable")) => {
                    self.start_session(request, Some(id), base)
                }
                ("PUT", ["upload", "session", id], _) => self.chunk(id, request),
                _ => nothing(404),
            }
        }

        fn token(&mut self, form: &str) -> Reply {
            let form: HashMap<_, _> = form
                .split('&')
                .filter_map(|pair| pair.split_once('='))
                .map(|(key, value)| (key, crate::percent::decode(value)))
                .collect();
            let valid = form.get("grant_type").is_some_and(|g| g == "refresh_token")
                && form.get("client_id").is_some_and(|c| c == CLIENT)
                && form
                    .get("refresh_token")
                    .is_some_and(|t| *t == self.refresh)
                && !self.revoked;
            if !valid {
                return reply(400, json!({"error": "invalid_grant"}));
            }
            let token = format!("access-{}", self.next_id());
            self.tokens.insert(token.clone());
            let mut answer =
                json!({"access_token": token, "expires_in": 3600, "token_type": "Bearer"});
            if let Some(rotated) = self.rotate_to.take() {
                answer["refresh_token"] = json!(rotated);
                self.refresh = rotated;
            }
            reply(200, answer)
        }
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
            path: path.to_owned(),
            query,
            headers,
            body,
        })
    }

    /// A local fake of the parts of the Drive and OAuth APIs the storage
    /// uses, over plain HTTP. Lists come in pages of two.
    struct Fake {
        base: String,
        addr: SocketAddr,
        state: Arc<Mutex<State>>,
        stop: Arc<AtomicBool>,
        /// The refresh tokens the storages made here were told about.
        reported: Arc<Recorder>,
    }

    impl Fake {
        fn start() -> Self {
            let listener = TcpListener::bind("127.0.0.1:0").unwrap();
            let addr = listener.local_addr().unwrap();
            let base = format!("http://{addr}");
            let state = Arc::new(Mutex::new(State::default()));
            state.lock().unwrap().refresh = REFRESH.to_owned();
            state.lock().unwrap().add(ROOT, "", true, Vec::new());
            let stop = Arc::new(AtomicBool::new(false));
            let (served, halt, address) = (state.clone(), stop.clone(), base.clone());
            thread::spawn(move || {
                for stream in listener.incoming() {
                    if halt.load(Relaxed) {
                        break;
                    }
                    let (Ok(mut stream), served, address) =
                        (stream, served.clone(), address.clone())
                    else {
                        continue;
                    };
                    thread::spawn(move || {
                        let Some(request) = read_request(&stream) else {
                            return;
                        };
                        let answer = served.lock().unwrap().route(&request, &address);
                        let mut head = format!("HTTP/1.1 {} X\r\n", answer.status);
                        for (name, value) in &answer.headers {
                            head.push_str(&format!("{name}: {value}\r\n"));
                        }
                        head.push_str(&format!(
                            "Content-Length: {}\r\nConnection: close\r\n\r\n",
                            answer.body.len()
                        ));
                        let _ = stream.write_all(head.as_bytes());
                        let _ = stream.write_all(&answer.body);
                    });
                }
            });
            Self {
                base,
                addr,
                state,
                stop,
                reported: Arc::default(),
            }
        }

        fn config(&self, simple_limit: usize, chunk_size: usize) -> Config {
            Config {
                api: self.base.clone(),
                token_url: format!("{}/token", self.base),
                allow_http: true,
                simple_limit,
                chunk_size,
            }
        }

        fn storage_with(&self, simple_limit: usize, chunk_size: usize) -> GoogleDriveStorage {
            let config = self.config(simple_limit, chunk_size);
            GoogleDriveStorage::at(CLIENT, REFRESH, ROOT, self.reported.clone(), config)
        }

        /// The storage in the folder `root`.
        fn storage_in(&self, root: &str) -> GoogleDriveStorage {
            let config = self.config(SIMPLE_LIMIT, CHUNK_SIZE);
            GoogleDriveStorage::at(CLIENT, REFRESH, root, self.reported.clone(), config)
        }

        fn connect(&self) -> io::Result<(GoogleDriveStorage, String)> {
            let config = self.config(SIMPLE_LIMIT, CHUNK_SIZE);
            GoogleDriveStorage::connect_with(CLIENT, REFRESH, self.reported.clone(), config)
        }

        fn resume(&self) -> io::Result<GoogleDriveStorage> {
            let config = self.config(SIMPLE_LIMIT, CHUNK_SIZE);
            GoogleDriveStorage::resume_with(CLIENT, REFRESH, self.reported.clone(), config)
        }

        /// A folder `LeafPDF` in My Drive's root, created at second `created`.
        fn add_app_folder(&self, created: u64, trashed: bool) -> String {
            let mut state = self.state.lock().unwrap();
            state.add_at(APP_FOLDER, "root", true, Vec::new(), created, trashed)
        }

        /// How many not trashed `LeafPDF` folders are in My Drive's root.
        fn app_folders(&self) -> usize {
            let state = self.state.lock().unwrap();
            let named = |i: &&Stored| i.parent == "root" && i.name == APP_FOLDER && !i.trashed;
            state.items.iter().filter(named).count()
        }

        fn storage(&self) -> GoogleDriveStorage {
            self.storage_with(SIMPLE_LIMIT, CHUNK_SIZE)
        }

        /// The access tokens given so far stop working, as after an hour.
        fn expire_access_tokens(&self) {
            self.state.lock().unwrap().tokens.clear();
        }

        fn revoke_access(&self) {
            self.state.lock().unwrap().revoked = true;
            self.expire_access_tokens();
        }

        fn fail_with(&self, status: u16, reason: &'static str) {
            self.state.lock().unwrap().outage = Some((status, reason));
        }
    }

    impl Drop for Fake {
        fn drop(&mut self) {
            self.stop.store(true, Relaxed);
            let _ = TcpStream::connect(self.addr);
        }
    }

    fn fake_storage() -> Option<(Fake, GoogleDriveStorage)> {
        let fake = Fake::start();
        let storage = fake.storage();
        Some((fake, storage))
    }

    /// Every blob, even the smallest, goes through a resumable upload, in
    /// chunks of four bytes.
    fn fake_storage_in_chunks() -> Option<(Fake, GoogleDriveStorage)> {
        let fake = Fake::start();
        let storage = fake.storage_with(0, 4);
        Some((fake, storage))
    }

    mod fake_drive {
        use super::*;
        storage_contract_tests!(fake_storage);
    }

    mod fake_drive_in_chunks {
        use super::*;
        storage_contract_tests!(fake_storage_in_chunks);
    }

    /// A scratch folder in the My Drive of a real account, deleted on drop.
    struct RealFolder(GoogleDriveStorage, String);

    impl Drop for RealFolder {
        fn drop(&mut self) {
            let _ = self.0.remove(&self.1);
        }
    }

    /// A storage in a new folder of the account whose OAuth client ID and
    /// refresh token are in `LEAFPDF_GOOGLE_DRIVE_CLIENT_ID` and
    /// `LEAFPDF_GOOGLE_DRIVE_REFRESH_TOKEN`. None if they aren't set.
    fn real_storage() -> Option<(RealFolder, GoogleDriveStorage)> {
        let var = |name| std::env::var(name).ok();
        let (Some(client), Some(token)) = (
            var("LEAFPDF_GOOGLE_DRIVE_CLIENT_ID"),
            var("LEAFPDF_GOOGLE_DRIVE_REFRESH_TOKEN"),
        ) else {
            eprintln!("skipped: no Google Drive account in the environment");
            return None;
        };
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let at = |root| {
            let (callback, config) = (Arc::<Recorder>::default(), Config::default());
            GoogleDriveStorage::at(&client, &token, root, callback, config)
        };
        let admin = at("root");
        let folder = admin
            .make_folder("root", &format!("leafpdf-test-{nanos}-{}", unique_name()))
            .unwrap();
        let storage = at(&folder);
        Some((RealFolder(admin, folder), storage))
    }

    mod real_drive {
        use super::*;
        storage_contract_tests!(real_storage);
    }

    #[test]
    fn an_expired_access_token_is_refreshed_without_the_caller_noticing() {
        let (fake, storage) = fake_storage().unwrap();
        put_bytes(&storage, "d/blob", b"1");

        fake.expire_access_tokens();
        assert_eq!(get_bytes(&storage, "d/blob").unwrap().unwrap(), b"1");

        fake.expire_access_tokens();
        put_bytes(&storage, "d/blob", b"22");
        fake.expire_access_tokens();
        storage.delete("other").unwrap();
        assert_eq!(get_bytes(&storage, "d/blob").unwrap().unwrap(), b"22");
    }

    #[test]
    fn an_expired_access_token_during_a_chunked_upload_is_refreshed() {
        let (fake, storage) = fake_storage_in_chunks().unwrap();
        fake.expire_access_tokens();

        put_bytes(&storage, "blob", b"0123456789");

        assert_eq!(get_bytes(&storage, "blob").unwrap().unwrap(), b"0123456789");
    }

    #[test]
    fn blobs_of_every_size_read_back_as_stored() {
        let (_fake, storage) = fake_storage_in_chunks().unwrap();
        let bytes: Vec<u8> = (0..1000u32).map(|i| (i * 7) as u8).collect();
        // Chunk sizes of 4 bytes: below, at and above one chunk, and with
        // bytes that look like HTTP.
        for len in [0, 3, 4, 5, 8, 1000] {
            put_bytes(&storage, "blob", &bytes[..len]);
            assert_eq!(get_bytes(&storage, "blob").unwrap().unwrap(), &bytes[..len]);
        }
        let (_fake, storage) = fake_storage().unwrap();
        put_bytes(&storage, "multipart", b"\r\n--x--\r\n\r\n");
        assert_eq!(
            get_bytes(&storage, "multipart").unwrap().unwrap(),
            b"\r\n--x--\r\n\r\n"
        );
    }

    #[test]
    fn listing_pages_through_all_blobs_and_names_may_hold_quotes() {
        let (_fake, storage) = fake_storage().unwrap();
        let names = ["a", "b", "c", "d", "e", "it's", "back\\slash", "q\"uote"];
        for name in names {
            put_bytes(&storage, &format!("dir/{name}"), name.as_bytes());
        }

        let mut expected = names.to_vec();
        expected.sort();
        assert_eq!(crate::storage::contract::names(&storage, "dir"), expected);
        for name in names {
            let bytes = get_bytes(&storage, &format!("dir/{name}"))
                .unwrap()
                .unwrap();
            assert_eq!(bytes, name.as_bytes());
        }
    }

    #[test]
    fn revoked_access_full_storage_and_rate_limits_differ_from_being_offline() {
        let (fake, storage) = fake_storage().unwrap();
        put_bytes(&storage, "blob", b"1");

        fake.fail_with(403, "storageQuotaExceeded");
        assert!(is_full(&storage.put("blob", &mut &b"2"[..]).unwrap_err()));
        fake.fail_with(403, "userRateLimitExceeded");
        let busy = storage.list("").unwrap_err();
        assert!(busy.kind() != io::ErrorKind::PermissionDenied && !is_full(&busy));
        fake.fail_with(503, "backendError");
        let down = storage.list("").unwrap_err();
        assert!(down.kind() != io::ErrorKind::PermissionDenied && !is_full(&down));

        fake.revoke_access();
        for error in [
            storage.list("").unwrap_err(),
            storage.get("blob").map(|_| ()).unwrap_err(),
            storage.put("blob", &mut &b"3"[..]).unwrap_err(),
            storage.delete("blob").unwrap_err(),
        ] {
            assert_eq!(error.kind(), io::ErrorKind::PermissionDenied);
        }
    }

    #[test]
    fn a_server_that_is_gone_is_not_a_lost_permission() {
        let (fake, storage) = fake_storage().unwrap();
        drop(fake);
        let error = storage.list("").unwrap_err();
        assert_ne!(error.kind(), io::ErrorKind::PermissionDenied);
    }

    /// Marks `folder` by a blob, so a later connect shows which one it used.
    fn mark(fake: &Fake, folder: &str) {
        put_bytes(&fake.storage_in(folder), "mark", b"1");
    }

    fn marked(storage: &GoogleDriveStorage) -> bool {
        crate::storage::contract::names(storage, "") == ["mark"]
    }

    #[test]
    fn connecting_creates_the_folder_once_and_returns_the_account() {
        let fake = Fake::start();

        let (storage, account) = fake.connect().unwrap();
        assert_eq!(account, ACCOUNT);
        assert_eq!(fake.app_folders(), 1);
        put_bytes(&storage, "d/blob", b"1");

        let (again, _) = fake.connect().unwrap();
        assert_eq!(fake.app_folders(), 1);
        assert_eq!(get_bytes(&again, "d/blob").unwrap().unwrap(), b"1");
        let resumed = fake.resume().unwrap();
        assert_eq!(fake.app_folders(), 1);
        assert_eq!(get_bytes(&resumed, "d/blob").unwrap().unwrap(), b"1");
    }

    #[test]
    fn a_trashed_folder_is_ignored() {
        let fake = Fake::start();
        let trashed = fake.add_app_folder(1, true);
        mark(&fake, &trashed);
        let (storage, _) = fake.connect().unwrap();
        assert!(!marked(&storage));
        assert_eq!(fake.app_folders(), 1);

        let fake = Fake::start();
        let trashed = fake.add_app_folder(1, true);
        mark(&fake, &trashed);
        let live = fake.add_app_folder(2, false);
        put_bytes(&fake.storage_in(&live), "live", b"1");
        let (storage, _) = fake.connect().unwrap();
        assert_eq!(crate::storage::contract::names(&storage, ""), ["live"]);
    }

    #[test]
    fn of_several_folders_the_oldest_wins_then_the_lowest_id() {
        let fake = Fake::start();
        let newer = fake.add_app_folder(5, false);
        let older = fake.add_app_folder(3, false);
        mark(&fake, &older);
        put_bytes(&fake.storage_in(&newer), "other", b"1");
        assert!(marked(&fake.connect().unwrap().0));
        assert!(marked(&fake.resume().unwrap()));
        // Nothing is deleted: only a Device's own empty duplicate.
        assert_eq!(fake.app_folders(), 2);

        let fake = Fake::start();
        let lowest = fake.add_app_folder(3, false);
        let higher = fake.add_app_folder(3, false);
        mark(&fake, &lowest);
        put_bytes(&fake.storage_in(&higher), "other", b"1");
        assert!(marked(&fake.connect().unwrap().0));
    }

    #[test]
    fn a_duplicate_folder_made_at_the_same_moment_is_deleted_by_its_creator() {
        let fake = Fake::start();
        fake.state.lock().unwrap().race = true;

        let (storage, _) = fake.connect().unwrap();
        assert_eq!(fake.app_folders(), 1);
        put_bytes(&storage, "blob", b"1");

        let (other, _) = fake.connect().unwrap();
        assert_eq!(get_bytes(&other, "blob").unwrap().unwrap(), b"1");
    }

    #[test]
    fn connecting_with_revoked_access_is_a_lost_permission() {
        let fake = Fake::start();
        fake.connect().unwrap();
        fake.revoke_access();

        let error = fake.connect().map(|_| ()).unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::PermissionDenied);
        let error = fake.resume().map(|_| ()).unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::PermissionDenied);
    }

    #[test]
    fn a_full_drive_cannot_create_the_folder_but_opens_an_existing_one() {
        let fake = Fake::start();
        fake.state.lock().unwrap().full = true;
        assert!(is_full(&fake.connect().map(|_| ()).unwrap_err()));
        assert!(is_full(&fake.resume().map(|_| ()).unwrap_err()));
        assert_eq!(fake.app_folders(), 0);

        fake.add_app_folder(1, false);
        let (storage, _) = fake.connect().unwrap();
        assert!(is_full(&storage.put("blob", &mut &b"1"[..]).unwrap_err()));
    }

    #[test]
    fn a_rotated_refresh_token_is_reported_once() {
        let fake = Fake::start();
        let (storage, _) = fake.connect().unwrap();
        assert!(fake.reported.0.lock().unwrap().is_empty());

        fake.state.lock().unwrap().rotate_to = Some("rotated".to_owned());
        fake.expire_access_tokens();
        put_bytes(&storage, "blob", b"1");
        assert_eq!(*fake.reported.0.lock().unwrap(), ["rotated"]);

        // The new token is the one in use now.
        fake.expire_access_tokens();
        put_bytes(&storage, "blob", b"2");
        assert_eq!(*fake.reported.0.lock().unwrap(), ["rotated"]);
    }

    #[test]
    fn a_refresh_token_rotated_while_connecting_is_reported() {
        let fake = Fake::start();
        fake.state.lock().unwrap().rotate_to = Some("rotated".to_owned());

        fake.connect().unwrap();

        assert_eq!(*fake.reported.0.lock().unwrap(), ["rotated"]);
    }

    #[test]
    fn two_libraries_sync_their_documents_and_files_through_google_drive() {
        let fake = Fake::start();
        let home = Scratch::new("drive-devices");
        let open = |device: &str| Library::open(home.0.join(device).join("library")).unwrap();
        let (a, b) = (open("a"), open("b"));
        let source = home.0.join("Paper.pdf");
        fs::write(&source, b"%PDF-paper bytes").unwrap();
        let ImportResult::Imported(imported) = a.import(&source, |_, _| {}).unwrap() else {
            panic!("not imported");
        };

        a.sync(&fake.storage()).unwrap();
        b.sync(&fake.storage()).unwrap();

        let documents = b.documents().unwrap();
        assert_eq!(documents.len(), 1);
        assert_eq!(documents[0].id, imported.id);
        assert_eq!(fs::read(&documents[0].path).unwrap(), b"%PDF-paper bytes");
        assert_eq!(documents[0].path.file_name().unwrap(), "Paper.pdf");
    }
}
