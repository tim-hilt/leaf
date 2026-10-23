//! The storage interface every Cloud Provider implements (ADR-0010), and the
//! directory-backed storage, which is also the future Folder provider.
//!
//! A storage is plain remote file storage: named blobs in directories, no
//! transactions, no server logic (ADR-0017). Everything above it, from the
//! remote layout to merging, is in the core.

use std::fmt;
use std::fs::{self, File};
use std::io::{self, Read};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicU32, Ordering::Relaxed};

/// A blob in a storage directory.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Blob {
    /// The blob's name within its directory.
    pub name: String,
    /// Its size in bytes. Blobs are normally immutable and told apart by name;
    /// the size also reveals an overwritten one.
    pub size: u64,
}

/// Why connecting to a Cloud Provider failed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ConnectError {
    /// The user backed out of the provider's prompt or sign-in page.
    Cancelled,
    /// The provider refused access.
    AccessDenied,
    /// iCloud Drive is off, or not signed in to iCloud.
    ICloudDriveUnavailable,
    /// The granted folder isn't iCloud Drive itself.
    WrongFolder,
    /// A kind of account the provider doesn't support.
    UnsupportedAccount,
    /// WebDAV: the server rejected the username or password.
    WrongCredentials,
    /// WebDAV: no answer: wrong host, no network, a broken certificate or a
    /// server that is down.
    Unreachable,
    /// WebDAV: the URL doesn't start with `https://`. The password would
    /// travel in plain text.
    NotHttps,
    /// WebDAV: the server answers, but not as a WebDAV server.
    NotWebDav,
}

/// The variant's name; clients word the message for the user.
impl fmt::Display for ConnectError {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        write!(f, "{self:?}")
    }
}

impl std::error::Error for ConnectError {}

/// Told by a Cloud Provider behind OAuth that its refresh token changed. The
/// client keeps the new one (in the Keychain) and resumes with it next time.
/// Called while the storage renews its access, so it must not use the storage.
pub trait RefreshTokenCallback: Send + Sync {
    fn new_refresh_token(&self, token: &str);
}

/// Named blobs in `/`-separated directories, e.g. `v1/file.abc`.
///
/// Names are plain: every part is non-empty, isn't `.` or `..`, and doesn't
/// start with a dot. Anything else is `InvalidInput`. Directories exist as soon
/// as a blob is in them; a missing one is empty.
///
/// Errors are `io::Error`s. Credentials the storage rejects are
/// `PermissionDenied`, and a storage without space left is `StorageFull` (or
/// `QuotaExceeded`, see `is_full`), so both can be told from being offline.
/// The directory storage passes the file system's errors on, so it does both.
pub trait Storage: Send + Sync {
    /// Stores everything `data` yields as the blob `name`, replacing any
    /// previous one. A blob is never visible under `name` before all of it is
    /// written, and a failed `put` (`data` erroring too) leaves no trace.
    fn put(&self, name: &str, data: &mut dyn Read) -> io::Result<()>;

    /// The content of blob `name`; none if there is no such blob.
    fn get(&self, name: &str) -> io::Result<Option<Box<dyn Read + Send>>>;

    /// The blobs directly in directory `dir` (`""` is the root), in no order.
    /// Subdirectories are not listed.
    fn list(&self, dir: &str) -> io::Result<Vec<Blob>>;

    /// Deletes blob `name`. Deleting a blob that isn't there does nothing.
    fn delete(&self, name: &str) -> io::Result<()>;
}

/// Whether `error` says the storage has no space left.
pub(crate) fn is_full(error: &io::Error) -> bool {
    matches!(
        error.kind(),
        io::ErrorKind::StorageFull | io::ErrorKind::QuotaExceeded
    )
}

/// Checks that `name` is a plain blob name, see `Storage`.
pub(crate) fn check_name(name: &str) -> io::Result<()> {
    let plain = !name.is_empty()
        && name
            .split('/')
            .all(|part| !part.is_empty() && !part.starts_with('.'));
    if plain {
        Ok(())
    } else {
        Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("{name:?} is not a blob name"),
        ))
    }
}

/// The content of blob `name` in memory, for small blobs. None if missing.
pub(crate) fn get_bytes(storage: &dyn Storage, name: &str) -> io::Result<Option<Vec<u8>>> {
    storage
        .get(name)?
        .map(|mut data| {
            let mut bytes = Vec::new();
            data.read_to_end(&mut bytes)?;
            Ok(bytes)
        })
        .transpose()
}

