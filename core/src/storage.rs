//! The storage interface every Cloud Provider implements (ADR-0010), and the
//! directory-backed storage, which is also the future Folder provider.
//!
//! A storage is plain remote file storage: named blobs in directories, no
//! transactions, no server logic (ADR-0017). Everything above it, from the
//! remote layout to merging, is in the core.

use std::fs::{self, File};
use std::io::{self, Read};
use std::path::PathBuf;
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

/// Named blobs in `/`-separated directories, e.g. `v1/files/abc`.
///
/// Names are plain: every part is non-empty, isn't `.` or `..`, and doesn't
/// start with a dot. Anything else is `InvalidInput`. Directories exist as soon
/// as a blob is in them; a missing one is empty.
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

/// A storage in a directory of the file system.
#[derive(Debug)]
pub struct DirStorage {
    root: PathBuf,
}

/// Where blobs are written before they are renamed into place. Starts with a
/// dot, so it is no valid name and never listed.
const INCOMING: &str = ".incoming";

impl DirStorage {
    /// The storage in directory `root`, created if missing. Leftovers of
    /// `put`s that never finished are deleted.
    pub fn open(root: impl Into<PathBuf>) -> io::Result<Self> {
        let root = root.into();
        match fs::remove_dir_all(root.join(INCOMING)) {
            Err(e) if e.kind() != io::ErrorKind::NotFound => return Err(e),
            _ => {}
        }
        fs::create_dir_all(root.join(INCOMING))?;
        Ok(Self { root })
    }

    /// The path of `name`, which may not exist.
    fn path(&self, name: &str) -> io::Result<PathBuf> {
        let plain = !name.is_empty()
            && name
                .split('/')
                .all(|part| !part.is_empty() && !part.starts_with('.'));
        if !plain {
            return Err(invalid_name(name));
        }
        Ok(self.root.join(name))
    }
}

fn invalid_name(name: &str) -> io::Error {
    io::Error::new(
        io::ErrorKind::InvalidInput,
        format!("{name:?} is not a blob name"),
    )
}

impl Storage for DirStorage {
    fn put(&self, name: &str, data: &mut dyn Read) -> io::Result<()> {
        let path = self.path(name)?;
        static NEXT: AtomicU32 = AtomicU32::new(0);
        let incoming = self.root.join(INCOMING).join(format!(
            "{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Relaxed)
        ));
        let written = (|| {
            let mut file = File::create_new(&incoming)?;
            io::copy(data, &mut file)?;
            file.sync_all()?;
            if let Some(parent) = path.parent() {
                fs::create_dir_all(parent)?;
            }
            fs::rename(&incoming, &path)
        })();
        if written.is_err() {
            let _ = fs::remove_file(&incoming);
        }
        written
    }

    fn get(&self, name: &str) -> io::Result<Option<Box<dyn Read + Send>>> {
        match File::open(self.path(name)?) {
            Ok(file) if file.metadata()?.is_file() => Ok(Some(Box::new(file))),
            Ok(_) => Ok(None),
            Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(None),
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
            if meta.is_file() && !name.starts_with('.') {
                blobs.push(Blob {
                    name,
                    size: meta.len(),
                });
            }
        }
        Ok(blobs)
    }

    fn delete(&self, name: &str) -> io::Result<()> {
        match fs::remove_file(self.path(name)?) {
            Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(()),
            result => result,
        }
    }
}

/// The contract every `Storage` keeps, as tests. A storage runs them with
/// `storage_contract_tests!(make)`, where `make()` returns a new, empty
/// `Storage` (and whatever must stay alive with it).
#[cfg(test)]
pub(crate) mod contract {
    use super::*;

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
                    let (_alive, storage) = $make();
                    $crate::storage::contract::$check(&storage);
                }
            )+
        };
    }
    pub(crate) use storage_contract_tests;
}

#[cfg(test)]
mod tests {
    use super::contract::storage_contract_tests;
    use super::*;

    /// A fresh directory under the system temp dir, removed on drop.
    struct Scratch(PathBuf);

    impl Drop for Scratch {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    fn scratch_storage() -> (Scratch, DirStorage) {
        static NEXT: AtomicU32 = AtomicU32::new(0);
        let dir = std::env::temp_dir().join(format!(
            "leafpdf-storage-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Relaxed)
        ));
        let storage = DirStorage::open(&dir).unwrap();
        (Scratch(dir), storage)
    }

    mod dir_storage {
        use super::*;
        storage_contract_tests!(scratch_storage);
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
}
