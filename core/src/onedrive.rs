//! The OneDrive storage: a Cloud Provider (ADR-0010) that keeps everything in
//! the app folder of the user's OneDrive, `Apps/Leaf`.
//!
//! Scope `Files.ReadWrite.AppFolder`, personal accounts only (ADR-0011).
//! Items are addressed by path below the app root, so there are no IDs to look
//! up. Small blobs upload in one request, bigger ones through an upload
//! session, which is never resumed: an interrupted `put` starts over the next
//! time. Deletes go to the recycle bin (ADR-0016).

use crate::cloud_http::{
    Config, OAuthClient, read_head, read_json, succeeded, unexpected, upload_chunks,
};
use crate::percent::encode;
use crate::storage::{Blob, RefreshTokenCallback, Storage, check_name, unique_name};
use serde_json::json;
use std::fmt;
use std::fs::{self, File};
use std::io::{self, Read, Seek};
use std::path::PathBuf;
use std::sync::Arc;

const API: &str = "https://graph.microsoft.com/v1.0";
/// Personal Microsoft accounts only.
const TOKEN_URL: &str = "https://login.microsoftonline.com/consumers/oauth2/v2.0/token";

/// Blobs up to this many bytes upload in one request, which Graph limits to
/// 4 MB. They are held in memory.
const SIMPLE_LIMIT: usize = 4_000_000;
/// The size of a part of an upload session. Graph wants a multiple of 320 KiB.
const CHUNK_SIZE: usize = 10 << 20;

fn production() -> Config {
    Config::new(API, TOKEN_URL, SIMPLE_LIMIT, CHUNK_SIZE)
}

/// The app folder of a OneDrive and everything below it.
///
/// Errors tell why a request failed, see `cloud_http::OAuthClient`: revoked
/// access is `PermissionDenied`, a full OneDrive is `StorageFull`.
pub struct OneDriveStorage {
    oauth: OAuthClient,
    api: String,
    simple_limit: usize,
    chunk_size: usize,
    /// The directory below the app root that is `""`; none, but in tests.
    dir: String,
}

impl fmt::Debug for OneDriveStorage {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        // No credentials.
        f.debug_struct("OneDriveStorage").finish_non_exhaustive()
    }
}

impl OneDriveStorage {
    /// Connects to the OneDrive of the user who owns `refresh_token`, a token
    /// of the public OAuth client `client_id`, and returns the storage with
    /// the user's account (email or name, empty if OneDrive doesn't tell it
    /// without more permissions). Fails with `Unsupported` for a work or
    /// school account. Rotated refresh tokens are reported to
    /// `on_new_refresh_token`.
    pub fn connect(
        client_id: &str,
        refresh_token: &str,
        on_new_refresh_token: Arc<dyn RefreshTokenCallback>,
    ) -> io::Result<(Self, String)> {
        let config = production();
        Self::connect_with(client_id, refresh_token, on_new_refresh_token, config)
    }

    /// The storage of a OneDrive that was connected before, e.g. at the last
    /// launch. Contacts nobody, so it works offline. Until a request works,
    /// uses fail as requests do, see above.
    pub fn resume(
        client_id: &str,
        refresh_token: &str,
        on_new_refresh_token: Arc<dyn RefreshTokenCallback>,
    ) -> Self {
        let config = production();
        Self::at(client_id, refresh_token, "", on_new_refresh_token, config)
    }

    fn connect_with(
        client_id: &str,
        refresh_token: &str,
        on_new_refresh_token: Arc<dyn RefreshTokenCallback>,
        config: Config,
    ) -> io::Result<(Self, String)> {
        let storage = Self::at(client_id, refresh_token, "", on_new_refresh_token, config);
        // The first access creates the app folder. Asking for it needs no
        // scope beyond `Files.ReadWrite.AppFolder`, and tells whose it is.
        let url = format!("{}?$select=createdBy,parentReference", storage.url("", ""));
        let root = storage.oauth.json("GET", &url, None)?;
        match root["parentReference"]["driveType"].as_str() {
            None | Some("personal") => {}
            Some(_) => {
                return Err(io::Error::new(
                    io::ErrorKind::Unsupported,
                    "only personal OneDrive accounts are supported",
                ));
            }
        }
        let user = &root["createdBy"]["user"];
        let account = user["email"].as_str().or(user["displayName"].as_str());
        Ok((storage, account.unwrap_or_default().to_owned()))
    }