/// Makes the bytes written to `file` reach the disk before any later write
/// does, e.g. the rename that puts it in place: a crash then leaves the old
/// file or the new one, never a torn one. Doesn't wait for the disk itself,
/// so the latest writes may be lost, which is far cheaper on Apple's
/// platforms (`F_BARRIERFSYNC` rather than `F_FULLFSYNC`).
pub(crate) fn flush_ordered(file: &File) -> io::Result<()> {
    #[cfg(target_vendor = "apple")]
    {
        use std::os::fd::AsRawFd;
        // SAFETY: `fcntl` with a command that takes no argument, on a
        // descriptor `file` keeps open.
        if unsafe { libc::fcntl(file.as_raw_fd(), libc::F_BARRIERFSYNC) } == -1 {
            return Err(io::Error::last_os_error());
        }
        Ok(())
    }
    #[cfg(not(target_vendor = "apple"))]
    file.sync_data()
}

/// A name no other call in this process, or an earlier one, has used for a
/// scratch file or folder. Starts with the process ID.
pub(crate) fn unique_name() -> String {
    static NEXT: AtomicU32 = AtomicU32::new(0);
    format!("{}-{}", std::process::id(), NEXT.fetch_add(1, Relaxed))
}

/// `result`, except that a missing file or folder (`NotFound`) is `Ok`: there
/// was nothing to do.
pub(crate) fn ignore_not_found(result: io::Result<()>) -> io::Result<()> {
    match result {
        Err(e) if e.kind() != io::ErrorKind::NotFound => Err(e),
        _ => Ok(()),
    }
}

/// Streams `data` into a new file in the directory `staging`, then renames it
/// to `path`, so `path` is the old file or the new one, never a torn one. A
/// failure leaves no staged file.
pub(crate) fn write_atomically(staging: &Path, path: &Path, data: &mut dyn Read) -> io::Result<()> {
    let staged = staging.join(unique_name());
    let written = (|| {
        let mut file = File::create_new(&staged)?;
        io::copy(data, &mut file)?;
        flush_ordered(&file)?;
        fs::rename(&staged, path)
    })();
    if written.is_err() {
        let _ = fs::remove_file(&staged);
    }
    written
}

/// Asked to download the file at a path, see `DirStorage::on_download_needed`.
type DownloadRequest = Arc<dyn Fn(&Path) + Send + Sync>;

/// A storage in a directory of the file system.
pub struct DirStorage {
    root: PathBuf,
    download: Option<DownloadRequest>,
}

impl fmt::Debug for DirStorage {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        f.debug_struct("DirStorage")
            .field("root", &self.root)
            .finish_non_exhaustive()
    }
}

/// The placeholder iCloud Drive leaves for the file `name`, until it has
/// downloaded it.
fn placeholder(name: &str) -> String {
    format!(".{name}.icloud")
}

/// The file a placeholder stands for, if `name` is one.
fn placeholder_of(name: &str) -> Option<&str> {
    name.strip_prefix('.')?
        .strip_suffix(".icloud")
        .filter(|file| !file.is_empty())
}

/// Where blobs are written before they are renamed into place. Starts with a
/// dot, so it is no valid name and never listed.
const INCOMING: &str = ".incoming";

impl DirStorage {
    /// The storage in directory `root`, created if missing. Leftovers of
    /// `put`s that never finished are deleted, except those of this process:
    /// they belong to another storage in the same directory that is writing.
    pub fn open(root: impl Into<PathBuf>) -> io::Result<Self> {
        let root = root.into();
        let incoming = root.join(INCOMING);
        fs::create_dir_all(&incoming)?;
        let own = format!("{}-", std::process::id());
        for entry in fs::read_dir(&incoming)? {
            let entry = entry?;
            if !entry.file_name().to_string_lossy().starts_with(&own) {
                ignore_not_found(fs::remove_file(entry.path()))?;
            }
        }
        Ok(Self {
            root,
            download: None,
        })
    }

    /// Makes the storage recognize files that iCloud Drive has not downloaded
    /// yet, which it leaves as `.name.icloud` placeholders: they count as not
    /// there, and `request` is called with the path of the file, so a later
    /// call finds it.
    pub fn on_download_needed(mut self, request: impl Fn(&Path) + Send + Sync + 'static) -> Self {
        self.download = Some(Arc::new(request));
        self
    }

