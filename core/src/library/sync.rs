//! Sync: exchanging the Library and its Files with a Cloud Provider's storage
//! (ADR-0009, ADR-0015, ADR-0016, ADR-0017).
//!
//! The remote layout, versioned so it can change later:
//!
//! - `v1/library/<device>-<number>`: chunks of the Library document, see
//!   `chunks`.
//! - `v1/files/<sha256>`: each File once, whichever Device uploaded it first.
//!
//! A Document is listed only once its File is stored here, so a Sync that
//! learns of a Document lists it when its File has arrived.

use super::*;
use crate::chunks;
use crate::storage::Storage;

const LIBRARY_DIR: &str = "v1/library";
const FILES_DIR: &str = "v1/files";

impl Library {
    /// One Sync step with `storage`, which is shared by all of the user's
    /// Devices: merges the Library document of the other Devices, sends this
    /// Device's changes, uploads the Files the storage lacks and downloads the
    /// ones this Device lacks, those Read last first, then those Imported
    /// last first.
    ///
    /// A step with nothing new costs one listing per directory. A File whose
    /// bytes don't match its hash is not stored. The Library is tied to no
    /// storage: it sends everything to one that lacks it.
    pub fn sync(&self, storage: &dyn Storage) -> io::Result<()> {
        let mut cursor = self.cursor.lock().unwrap_or_else(PoisonError::into_inner);
        if self.exchange_library(storage, &mut cursor)? {
            // Removes and names of other Devices.
            self.sync_changes.fetch_add(1, Relaxed);
            self.reconcile()?;
        }
        let remote_files: HashSet<String> = storage
            .list(FILES_DIR)?
            .into_iter()
            .map(|blob| blob.name)
            .collect();
        self.upload_files(storage, &remote_files)?;
        self.download_files(storage, &remote_files)
    }

    /// Merges the other Devices' chunks of the Library document and sends this
    /// Device's own. True if the Library document changed.
    fn exchange_library(&self, storage: &dyn Storage, cursor: &mut Cursor) -> io::Result<bool> {
        let before = cursor.clone();
        let pulled = chunks::pull(storage, LIBRARY_DIR, &self.device_id(), cursor)?;
        let (merged, outgoing) = {
            let mut doc = self.catalog();
            let merged = doc.merge(cursor, pulled);
            if merged && let Err(e) = self.save_catalog(&mut doc) {
                *cursor = before;
                return Err(e);
            }
            (merged, doc.outgoing(cursor))
        };
        // The network runs without the lock, so Imports and Removes aren't held
        // up. The cursor is stored after the document, so it never counts
        // something as applied that was lost.
        let sent = match outgoing {
            Some(outgoing) => chunks::push(storage, LIBRARY_DIR, cursor, outgoing),
            None => Ok(()),
        };
        if *cursor != before {
            let path = self.root.join(LIBRARY_CURSOR);
            write_atomically(&self.staging(), &path, cursor.encode().as_bytes())?;
        }
        sent.map(|()| merged)
    }

    /// Uploads the stored Files of listed Documents that aren't among `remote`.
    fn upload_files(&self, storage: &dyn Storage, remote: &HashSet<String>) -> io::Result<()> {
        for entry in self.entries().iter().filter(|e| !remote.contains(&e.id)) {
            let Some(path) = self.file_path(entry)? else {
                continue;
            };
            match File::open(path) {
                // Removed meanwhile.
                Err(e) if e.kind() == io::ErrorKind::NotFound => {}
                file => storage.put(&format!("{FILES_DIR}/{}", entry.id), &mut file?)?,
            }
        }
        Ok(())
    }

    /// Downloads the Files of listed Documents that are among `remote` and not
    /// stored here.
    fn download_files(&self, storage: &dyn Storage, remote: &HashSet<String>) -> io::Result<()> {
        let mut missing = Vec::new();
        for entry in self.entries() {
            if remote.contains(&entry.id)
                && is_file_name(&entry.name)
                && self.file_path(&entry)?.is_none()
            {
                missing.push((self.last_read(&entry), entry));
            }
        }
        // Never read sorts last: `None` is less than any `Some`.
        missing.sort_by(|(a_read, a), (b_read, b)| {
            (b_read, b.imported, &a.id).cmp(&(a_read, a.imported, &b.id))
        });
        for (_, entry) in missing {
            self.download_file(storage, &entry)?;
        }
        Ok(())
    }

    /// When the Document of `entry` was last read, if ever, according to the
    /// state stored here.
    fn last_read(&self, entry: &Entry) -> Option<u64> {
        let states = self.read_states(&entry.id, &entry.imports);
        progress::read_all(states.iter().map(Vec::as_slice)).map(|p| p.last_read)
    }