    /// The storage in directory `dir` below the app root.
    fn at(
        client_id: &str,
        refresh_token: &str,
        dir: &str,
        on_new_refresh_token: Arc<dyn RefreshTokenCallback>,
        config: Config,
    ) -> Self {
        Self {
            oauth: OAuthClient::new(&config, client_id, refresh_token, on_new_refresh_token),
            api: config.api,
            simple_limit: config.simple_limit,
            chunk_size: config.chunk_size,
            dir: dir.to_owned(),
        }
    }

    /// The URL of the item `path`, `""` being this storage's root, followed by
    /// `action` (`"/content"`, ...).
    fn url(&self, path: &str, action: &str) -> String {
        let path = [self.dir.as_str(), path]
            .into_iter()
            .filter(|part| !part.is_empty())
            .collect::<Vec<_>>()
            .join("/");
        let root = format!("{}/me/drive/special/approot", self.api);
        if path.is_empty() {
            return format!("{root}{action}");
        }
        let path: Vec<_> = path.split('/').map(encode).collect();
        format!("{root}:/{}:{action}", path.join("/"))
    }

    /// Uploads `bytes` in one request, replacing blob `name`.
    fn upload_whole(&self, name: &str, bytes: &[u8]) -> io::Result<()> {
        let headers = [("Content-Type", "application/octet-stream")];
        let response = self
            .oauth
            .send("PUT", &self.url(name, "/content"), &headers, bytes)?;
        succeeded("upload", &response)
    }

    /// Uploads everything `data` yields through an upload session, replacing
    /// blob `name`.
    fn upload_in_chunks(&self, name: &str, data: &mut dyn Read) -> io::Result<()> {
        // Graph wants the size of the whole with each part, so `data` is read
        // through first, before OneDrive hears of the blob.
        let mut spool = Spool::new()?;
        let size = io::copy(data, &mut spool.file)?;
        spool.file.rewind()?;

        let url = self.url(name, "/createUploadSession");
        let item = json!({"item": {"@microsoft.graph.conflictBehavior": "replace"}});
        let session = self.oauth.json("POST", &url, Some(&item))?;
        let upload = session["uploadUrl"]
            .as_str()
            .ok_or_else(|| io::Error::other("the upload has no session"))?;

        upload_chunks(&mut spool.file, self.chunk_size, |chunk| {
            let range = chunk.content_range(Some(size));
            let headers = [("Content-Range", range.as_str())];
            let response =
                self.oauth
                    .send_to_handed_out_url("PUT", upload, &headers, chunk.bytes)?;
            match (response.status().as_u16(), chunk.total) {
                (202, None) | (200 | 201, Some(_)) => Ok(()),
                (status, _) => Err(unexpected("upload", status)),
            }
        })
    }
}

/// A temporary file that is removed when dropped.
struct Spool {
    file: File,
    path: PathBuf,
}

impl Spool {
    fn new() -> io::Result<Self> {
        let path = std::env::temp_dir().join(format!("leaf-upload-{}", unique_name()));
        let file = File::options()
            .read(true)
            .write(true)
            .create_new(true)
            .open(&path)?;
        Ok(Self { file, path })
    }
}

impl Drop for Spool {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.path);
    }
}

impl Storage for OneDriveStorage {
    fn put(&self, name: &str, data: &mut dyn Read) -> io::Result<()> {
        check_name(name)?;
        // A source that fails does so before OneDrive hears of the blob.
        let head = read_head(data, self.simple_limit)?;
        if head.len() <= self.simple_limit {
            self.upload_whole(name, &head)
        } else {
            self.upload_in_chunks(name, &mut (&head[..]).chain(data))
        }
    }