    /// Asks for the file at `path` to be downloaded if it is only a placeholder.
    fn request_if_placeholder(&self, path: &Path) -> io::Result<()> {
        let (Some(download), Some(name)) = (&self.download, path.file_name()) else {
            return Ok(());
        };
        let stand_in = path.with_file_name(placeholder(&name.to_string_lossy()));
        if stand_in.try_exists()? {
            download(path);
        }
        Ok(())
    }

    /// The path of `name`, which may not exist.
    fn path(&self, name: &str) -> io::Result<PathBuf> {
        check_name(name)?;
        Ok(self.root.join(name))
    }
}

impl Storage for DirStorage {
    fn put(&self, name: &str, data: &mut dyn Read) -> io::Result<()> {
        let path = self.path(name)?;
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }
        write_atomically(&self.root.join(INCOMING), &path, data)
    }

    fn get(&self, name: &str) -> io::Result<Option<Box<dyn Read + Send>>> {
        let path = self.path(name)?;
        match File::open(&path) {
            Ok(file) if file.metadata()?.is_file() => Ok(Some(Box::new(file))),
            Ok(_) => Ok(None),
            Err(e) if e.kind() == io::ErrorKind::NotFound => {
                self.request_if_placeholder(&path)?;
                Ok(None)
            }
            Err(e) => Err(e),
        }
    }

    fn list(&self, dir: &str) -> io::Result<Vec<Blob>> {
        let path = if dir.is_empty() {
            self.root.clone()
        } else {
            self.path(dir)?
        };
        let entries = match fs::read_dir(path) {
            Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(Vec::new()),
            result => result?,
        };
        let mut blobs = Vec::new();
        for entry in entries {
            let entry = entry?;
            let meta = entry.metadata()?;
            let name = entry.file_name().to_string_lossy().into_owned();
            if !meta.is_file() {
                continue;
            }
            if !name.starts_with('.') {
                blobs.push(Blob {
                    name,
                    size: meta.len(),
                });
            } else if let (Some(download), Some(file)) = (&self.download, placeholder_of(&name)) {
                download(&entry.path().with_file_name(file));
            }
        }
        Ok(blobs)
    }

    fn delete(&self, name: &str) -> io::Result<()> {
        ignore_not_found(fs::remove_file(self.path(name)?))
    }
}

/// The contract every `Storage` keeps, as tests. A storage runs them with
/// `storage_contract_tests!(make)`, where `make()` returns a new, empty
/// `Storage` (and whatever must stay alive with it), or none to skip the
/// tests, e.g. when the server they need isn't installed.
#[cfg(test)]
pub(crate) mod contract {
    use super::*;

    /// A fresh directory under the system temp dir, removed on drop.
    pub struct Scratch(pub PathBuf);

    impl Scratch {
        pub fn new(prefix: &str) -> Self {
            static NEXT: AtomicU32 = AtomicU32::new(0);
            let dir = std::env::temp_dir().join(format!(
                "leafpdf-{prefix}-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Relaxed)
            ));
            fs::create_dir_all(&dir).unwrap();
            Scratch(dir)
        }
    }

    impl Drop for Scratch {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    pub fn put_bytes(storage: &dyn Storage, name: &str, bytes: &[u8]) {
        storage.put(name, &mut &bytes[..]).unwrap();
    }

    pub fn names(storage: &dyn Storage, dir: &str) -> Vec<String> {
        let mut names: Vec<_> = storage
            .list(dir)
            .unwrap()
            .into_iter()
            .map(|b| b.name)
            .collect();
        names.sort();
        names
    }

    /// Yields `bytes`, then fails; asks `during` after the first read.
    struct Interrupted<'a> {
        bytes: &'a [u8],
        during: Option<Box<dyn FnOnce() + 'a>>,
    }