    /// Downloads the File of `entry` into its folder, unless the Document was
    /// Removed or got its File meanwhile.
    fn download_file(&self, storage: &dyn Storage, entry: &Entry) -> io::Result<()> {
        let Some(mut data) = storage.get(&format!("{FILES_DIR}/{}", entry.id))? else {
            return Ok(());
        };
        let staged = self.staging().join(unique_name());
        fs::create_dir(&staged)?;
        let result = stream_hashed(&mut data, &staged.join(&entry.name), 0, |_, _| {})
            .and_then(|hash| self.install(&staged, entry, &hash));
        // Nothing left to remove after a successful rename.
        let _ = fs::remove_dir_all(&staged);
        result
    }

    /// Moves the downloaded File in `staged` into the Document folder of
    /// `entry`, if its bytes are those of the Document, the Library document
    /// still lists it and its File isn't there already.
    fn install(&self, staged: &Path, entry: &Entry, hash: &str) -> io::Result<()> {
        let doc = self.catalog();
        let folder = self.root.join(&entry.id);
        if hash != entry.id || doc.live(&entry.id).next().is_none() {
            return Ok(());
        }
        if !folder.exists() {
            fs::rename(staged, folder)?;
        } else if self.file_path(entry)?.is_none() {
            // The folder may hold a state already.
            fs::rename(staged.join(&entry.name), folder.join(&entry.name))?;
        } else {
            return Ok(());
        }
        self.sync_changes.fetch_add(1, Relaxed);
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::storage::DirStorage;
    use std::thread::sleep;
    use std::time::Duration;

    /// Devices sharing one cloud: each has its own Library folder, and all
    /// sync with the one storage directory.
    struct Cloud {
        dir: PathBuf,
        next_device: u32,
    }

    impl Cloud {
        fn new() -> Self {
            static NEXT: AtomicU32 = AtomicU32::new(0);
            let dir = std::env::temp_dir().join(format!(
                "leafpdf-sync-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Relaxed)
            ));
            fs::create_dir_all(&dir).unwrap();
            Cloud {
                dir,
                next_device: 0,
            }
        }

        fn storage(&self) -> DirStorage {
            DirStorage::open(self.dir.join("cloud")).unwrap()
        }

        /// A new Device with an empty Library, not Connected yet.
        fn device(&mut self) -> Device {
            self.next_device += 1;
            let home = self.dir.join(format!("device-{}", self.next_device));
            Device {
                library: Library::open(home.join("library")).unwrap(),
                home,
                storage: self.storage(),
            }
        }

        /// The files in the cloud with exactly the content `bytes`, wherever
        /// they are.
        fn blobs_with(&self, bytes: &[u8]) -> Vec<PathBuf> {
            let mut found = Vec::new();
            let mut todo = vec![self.dir.join("cloud")];
            while let Some(dir) = todo.pop() {
                for entry in fs::read_dir(dir).unwrap() {
                    let path = entry.unwrap().path();
                    if path.is_dir() {
                        todo.push(path);
                    } else if fs::read(&path).unwrap() == bytes {
                        found.push(path);
                    }
                }
            }
            found
        }
    }

    impl Drop for Cloud {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.dir);
        }
    }

    struct Device {
        library: Library,
        home: PathBuf,
        storage: DirStorage,
    }

    impl Device {
        fn import(&self, name: &str, bytes: &[u8]) -> Document {
            let source = self.home.join(name);
            fs::write(&source, bytes).unwrap();
            match self.library.import(&source, |_, _| {}).unwrap() {
                ImportResult::Imported(document) | ImportResult::AlreadyImported(document) => {
                    document
                }
            }
        }

        fn sync(&self) {
            self.library.sync(&self.storage).unwrap();
        }

        fn ids(&self) -> Vec<String> {
            self.library
                .documents()
                .unwrap()
                .into_iter()
                .map(|d| d.id)
                .collect()
        }

        fn document(&self, id: &str) -> Document {
            let documents = self.library.documents().unwrap();
            documents.into_iter().find(|d| d.id == id).unwrap()
        }
    }

    /// Wraps a storage and records the names of the blobs read.
    struct Recording {
        inner: DirStorage,
        gets: Mutex<Vec<String>>,
    }

    impl Storage for Recording {
        fn put(&self, name: &str, data: &mut dyn Read) -> io::Result<()> {
            self.inner.put(name, data)
        }
        fn get(&self, name: &str) -> io::Result<Option<Box<dyn Read + Send>>> {
            self.gets.lock().unwrap().push(name.to_owned());
            self.inner.get(name)
        }
        fn list(&self, dir: &str) -> io::Result<Vec<crate::storage::Blob>> {
            self.inner.list(dir)
        }
        fn delete(&self, name: &str) -> io::Result<()> {
            self.inner.delete(name)
        }
    }

    #[test]
    fn an_imported_document_reaches_another_device_with_file_and_name() {
        let mut cloud = Cloud::new();
        let (a, b) = (cloud.device(), cloud.device());
        let imported = a.import("Paper.pdf", b"paper bytes");

        a.sync();
        b.sync();

        let document = b.document(&imported.id);
        assert_eq!(fs::read(&document.path).unwrap(), b"paper bytes");
        assert_eq!(document.path.file_name().unwrap(), "Paper.pdf");
        assert!(document.progress.is_none());
    }

    #[test]
    fn a_document_is_listed_in_the_order_of_its_import_on_the_other_device() {
        let mut cloud = Cloud::new();
        let (a, b) = (cloud.device(), cloud.device());
        let first = a.import("a.pdf", b"first");
        sleep(Duration::from_millis(20));
        let second = a.import("b.pdf", b"second");

        a.sync();
        b.sync();

        // Downloaded newest first, so a download date would give the reverse.
        assert_eq!(b.ids(), [second.id.clone(), first.id.clone()]);
        // Stays so after another step, and on the first Device.
        b.sync();
        a.sync();
        assert_eq!(b.ids(), [second.id.clone(), first.id.clone()]);
        assert_eq!(a.ids(), [second.id, first.id]);
    }

    #[test]
    fn connecting_a_library_with_documents_merges_both_sides() {
        let mut cloud = Cloud::new();
        let (a, b) = (cloud.device(), cloud.device());
        let on_a = a.import("a.pdf", b"on a");
        a.sync();
        let on_b = b.import("b.pdf", b"on b");

        b.sync();
        a.sync();

        for device in [&a, &b] {
            let mut ids = device.ids();
            ids.sort();
            let mut expected = vec![on_a.id.clone(), on_b.id.clone()];
            expected.sort();
            assert_eq!(ids, expected);
            assert_eq!(fs::read(&device.document(&on_a.id).path).unwrap(), b"on a");
            assert_eq!(fs::read(&device.document(&on_b.id).path).unwrap(), b"on b");
        }
    }

    #[test]
    fn files_download_in_the_order_of_last_read_then_date_imported() {
        let mut cloud = Cloud::new();
        let b = cloud.device();
        let old = b.import("old.pdf", b"old");
        sleep(Duration::from_millis(20));
        let read_early = b.import("early.pdf", b"early");
        let read_late = b.import("late.pdf", b"late");
        sleep(Duration::from_millis(20));
        let newest = b.import("newest.pdf", b"newest");
        for (document, last_read) in [(&read_early, 100), (&read_late, 200)] {
            let progress = ReadingProgress {
                page_index: 1,
                x: 0.0,
                y: 0.0,
                last_read,
            };
            b.library.save_progress(&document.id, &progress).unwrap();
        }
        b.sync();
        // The Files get lost on this Device, the Library keeps listing them.
        for document in [&old, &read_early, &read_late, &newest] {
            fs::remove_file(&document.path).unwrap();
        }

        let recording = Recording {
            inner: cloud.storage(),
            gets: Mutex::new(Vec::new()),
        };
        b.library.sync(&recording).unwrap();

        let downloads: Vec<_> = recording
            .gets
            .lock()
            .unwrap()
            .iter()
            .filter_map(|name| {
                [&old, &read_early, &read_late, &newest]
                    .iter()
                    .position(|d| name.contains(&d.id))
            })
            .collect();
        // Last Read: late, early; never read: newest, old.
        assert_eq!(downloads, [2, 1, 3, 0]);
        assert_eq!(b.ids().len(), 4);
    }

    #[test]
    fn the_same_file_imported_on_two_devices_apart_is_listed_once_with_the_earliest_date() {
        let mut cloud = Cloud::new();
        let (a, b) = (cloud.device(), cloud.device());
        let shared_on_a = a.import("on-a.pdf", b"shared");
        sleep(Duration::from_millis(20));
        let other = b.import("other.pdf", b"other");
        sleep(Duration::from_millis(20));
        b.import("on-b.pdf", b"shared");

        a.sync();
        b.sync();
        a.sync();

        // Imported on A first, so after B's other one in the newest-first list.
        for device in [&a, &b] {
            assert_eq!(device.ids(), [other.id.clone(), shared_on_a.id.clone()]);
        }
        // Under the name of the first Import, on both.
        assert_eq!(
            b.document(&shared_on_a.id).path.file_name().unwrap(),
            "on-a.pdf"
        );
        assert_eq!(
            fs::read(&b.document(&shared_on_a.id).path).unwrap(),
            b"shared"
        );
    }

    #[test]
    fn a_file_the_library_lists_but_the_cloud_lacks_is_uploaded_again() {
        let mut cloud = Cloud::new();
        let (a, b) = (cloud.device(), cloud.device());
        a.import("a.pdf", b"precious");
        a.sync();
        let blobs = cloud.blobs_with(b"precious");
        assert_eq!(blobs.len(), 1);
        fs::remove_file(&blobs[0]).unwrap();

        a.sync();
        b.sync();

        assert_eq!(cloud.blobs_with(b"precious").len(), 1);
        assert_eq!(b.ids().len(), 1);
    }

    #[test]
    fn another_device_that_has_the_file_uploads_it_when_the_cloud_lacks_it() {
        let mut cloud = Cloud::new();
        let (a, b, c) = (cloud.device(), cloud.device(), cloud.device());
        let document = a.import("a.pdf", b"precious");
        a.sync();
        b.sync();
        fs::remove_file(&cloud.blobs_with(b"precious")[0]).unwrap();
        // B has the File too, so any of the two puts it back.
        b.sync();
        c.sync();

        assert_eq!(c.ids(), [document.id]);
    }

    #[test]
    fn imports_made_before_a_sync_upload_on_the_next_one() {
        let mut cloud = Cloud::new();
        let (a, b) = (cloud.device(), cloud.device());
        let first = a.import("a.pdf", b"made offline");
        let second = a.import("b.pdf", b"also offline");
        // A step that can't reach the cloud fails and changes nothing.
        fs::write(cloud.dir.join("cloud").join("v1"), b"in the way").unwrap();
        assert!(a.library.sync(&a.storage).is_err());
        fs::remove_file(cloud.dir.join("cloud").join("v1")).unwrap();

        a.sync();
        b.sync();

        let mut ids = b.ids();
        ids.sort();
        let mut expected = vec![first.id, second.id];
        expected.sort();
        assert_eq!(ids, expected);
    }

    #[test]
    fn a_step_with_nothing_new_reads_nothing() {
        let mut cloud = Cloud::new();
        let (a, b) = (cloud.device(), cloud.device());
        a.import("a.pdf", b"x");
        a.sync();
        b.sync();

        let recording = Recording {
            inner: cloud.storage(),
            gets: Mutex::new(Vec::new()),
        };
        a.library.sync(&recording).unwrap();
        b.library.sync(&recording).unwrap();

        assert!(recording.gets.lock().unwrap().is_empty());
    }

    #[test]
    fn a_synced_library_survives_reopening_without_downloading_again() {
        let mut cloud = Cloud::new();
        let (a, b) = (cloud.device(), cloud.device());
        a.import("a.pdf", b"x");
        a.sync();
        b.sync();
        let root = b.home.join("library");
        drop(b);

        let library = Library::open(&root).unwrap();
        let recording = Recording {
            inner: cloud.storage(),
            gets: Mutex::new(Vec::new()),
        };
        library.sync(&recording).unwrap();

        assert!(recording.gets.lock().unwrap().is_empty());
        assert_eq!(library.documents().unwrap().len(), 1);
    }

    #[test]
    fn a_library_syncs_to_another_cloud_by_sending_everything_to_it() {
        let mut cloud = Cloud::new();
        let mut elsewhere = Cloud::new();
        let (a, c) = (cloud.device(), elsewhere.device());
        let document = a.import("a.pdf", b"x");
        a.sync();

        a.library.sync(&elsewhere.storage()).unwrap();
        c.sync();

        assert_eq!(c.ids(), [document.id]);
    }

    #[test]
    fn a_file_that_does_not_match_its_hash_is_not_stored() {
        let mut cloud = Cloud::new();
        let (a, b) = (cloud.device(), cloud.device());
        let document = a.import("a.pdf", b"genuine");
        a.sync();
        let blob = cloud.blobs_with(b"genuine").remove(0);
        fs::write(blob, b"tampered").unwrap();

        b.sync();

        assert!(b.ids().is_empty());
        assert!(!b.home.join("library").join(&document.id).exists());
    }

    #[test]
    fn a_documents_progress_is_kept_when_a_lost_file_downloads_again() {
        let mut cloud = Cloud::new();
        let a = cloud.device();
        let document = a.import("a.pdf", b"x");
        let progress = ReadingProgress {
            page_index: 3,
            x: 1.0,
            y: 2.0,
            last_read: 5,
        };
        a.library.save_progress(&document.id, &progress).unwrap();
        a.sync();
        fs::remove_file(&document.path).unwrap();
        assert!(a.ids().is_empty());

        a.sync();

        assert_eq!(a.document(&document.id).progress, Some(progress));
    }
}