    fn get(&self, name: &str) -> io::Result<Option<Box<dyn Read + Send>>> {
        check_name(name)?;
        let response = self
            .oauth
            .send("GET", &self.url(name, "/content"), &[], &[])?;
        let response = match response.status().as_u16() {
            // To a download URL that is authorized already.
            301 | 302 | 303 | 307 | 308 => {
                let location = response
                    .headers()
                    .get("location")
                    .and_then(|location| location.to_str().ok())
                    .ok_or_else(|| io::Error::other("the download has no URL"))?;
                self.oauth
                    .send_to_handed_out_url("GET", location, &[], &[])?
            }
            _ => response,
        };
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
        let mut next = Some(self.url(dir, "/children?$select=name,size,file&$top=200"));
        let mut blobs = Vec::new();
        while let Some(url) = next {
            let response = self.oauth.send("GET", &url, &[], &[])?;
            if response.status().as_u16() == 404 {
                return Ok(Vec::new());
            }
            succeeded("list", &response)?;
            let page = read_json(response)?;
            for item in page["value"].as_array().into_iter().flatten() {
                // Folders have no `file`.
                if let (Some(name), Some(_)) = (item["name"].as_str(), item.get("file")) {
                    blobs.push(Blob {
                        name: name.to_owned(),
                        size: item["size"].as_u64().unwrap_or(0),
                    });
                }
            }
            next = page["@odata.nextLink"].as_str().map(str::to_owned);
        }
        Ok(blobs)
    }