    impl Read for Interrupted<'_> {
        fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
            if self.bytes.is_empty() {
                return Err(io::Error::other("connection lost"));
            }
            let n = self.bytes.read(buf)?;
            if let Some(during) = self.during.take() {
                during();
            }
            Ok(n)
        }
    }

    pub fn a_blob_reads_back_as_stored(storage: &dyn Storage) {
        put_bytes(storage, "a/b/blob", b"hello");
        let bytes = get_bytes(storage, "a/b/blob").unwrap();
        assert_eq!(bytes.as_deref(), Some(&b"hello"[..]));
    }

    pub fn a_missing_blob_reads_as_none_and_deleting_it_does_nothing(storage: &dyn Storage) {
        assert!(get_bytes(storage, "nothing/here").unwrap().is_none());
        storage.delete("nothing/here").unwrap();
    }

    pub fn putting_again_replaces_the_blob(storage: &dyn Storage) {
        put_bytes(storage, "blob", b"first version");
        put_bytes(storage, "blob", b"second");
        assert_eq!(get_bytes(storage, "blob").unwrap().unwrap(), b"second");
        assert_eq!(storage.list("").unwrap().len(), 1);
    }

    pub fn a_deleted_blob_is_gone(storage: &dyn Storage) {
        put_bytes(storage, "d/one", b"1");
        put_bytes(storage, "d/two", b"22");
        storage.delete("d/one").unwrap();
        assert!(get_bytes(storage, "d/one").unwrap().is_none());
        assert_eq!(names(storage, "d"), ["two"]);
    }

    pub fn listing_gives_names_and_sizes_of_the_blobs_directly_in_a_directory(
        storage: &dyn Storage,
    ) {
        put_bytes(storage, "top", b"t");
        put_bytes(storage, "d/one", b"1");
        put_bytes(storage, "d/two", b"22");
        put_bytes(storage, "d/sub/deep", b"3");

        let mut listed = storage.list("d").unwrap();
        listed.sort_by(|a, b| a.name.cmp(&b.name));
        let expected = [("one", 1), ("two", 2)];
        let listed: Vec<_> = listed.iter().map(|b| (b.name.as_str(), b.size)).collect();
        assert_eq!(listed, expected);
        assert_eq!(names(storage, ""), ["top"]);
    }

    pub fn a_missing_directory_lists_as_empty(storage: &dyn Storage) {
        assert!(storage.list("nothing/here").unwrap().is_empty());
    }

    pub fn a_blob_is_not_visible_while_it_is_written(storage: &dyn Storage) {
        put_bytes(storage, "blob", b"old");
        let mut data = Interrupted {
            bytes: b"new content",
            during: Some(Box::new(|| {
                // Neither the new content nor a part of it, nor a stray name.
                let during = get_bytes(storage, "blob").unwrap().unwrap();
                assert_eq!(during, b"old");
                assert_eq!(names(storage, ""), ["blob"]);
            })),
        };
        // Fails after the first read, so the interrupted case runs here too.
        assert!(storage.put("blob", &mut data).is_err());
        assert_eq!(get_bytes(storage, "blob").unwrap().unwrap(), b"old");
    }

    pub fn a_failed_put_leaves_nothing_behind(storage: &dyn Storage) {
        let mut data = Interrupted {
            bytes: b"partial",
            during: None,
        };
        assert!(storage.put("new/blob", &mut data).is_err());
        assert!(get_bytes(storage, "new/blob").unwrap().is_none());
        assert!(storage.list("new").unwrap().is_empty());
        assert!(storage.list("").unwrap().is_empty());
    }

    macro_rules! storage_contract_tests {
        ($make:expr) => {
            storage_contract_tests!(
                $make,
                a_blob_reads_back_as_stored,
                a_missing_blob_reads_as_none_and_deleting_it_does_nothing,
                putting_again_replaces_the_blob,
                a_deleted_blob_is_gone,
                listing_gives_names_and_sizes_of_the_blobs_directly_in_a_directory,
                a_missing_directory_lists_as_empty,
                a_blob_is_not_visible_while_it_is_written,
                a_failed_put_leaves_nothing_behind
            );
        };
        ($make:expr, $($check:ident),+) => {
            $(
                #[test]
                fn $check() {
                    let Some((_alive, storage)) = $make() else {
                        return;
                    };
                    $crate::storage::contract::$check(&storage);
                }
            )+
        };
    }
    pub(crate) use storage_contract_tests;
}

#[cfg(test)]
mod tests {
    use super::contract::{Scratch, storage_contract_tests};
    use super::*;
    use std::sync::Mutex;

    fn scratch_storage() -> (Scratch, DirStorage) {
        let scratch = Scratch::new("storage");
        let storage = DirStorage::open(&scratch.0).unwrap();
        (scratch, storage)
    }