    fn delete(&self, name: &str) -> io::Result<()> {
        check_name(name)?;
        let response = self.oauth.send("DELETE", &self.url(name, ""), &[], &[])?;
        match response.status().as_u16() {
            200..=299 | 404 => Ok(()),
            status => Err(unexpected("DELETE", status)),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cloud_http::fake::{Api, Auth, Recorder, Reply, Request, Server, nothing, reply};
    use crate::library::{ImportResult, Library};
    use crate::storage::contract::{Scratch, names, put_bytes, storage_contract_tests};
    use crate::storage::{get_bytes, is_full};
    use std::collections::BTreeMap;
    use std::collections::HashMap;
    use std::sync::MutexGuard;
    use std::time::{SystemTime, UNIX_EPOCH};

    const CLIENT: &str = "client-id";
    const REFRESH: &str = "refresh-token";
    const ACCOUNT: &str = "reader@example.com";
    const APP_ROOT: &str = "/me/drive/special/approot";

    /// An upload session that waits for its parts.
    struct Upload {
        path: String,
        received: Vec<u8>,
    }

    struct State {
        auth: Auth,
        /// The blobs, by path below the app root. Folders exist as long as
        /// something is in them.
        files: BTreeMap<String, Vec<u8>>,
        uploads: HashMap<String, Upload>,
        counter: u64,
        /// OneDrive is full: nothing can be created or changed.
        full: bool,
        /// The kind of the drive the account has.
        drive_type: &'static str,
        /// Whether the account's name is told.
        names_account: bool,
        /// The next part of an upload session after the first one fails.
        interrupt: bool,
        /// Every API request fails like this: status and error code.
        outage: Option<(u16, &'static str)>,
    }

    fn failure(status: u16, code: &str) -> Reply {
        reply(status, json!({"error": {"code": code}}))
    }

    /// The URL, percent-encoded, of the children of `dir` from `skip` on.
    fn children_url(base: &str, dir: &str, skip: usize) -> String {
        let parts: Vec<_> = dir.split('/').map(encode).collect();
        let place = match dir {
            "" => String::new(),
            _ => format!(":/{}:", parts.join("/")),
        };
        format!("{base}{APP_ROOT}{place}/children?$skiptoken={skip}")
    }

    impl State {
        fn new() -> Self {
            Self {
                auth: Auth::new(CLIENT, REFRESH),
                files: BTreeMap::new(),
                uploads: HashMap::new(),
                counter: 0,
                full: false,
                drive_type: "personal",
                names_account: true,
                interrupt: false,
                outage: None,
            }
        }

        fn children(&self, dir: &str, request: &Request, base: &str) -> Reply {
            const PAGE: usize = 2;
            let prefix = if dir.is_empty() {
                String::new()
            } else {
                format!("{dir}/")
            };
            let mut found: BTreeMap<&str, Option<usize>> = BTreeMap::new();
            for (path, data) in &self.files {
                let Some(rest) = path.strip_prefix(&prefix) else {
                    continue;
                };
                match rest.split_once('/') {
                    Some((folder, _)) => found.insert(folder, None),
                    None => found.insert(rest, Some(data.len())),
                };
            }
            // The app root is always there, other folders only with content.
            if found.is_empty() && !dir.is_empty() {
                return failure(404, "itemNotFound");
            }
            let start = request
                .query
                .get("$skiptoken")
                .and_then(|t| t.parse().ok())
                .unwrap_or(0);
            let value: Vec<_> = found
                .iter()
                .skip(start)
                .take(PAGE)
                .map(|(name, size)| match size {
                    Some(size) => json!({"name": name, "size": size, "file": {}}),
                    None => json!({"name": name, "size": 1, "folder": {}}),
                })
                .collect();
            let mut answer = json!({ "value": value });
            if start + PAGE < found.len() {
                let next = children_url(base, dir, start + PAGE);
                answer["@odata.nextLink"] = json!(next);
            }
            reply(200, answer)
        }

        fn root(&self) -> Reply {
            let mut answer = json!({"parentReference": {"driveType": self.drive_type}});
            if self.names_account {
                answer["createdBy"] = json!({"user": {"email": ACCOUNT, "displayName": "Reader"}});
            }
            reply(200, answer)
        }

        /// A finished upload.
        fn store(&mut self, path: &str, data: Vec<u8>) -> Reply {
            let created = self.files.insert(path.to_owned(), data).is_none();
            reply(if created { 201 } else { 200 }, json!({"id": path}))
        }

        fn start_session(&mut self, path: &str, base: &str) -> Reply {
            self.counter += 1;
            let id = format!("session{}", self.counter);
            let upload = Upload {
                path: path.to_owned(),
                received: Vec::new(),
            };
            self.uploads.insert(id.clone(), upload);
            reply(200, json!({"uploadUrl": format!("{base}/session/{id}")}))
        }

        fn part(&mut self, id: &str, request: &Request) -> Reply {
            // Graph refuses a token on an upload URL.
            if request.headers.contains_key("authorization") {
                return failure(401, "InvalidAuthenticationToken");
            }
            let Some(upload) = self.uploads.get_mut(id) else {
                return failure(404, "itemNotFound");
            };
            let range = request.headers["content-range"].strip_prefix("bytes ");
            let (span, total) = range.unwrap().split_once('/').unwrap();
            let start: usize = span.split('-').next().unwrap().parse().unwrap();
            // Unlike Drive, Graph wants the size of the whole every time.
            let total: usize = total.parse().unwrap();
            if start != upload.received.len() {
                return failure(416, "invalidRange");
            }
            if start > 0 && std::mem::take(&mut self.interrupt) {
                self.uploads.remove(id);
                return failure(503, "serviceNotAvailable");
            }
            let upload = self.uploads.get_mut(id).unwrap();
            upload.received.extend_from_slice(&request.body);
            if upload.received.len() < total {
                return reply(202, json!({"nextExpectedRanges": []}));
            }
            let upload = self.uploads.remove(id).unwrap();
            self.store(&upload.path, upload.received)
        }
    }

    impl Api for State {
        fn auth(&mut self) -> &mut Auth {
            &mut self.auth
        }

        fn is_public(&self, request: &Request) -> bool {
            request.path.starts_with("/session/") || request.path.starts_with("/download/")
        }

        fn route(&mut self, request: &Request, base: &str) -> Reply {
            let method = request.method.as_str();
            if let ("PUT", Some(id)) = (method, request.path.strip_prefix("/session/")) {
                return self.part(id, request);
            }
            if let Some(path) = request.path.strip_prefix("/download/") {
                // Graph's download URLs are authorized: a token on top is refused.
                if request.headers.contains_key("authorization") {
                    return failure(401, "InvalidAuthenticationToken");
                }
                return match self.files.get(path) {
                    Some(data) => Reply {
                        status: 200,
                        headers: Vec::new(),
                        body: data.clone(),
                    },
                    None => failure(404, "itemNotFound"),
                };
            }
            if let Some((status, code)) = self.outage {
                return failure(status, code);
            }
            let Some(rest) = request.path.strip_prefix(APP_ROOT) else {
                return nothing(404);
            };
            // `:/dir/blob:/content`, or the app root itself.
            let (path, action) = match rest.strip_prefix(":/") {
                Some(rest) => rest.split_once(':').unwrap(),
                None => ("", rest),
            };
            let changes = matches!(
                (method, action),
                ("PUT", "/content") | ("POST", "/createUploadSession")
            );
            if self.full && changes {
                return failure(507, "quotaLimitReached");
            }
            match (method, action) {
                ("GET", "") if path.is_empty() => self.root(),
                ("GET", "/children") => self.children(path, request, base),
                ("GET", "/content") => match self.files.contains_key(path) {
                    true => {
                        let mut answer = nothing(302);
                        let url = format!("{base}/download/{}", encode_path(path));
                        answer.headers.push(("Location", url));
                        answer
                    }
                    false => failure(404, "itemNotFound"),
                },
                ("PUT", "/content") => self.store(path, request.body.clone()),
                ("POST", "/createUploadSession") => self.start_session(path, base),
                ("DELETE", "") => {
                    let before = self.files.len();
                    let folder = format!("{path}/");
                    self.files
                        .retain(|name, _| name != path && !name.starts_with(&folder));
                    nothing(if self.files.len() < before { 204 } else { 404 })
                }
                _ => nothing(404),
            }
        }
    }

    fn encode_path(path: &str) -> String {
        path.split('/').map(encode).collect::<Vec<_>>().join("/")
    }

    /// A local fake of the parts of the Graph and OAuth APIs the storage
    /// uses, over plain HTTP. Lists come in pages of two.
    struct Fake {
        server: Server<State>,
        /// The refresh tokens the storages made here were told about.
        reported: Arc<Recorder>,
    }

    impl Fake {
        fn start() -> Self {
            Self {
                server: Server::start(State::new()),
                reported: Arc::default(),
            }
        }

        fn state(&self) -> MutexGuard<'_, State> {
            self.server.state.lock().unwrap()
        }

        fn config(&self, simple_limit: usize, chunk_size: usize) -> Config {
            Config::fake(&self.server.base, simple_limit, chunk_size)
        }

        fn storage_with(&self, simple_limit: usize, chunk_size: usize) -> OneDriveStorage {
            let config = self.config(simple_limit, chunk_size);
            OneDriveStorage::at(CLIENT, REFRESH, "", self.reported.clone(), config)
        }

        fn storage(&self) -> OneDriveStorage {
            self.storage_with(SIMPLE_LIMIT, CHUNK_SIZE)
        }

        fn connect(&self) -> io::Result<(OneDriveStorage, String)> {
            let config = self.config(SIMPLE_LIMIT, CHUNK_SIZE);
            OneDriveStorage::connect_with(CLIENT, REFRESH, self.reported.clone(), config)
        }

        fn expire_access_tokens(&self) {
            self.state().auth.expire_access_tokens();
        }

        fn revoke_access(&self) {
            self.state().auth.revoke();
        }

        fn fail_with(&self, status: u16, code: &'static str) {
            self.state().outage = Some((status, code));
        }
    }

    fn fake_storage() -> Option<(Fake, OneDriveStorage)> {
        let fake = Fake::start();
        let storage = fake.storage();
        Some((fake, storage))
    }

    /// Every blob but the empty ones goes through an upload session, in parts
    /// of four bytes.
    fn fake_storage_in_chunks() -> Option<(Fake, OneDriveStorage)> {
        let fake = Fake::start();
        let storage = fake.storage_with(0, 4);
        Some((fake, storage))
    }

    mod fake_onedrive {
        use super::*;
        storage_contract_tests!(fake_storage);
    }

    mod fake_onedrive_in_chunks {
        use super::*;
        storage_contract_tests!(fake_storage_in_chunks);
    }

    /// A scratch folder in the app folder of a real account, deleted on drop.
    struct RealFolder(OneDriveStorage, String);

    impl Drop for RealFolder {
        fn drop(&mut self) {
            let _ = self.0.delete(&self.1);
        }
    }

    /// A storage in a new folder of the account whose OAuth client ID and
    /// refresh token are in `LEAF_ONEDRIVE_CLIENT_ID` and
    /// `LEAF_ONEDRIVE_REFRESH_TOKEN`. None if they aren't set.
    fn real_storage() -> Option<(RealFolder, OneDriveStorage)> {
        let var = |name| std::env::var(name).ok();
        let (Some(client), Some(token)) = (
            var("LEAF_ONEDRIVE_CLIENT_ID"),
            var("LEAF_ONEDRIVE_REFRESH_TOKEN"),
        ) else {
            eprintln!("skipped: no OneDrive account in the environment");
            return None;
        };
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let folder = format!("leaf-test-{nanos}-{}", unique_name());
        let at = |dir: &str| {
            let callback = Arc::<Recorder>::default();
            OneDriveStorage::at(&client, &token, dir, callback, production())
        };
        Some((RealFolder(at(""), folder.clone()), at(&folder)))
    }

    mod real_onedrive {
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
    fn an_expired_access_token_during_an_upload_session_is_refreshed() {
        let (fake, storage) = fake_storage_in_chunks().unwrap();
        fake.expire_access_tokens();

        put_bytes(&storage, "blob", b"0123456789");

        assert_eq!(get_bytes(&storage, "blob").unwrap().unwrap(), b"0123456789");
    }

    #[test]
    fn blobs_of_every_size_read_back_as_stored() {
        let (_fake, storage) = fake_storage_in_chunks().unwrap();
        let bytes: Vec<u8> = (0..1000u32).map(|i| (i * 7) as u8).collect();
        // Parts of 4 bytes: below, at and above one part.
        for len in [0, 3, 4, 5, 8, 1000] {
            put_bytes(&storage, "blob", &bytes[..len]);
            assert_eq!(get_bytes(&storage, "blob").unwrap().unwrap(), &bytes[..len]);
        }
    }

    #[test]
    fn listing_pages_through_all_blobs_and_names_may_need_escaping() {
        let (_fake, storage) = fake_storage().unwrap();
        let blobs = [
            "a",
            "b",
            "c",
            "d",
            "e",
            "it's",
            "two words",
            "ünï",
            "100%",
            "a#b+c",
        ];
        for name in blobs {
            put_bytes(&storage, &format!("dir name/{name}"), name.as_bytes());
        }

        let mut expected = blobs.to_vec();
        expected.sort();
        assert_eq!(names(&storage, "dir name"), expected);
        for name in blobs {
            let bytes = get_bytes(&storage, &format!("dir name/{name}"));
            assert_eq!(bytes.unwrap().unwrap(), name.as_bytes());
        }
    }

    #[test]
    fn an_upload_that_is_interrupted_starts_over_the_next_time() {
        let (fake, storage) = fake_storage_in_chunks().unwrap();
        put_bytes(&storage, "blob", b"old");
        fake.state().interrupt = true;

        let result = storage.put("blob", &mut &b"0123456789"[..]);

        assert!(result.is_err());
        assert_eq!(get_bytes(&storage, "blob").unwrap().unwrap(), b"old");
        assert_eq!(names(&storage, ""), ["blob"]);
        put_bytes(&storage, "blob", b"0123456789");
        assert_eq!(get_bytes(&storage, "blob").unwrap().unwrap(), b"0123456789");
    }

    #[test]
    fn revoked_access_full_storage_and_throttling_differ_from_being_offline() {
        let (fake, storage) = fake_storage().unwrap();
        put_bytes(&storage, "blob", b"1");

        fake.state().full = true;
        assert!(is_full(&storage.put("blob", &mut &b"2"[..]).unwrap_err()));
        let (fake_in_chunks, chunked) = fake_storage_in_chunks().unwrap();
        fake_in_chunks.state().full = true;
        assert!(is_full(
            &chunked.put("blob", &mut &b"22222"[..]).unwrap_err()
        ));
        fake.state().full = false;

        for (status, code) in [
            (429, "tooManyRequests"),
            (503, "serviceNotAvailable"),
            (403, "activityLimitReached"),
        ] {
            fake.fail_with(status, code);
            let error = storage.list("").unwrap_err();
            assert!(error.kind() != io::ErrorKind::PermissionDenied && !is_full(&error));
        }

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

    #[test]
    fn connecting_returns_the_account_if_onedrive_tells() {
        let fake = Fake::start();
        let (storage, account) = fake.connect().unwrap();
        assert_eq!(account, ACCOUNT);
        put_bytes(&storage, "d/blob", b"1");

        // The same blobs, however it is reached.
        let (again, _) = fake.connect().unwrap();
        assert_eq!(get_bytes(&again, "d/blob").unwrap().unwrap(), b"1");

        fake.state().names_account = false;
        assert_eq!(fake.connect().unwrap().1, "");
    }

    #[test]
    fn connecting_with_a_work_or_school_account_is_unsupported() {
        let fake = Fake::start();
        fake.state().drive_type = "business";

        let error = fake.connect().map(|_| ()).unwrap_err();

        assert_eq!(error.kind(), io::ErrorKind::Unsupported);
    }

    #[test]
    fn connecting_with_revoked_access_is_a_lost_permission() {
        let fake = Fake::start();
        fake.connect().unwrap();
        fake.revoke_access();

        let error = fake.connect().map(|_| ()).unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::PermissionDenied);
    }

    #[test]
    fn resuming_contacts_nobody_so_a_problem_shows_at_the_first_use() {
        let fake = Fake::start();
        fake.connect().unwrap();
        fake.revoke_access();
        let config = fake.config(SIMPLE_LIMIT, CHUNK_SIZE);
        let resumed = OneDriveStorage::at(CLIENT, REFRESH, "", fake.reported.clone(), config);
        let error = resumed.list("").unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::PermissionDenied);

        // Even with the server gone: that is Offline, and the next use tries again.
        let config = Config::fake("http://127.0.0.1:1", SIMPLE_LIMIT, CHUNK_SIZE);
        let callback = Arc::<Recorder>::default();
        let storage = OneDriveStorage::at(CLIENT, REFRESH, "", callback, config);
        let error = storage.list("").unwrap_err();
        assert!(!is_full(&error) && error.kind() != io::ErrorKind::PermissionDenied);
    }

    #[test]
    fn a_rotated_refresh_token_is_reported_once() {
        let fake = Fake::start();
        let (storage, _) = fake.connect().unwrap();
        assert!(fake.reported.0.lock().unwrap().is_empty());

        fake.state().auth.rotate_to = Some("rotated".to_owned());
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
        fake.state().auth.rotate_to = Some("rotated".to_owned());

        fake.connect().unwrap();

        assert_eq!(*fake.reported.0.lock().unwrap(), ["rotated"]);
    }

    #[test]
    fn two_libraries_sync_their_documents_and_files_through_onedrive() {
        let fake = Fake::start();
        let home = Scratch::new("onedrive-devices");
        let open = |device: &str| Library::open(home.0.join(device).join("library")).unwrap();
        let (a, b) = (open("a"), open("b"));
        let source = home.0.join("Paper.pdf");
        std::fs::write(&source, b"%PDF-paper bytes").unwrap();
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