    mod dir_storage {
        use super::*;
        storage_contract_tests!(|| Some(scratch_storage()));
    }

    #[test]
    fn names_that_could_leave_the_storage_are_invalid_input() {
        let (_alive, storage) = scratch_storage();
        for name in ["", "../x", "a/../x", "/x", "a//b", ".incoming/x", ".hidden"] {
            let put = storage.put(name, &mut &b"x"[..]);
            assert_eq!(
                put.unwrap_err().kind(),
                io::ErrorKind::InvalidInput,
                "{name}"
            );
            assert!(storage.get(name).is_err(), "{name}");
            assert!(storage.delete(name).is_err(), "{name}");
        }
    }

    #[test]
    fn running_out_of_space_is_full_and_leaves_nothing_behind() {
        struct NoSpace;
        impl Read for NoSpace {
            fn read(&mut self, _: &mut [u8]) -> io::Result<usize> {
                Err(io::Error::from_raw_os_error(libc::ENOSPC))
            }
        }
        let (_alive, storage) = scratch_storage();

        let error = storage.put("blob", &mut NoSpace).unwrap_err();

        assert!(is_full(&error));
        assert!(storage.list("").unwrap().is_empty());
    }

    /// Records the files the storage asks to have downloaded.
    fn with_downloads(dir: &Path) -> (DirStorage, Arc<Mutex<Vec<PathBuf>>>) {
        let asked = Arc::new(Mutex::new(Vec::new()));
        let log = asked.clone();
        let storage = DirStorage::open(dir)
            .unwrap()
            .on_download_needed(move |path| log.lock().unwrap().push(path.to_owned()));
        (storage, asked)
    }

    #[test]
    fn a_file_not_downloaded_yet_is_not_listed_and_is_requested() {
        let scratch = Scratch::new("storage");
        let (storage, asked) = with_downloads(&scratch.0);
        fs::create_dir(scratch.0.join("d")).unwrap();
        fs::write(scratch.0.join("d/.later.icloud"), b"placeholder").unwrap();
        contract::put_bytes(&storage, "d/now", b"1");

        assert_eq!(contract::names(&storage, "d"), ["now"]);

        assert_eq!(*asked.lock().unwrap(), [scratch.0.join("d/later")]);
    }

    #[test]
    fn reading_a_file_not_downloaded_yet_finds_nothing_and_requests_it() {
        let scratch = Scratch::new("storage");
        let (storage, asked) = with_downloads(&scratch.0);
        fs::write(scratch.0.join(".later.icloud"), b"placeholder").unwrap();

        assert!(get_bytes(&storage, "later").unwrap().is_none());

        assert_eq!(*asked.lock().unwrap(), [scratch.0.join("later")]);
    }

    #[test]
    fn a_file_that_has_arrived_is_listed_and_read_without_a_request() {
        let scratch = Scratch::new("storage");
        let (storage, asked) = with_downloads(&scratch.0);
        contract::put_bytes(&storage, "here", b"1");

        assert_eq!(contract::names(&storage, ""), ["here"]);
        assert_eq!(get_bytes(&storage, "here").unwrap().unwrap(), b"1");

        assert!(asked.lock().unwrap().is_empty());
    }

    #[test]
    fn without_a_download_callback_placeholders_are_ignored() {
        let (alive, storage) = scratch_storage();
        fs::write(alive.0.join(".later.icloud"), b"placeholder").unwrap();

        assert!(storage.list("").unwrap().is_empty());
        assert!(get_bytes(&storage, "later").unwrap().is_none());
    }

    #[test]
    fn opening_discards_puts_that_never_finished() {
        let (alive, storage) = scratch_storage();
        fs::write(alive.0.join(INCOMING).join("stale"), b"half").unwrap();
        drop(storage);

        let storage = DirStorage::open(&alive.0).unwrap();

        assert!(
            fs::read_dir(alive.0.join(INCOMING))
                .unwrap()
                .next()
                .is_none()
        );
        assert!(storage.list("").unwrap().is_empty());
    }

    #[test]
    fn opening_keeps_the_puts_this_process_is_writing() {
        let (alive, _first) = scratch_storage();
        let writing = alive
            .0
            .join(INCOMING)
            .join(format!("{}-7", std::process::id()));
        fs::write(&writing, b"half").unwrap();

        let _second = DirStorage::open(&alive.0).unwrap();

        assert!(writing.exists());
    }
}
