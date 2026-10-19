//! Sync: exchanging the Library, the states, the Preferences and the Files with
//! a Cloud Provider's storage (ADR-0009, ADR-0014, ADR-0015, ADR-0016,
//! ADR-0017).
//!
//! The remote layout, versioned so it can change later:
//!
//! - `v1/library/<device>-<number>`: chunks of the Library document, see
//!   `chunks`.
//! - `v1/state/<import>.<device>-<number>`: chunks of the state of each Import
//!   (Reading Progress and Markup). One directory for all of them, so one
//!   listing tells which have news.
//! - `v1/preferences/<device>-<number>`: chunks of the Preferences.
//! - `v1/files/<sha256>`: each File once, whichever Device uploaded it first.
//!
//! A Document is listed only once its File is stored here, so a Sync that
//! learns of a Document lists it when its File has arrived. Its state may
//! arrive first, into a folder without a File: that tells the order the Files
//! download in.

use super::*;
use crate::chunks;
use crate::storage::{Blob, Storage};

const LIBRARY_DIR: &str = "v1/library";
const STATE_DIR: &str = "v1/state";
const PREFERENCES_DIR: &str = "v1/preferences";
const FILES_DIR: &str = "v1/files";

/// What this Device knows of the exchange stored in the cursor file `path`.
fn read_cursor(path: &Path) -> Cursor {
    Cursor::decode(&fs::read_to_string(path).unwrap_or_default())
}

/// One synced Automerge document that is stored in a file.
struct Target {
    /// The remote directory of its chunks.
    dir: &'static str,
    /// What its chunks' names start with.
    prefix: String,
    path: PathBuf,
    cursor_path: PathBuf,
}

/// What a merge changed in a document: its stored bytes before and after.
struct Merged {
    before: Option<Vec<u8>>,
    after: Vec<u8>,
}

impl Library {
    /// One Sync step with `storage`, which is shared by all of the user's
    /// Devices: merges the Library document, the states and the Preferences of
    /// the other Devices, sends this Device's changes, uploads the Files the
    /// storage lacks and downloads the ones this Device lacks, those Read last
    /// first, then those Imported last first. Files of Removed Documents are
    /// deleted from the storage, and so are this Device's chunks of the states
    /// of Removed Imports.
    ///
    /// A step with nothing new costs one listing per directory and loads no
    /// document. A File whose bytes don't match its hash is not stored. The
    /// Library is tied to no storage: it sends everything to one that lacks it.
    pub fn sync(&self, storage: &dyn Storage) -> io::Result<()> {
        let mut exchanges = self
            .exchanges
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        if self.exchange_library(storage, &mut exchanges.library)? {
            // Removes and names of other Devices.
            self.sync_changes.fetch_add(1, Relaxed);
            self.reconcile()?;
        }
        let everything = std::mem::take(&mut self.dirty().everything);
        let result = self
            .exchange_preferences(storage, &mut exchanges, everything)
            .and_then(|()| self.exchange_states(storage, &mut exchanges, everything));
        if result.is_err() {
            self.dirty().everything |= everything;
        }
        result?;
        let remote_files: HashSet<String> = storage
            .list(FILES_DIR)?
            .into_iter()
            .map(|blob| blob.name)
            .collect();
        self.delete_removed_files(storage, &remote_files)?;
        self.upload_files(storage, &remote_files)?;
        self.download_files(storage, &remote_files)
    }

    fn dirty(&self) -> MutexGuard<'_, Dirty> {
        self.dirty.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Merges the other Devices' chunks of the Library document and sends this
    /// Device's own. True if the Library document changed.
    fn exchange_library(&self, storage: &dyn Storage, cursor: &mut Cursor) -> io::Result<bool> {
        let before = cursor.clone();
        let listing = storage.list(LIBRARY_DIR)?;
        let pulled = chunks::pull(
            storage,
            LIBRARY_DIR,
            &listing,
            "",
            &self.device_id(),
            cursor,
        )?;
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

    /// Exchanges the Preferences. `everything`: send local changes made before
    /// this Library was opened too.
    fn exchange_preferences(
        &self,
        storage: &dyn Storage,
        exchanges: &mut Exchanges,
        everything: bool,
    ) -> io::Result<()> {
        let target = Target {
            dir: PREFERENCES_DIR,
            prefix: String::new(),
            path: self.preferences(),
            cursor_path: self.root.join(PREFERENCES_CURSOR),
        };
        let blobs = storage.list(PREFERENCES_DIR)?;
        let dirty = everything || self.dirty().keys.remove(PREFERENCES_KEY);
        let cursor = exchanges
            .docs
            .entry(PREFERENCES_KEY.to_owned())
            .or_insert_with(|| read_cursor(&target.cursor_path));
        let merged = self
            .exchange_doc(storage, &target, &blobs, cursor, dirty, |bytes| {
                write_atomically(&self.staging(), &target.path, bytes).map(|()| true)
            })
            .inspect_err(|_| self.mark_dirty(PREFERENCES_KEY))?;
        if let Some(Merged { before, after }) = merged {
            let colors = |bytes: Option<&[u8]>| {
                (
                    preferences::colors(bytes),
                    preferences::default_color(bytes),
                )
            };
            if colors(before.as_deref()) != colors(Some(&after)) {
                self.sync_changes.fetch_add(1, Relaxed);
            }
        }
        Ok(())
    }

    /// Exchanges the state of every Import the Library document lists.
    /// `everything`: send local changes made before this Library was opened
    /// too.
    fn exchange_states(
        &self,
        storage: &dyn Storage,
        exchanges: &mut Exchanges,
        everything: bool,
    ) -> io::Result<()> {
        let listing = storage.list(STATE_DIR)?;
        let mut remote: HashMap<&str, Vec<Blob>> = HashMap::new();
        for blob in &listing {
            if let Some((import, _)) = blob.name.split_once('.') {
                remote.entry(import).or_default().push(blob.clone());
            }
        }
        let mut imports = Vec::new();
        let mut removed = HashSet::new();
        for i in self.catalog().imports() {
            if i.removed {
                removed.insert(i.id.clone());
            } else {
                imports.push((i.id.clone(), i.hash.clone()));
            }
        }
        exchanges.docs.retain(|import, _| !removed.contains(import));
        self.delete_own_chunks(storage, &listing, &removed)?;
        for (import, hash) in imports {
            let folder = self.root.join(&hash);
            let target = Target {
                dir: STATE_DIR,
                prefix: format!("{import}."),
                path: folder.join(state_name(&import)),
                cursor_path: folder.join(cursor_name(&import)),
            };
            let blobs = remote.get(import.as_str()).map_or(&[][..], Vec::as_slice);
            let dirty = everything || self.dirty().keys.remove(&import);
            let cursor = exchanges
                .docs
                .entry(import.clone())
                .or_insert_with(|| read_cursor(&target.cursor_path));
            let merged = self
                .exchange_doc(storage, &target, blobs, cursor, dirty, |bytes| {
                    self.store_state(&folder, &import, &target.path, bytes)
                })
                .inspect_err(|_| self.mark_dirty(&import))?;
            if let Some(merged) = merged {
                self.report_merged_state(&hash, &merged);
            }
        }
        Ok(())
    }

    /// Deletes this Device's chunks among `listing`, the blobs of the state
    /// directory, of the Imports `removed`. Other Devices delete theirs.
    fn delete_own_chunks(
        &self,
        storage: &dyn Storage,
        listing: &[Blob],
        removed: &HashSet<String>,
    ) -> io::Result<()> {
        let device = self.device_id();
        for blob in listing {
            let own_of_removed = blob
                .name
                .split_once('.')
                .and_then(|(import, chunk)| Some((import, chunk.rsplit_once('-')?.0)))
                .is_some_and(|(import, from)| from == device && removed.contains(import));
            if own_of_removed {
                storage.delete(&format!("{STATE_DIR}/{}", blob.name))?;
            }
        }
        Ok(())
    }

    /// Deletes the Files `remote` lists that were Removed, unless the Library
    /// document lists a live Import of them. One uploaded again by a Device
    /// that had not learned of the Remove goes at the next step.
    fn delete_removed_files(
        &self,
        storage: &dyn Storage,
        remote: &HashSet<String>,
    ) -> io::Result<()> {
        let doomed: Vec<String> = {
            let doc = self.catalog();
            let removed = doc.removed_files();
            remote
                .iter()
                .filter(|hash| removed.contains(hash.as_str()))
                .cloned()
                .collect()
        };
        for hash in doomed {
            storage.delete(&format!("{FILES_DIR}/{hash}"))?;
        }
        Ok(())
    }

    /// Stores the merged state `bytes` of Import `import` at `path` in the
    /// Document `folder`, creating it if needed. False if the Import was
    /// Removed meanwhile: nothing is stored.
    fn store_state(
        &self,
        folder: &Path,
        import: &str,
        path: &Path,
        bytes: &[u8],
    ) -> io::Result<bool> {
        let doc = self.catalog();
        if !doc.imports().iter().any(|i| i.id == import && !i.removed) {
            return Ok(false);
        }
        fs::create_dir_all(folder)?;
        write_atomically(&self.staging(), path, bytes)?;
        Ok(true)
    }

    /// Tells what a merge of a state changed: Reading Progress is part of the
    /// Documents, Markup is reported by Document.
    fn report_merged_state(&self, hash: &str, merged: &Merged) {
        let before = merged.before.as_deref();
        let progress = |bytes: Option<&[u8]>| bytes.and_then(progress::read);
        if progress(before) != progress(Some(&merged.after)) {
            self.sync_changes.fetch_add(1, Relaxed);
        }
        let markup = |bytes: Option<&[u8]>| markup::read_all(bytes);
        if markup(before) != markup(Some(&merged.after)) {
            let mut changed = self
                .markup_changes
                .lock()
                .unwrap_or_else(PoisonError::into_inner);
            if !changed.iter().any(|id| id == hash) {
                changed.push(hash.to_owned());
            }
        }
    }

    /// Exchanges the document `target` with `storage`, `blobs` being the
    /// listing of its directory: merges other Devices' new chunks into it and
    /// sends this Device's own changes. Loads the document only if there is
    /// something to do: `dirty`, new chunks or chunks the storage lost.
    /// `store` writes merged bytes and tells whether it did (the document may
    /// be gone). Returns what a merge changed.
    fn exchange_doc(
        &self,
        storage: &dyn Storage,
        target: &Target,
        blobs: &[Blob],
        cursor: &mut Cursor,
        dirty: bool,
        store: impl FnOnce(&[u8]) -> io::Result<bool>,
    ) -> io::Result<Option<Merged>> {
        let before = cursor.clone();
        let device = self.device_id();
        let pulled = chunks::pull(storage, target.dir, blobs, &target.prefix, &device, cursor)?;
        if !dirty && !cursor.wants(&pulled) {
            return Ok(None);
        }
        let (merged, outgoing) = {
            let _writing = self.writing();
            let existing = fs::read(&target.path).ok();
            let mut doc = existing
                .as_deref()
                .and_then(|bytes| AutoCommit::load(bytes).ok())
                .unwrap_or_default()
                .with_actor(self.device_id.clone());
            let mut merged = None;
            if cursor.apply(&mut doc, pulled) {
                let after = doc.save();
                // Gone: the Document was Removed. What was pulled is
                // fetched again if it comes back.
                if !store(&after)? {
                    *cursor = before;
                    return Ok(None);
                }
                merged = Some(Merged {
                    before: existing,
                    after,
                });
            }
            (merged, cursor.outgoing(&mut doc, &target.prefix))
        };
        // The cursor is stored after the document, so it never counts
        // something as applied that was lost.
        let sent = match outgoing {
            Some(outgoing) => chunks::push(storage, target.dir, cursor, outgoing),
            None => Ok(()),
        };
        if *cursor != before {
            match write_atomically(
                &self.staging(),
                &target.cursor_path,
                cursor.encode().as_bytes(),
            ) {
                // The folder is gone: the Document was Removed.
                Err(e) if e.kind() == io::ErrorKind::NotFound => {}
                result => result?,
            }
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
    use crate::markup::{Highlight, PageRects, Rgb};
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

    fn progress(page_index: u32, last_read: u64) -> ReadingProgress {
        ReadingProgress {
            page_index,
            x: 0.0,
            y: 0.0,
            last_read,
        }
    }

    fn highlight(device: &Device, id: &str, text: &str) -> Highlight {
        let anchor = vec![PageRects {
            page_index: 0,
            rects: vec![],
        }];
        let color = Rgb { r: 1, g: 2, b: 3 };
        device
            .library
            .add_highlight(id, anchor, text, color, 1)
            .unwrap()
    }

    /// Two Devices that both hold one Document, imported on the first.
    fn two_devices_with_a_document(cloud: &mut Cloud) -> (Device, Device, String) {
        let (a, b) = (cloud.device(), cloud.device());
        let id = a.import("a.pdf", b"shared document").id;
        a.sync();
        b.sync();
        (a, b, id)
    }

    /// Each Device sends, then both receive.
    fn settle(a: &Device, b: &Device) {
        a.sync();
        b.sync();
        a.sync();
    }

    #[test]
    fn reading_progress_reaches_the_other_device() {
        let mut cloud = Cloud::new();
        let (a, b, id) = two_devices_with_a_document(&mut cloud);

        a.library.save_progress(&id, &progress(4, 100)).unwrap();
        settle(&a, &b);

        assert_eq!(b.document(&id).progress, Some(progress(4, 100)));
    }

    #[test]
    fn on_conflicting_reading_progress_the_newest_last_read_wins_on_both_devices() {
        let mut cloud = Cloud::new();
        let (a, b, id) = two_devices_with_a_document(&mut cloud);

        a.library.save_progress(&id, &progress(1, 100)).unwrap();
        b.library.save_progress(&id, &progress(9, 200)).unwrap();
        settle(&a, &b);
        b.sync();

        for device in [&a, &b] {
            assert_eq!(device.document(&id).progress, Some(progress(9, 200)));
        }
    }

    #[test]
    fn highlights_notes_and_page_notes_added_and_edited_on_two_devices_merge() {
        let mut cloud = Cloud::new();
        let (a, b, id) = two_devices_with_a_document(&mut cloud);
        let shared = highlight(&a, &id, "shared").id;
        settle(&a, &b);

        // Concurrently: edits to two fields of one Highlight, a Highlight and a
        // page Note each.
        a.library
            .set_highlight_color(&id, &shared, Rgb { r: 9, g: 9, b: 9 })
            .unwrap();
        b.library
            .set_highlight_note(&id, &shared, "a note")
            .unwrap();
        let on_a = highlight(&a, &id, "on a").id;
        let on_b = highlight(&b, &id, "on b").id;
        let note_a = a.library.add_page_note(&id, 0, 1.0, 2.0, 1).unwrap().id;
        a.library
            .set_page_note_text(&id, &note_a, "from a")
            .unwrap();
        let note_b = b.library.add_page_note(&id, 1, 3.0, 4.0, 2).unwrap().id;
        b.library
            .set_page_note_text(&id, &note_b, "from b")
            .unwrap();
        settle(&a, &b);
        b.sync();

        let (from_a, from_b) = (
            a.library.markup(&id).unwrap(),
            b.library.markup(&id).unwrap(),
        );
        assert_eq!(from_a, from_b);
        let found = |wanted: &str| {
            from_a
                .highlights
                .iter()
                .find(|h| h.id == wanted)
                .cloned()
                .unwrap()
        };
        assert_eq!(from_a.highlights.len(), 3);
        assert_eq!(found(&shared).color, Rgb { r: 9, g: 9, b: 9 });
        assert_eq!(found(&shared).note.as_deref(), Some("a note"));
        assert_eq!(found(&on_a).quoted_text, "on a");
        assert_eq!(found(&on_b).quoted_text, "on b");
        let texts: Vec<_> = from_a.page_notes.iter().map(|n| n.text.as_str()).collect();
        assert_eq!(texts, ["from a", "from b"]);
    }

    #[test]
    fn concurrent_typing_in_one_note_keeps_both_edits() {
        let mut cloud = Cloud::new();
        let (a, b, id) = two_devices_with_a_document(&mut cloud);
        let shared = highlight(&a, &id, "shared").id;
        a.library.set_highlight_note(&id, &shared, "ab").unwrap();
        settle(&a, &b);

        a.library.set_highlight_note(&id, &shared, "aXb").unwrap();
        b.library.set_highlight_note(&id, &shared, "abY").unwrap();
        settle(&a, &b);
        b.sync();

        for device in [&a, &b] {
            let note = device.library.markup(&id).unwrap().highlights[0]
                .note
                .clone();
            assert_eq!(note.as_deref(), Some("aXbY"));
        }
    }

    #[test]
    fn the_same_file_imported_on_two_devices_apart_shows_the_markup_of_both() {
        let mut cloud = Cloud::new();
        let (a, b) = (cloud.device(), cloud.device());
        let id = a.import("on-a.pdf", b"shared").id;
        b.import("on-b.pdf", b"shared");
        highlight(&a, &id, "on a");
        highlight(&b, &id, "on b");

        settle(&a, &b);
        b.sync();

        for device in [&a, &b] {
            assert_eq!(device.ids(), std::slice::from_ref(&id));
            let markup = device.library.markup(&id).unwrap();
            let mut quoted: Vec<_> = markup
                .highlights
                .iter()
                .map(|h| h.quoted_text.as_str())
                .collect();
            quoted.sort_unstable();
            assert_eq!(quoted, ["on a", "on b"]);
        }
    }

    #[test]
    fn custom_colors_added_on_two_devices_both_survive_and_the_default_syncs() {
        let mut cloud = Cloud::new();
        let (a, b) = (cloud.device(), cloud.device());
        let red = a
            .library
            .add_custom_color(Rgb { r: 200, g: 0, b: 0 }, 1)
            .unwrap();
        let blue = b
            .library
            .add_custom_color(Rgb { r: 0, g: 0, b: 200 }, 2)
            .unwrap();
        a.library.set_default_highlight_color(&red.id).unwrap();

        settle(&a, &b);
        b.sync();

        for device in [&a, &b] {
            let custom: Vec<_> = device
                .library
                .highlight_colors()
                .into_iter()
                .filter(|c| c.is_custom)
                .collect();
            assert_eq!(custom, [red.clone(), blue.clone()]);
            assert_eq!(device.library.default_highlight_color(), red);
        }
    }

    #[test]
    fn removing_a_custom_color_wins_over_its_concurrent_use_as_the_default() {
        let mut cloud = Cloud::new();
        let (a, b) = (cloud.device(), cloud.device());
        let red = a
            .library
            .add_custom_color(Rgb { r: 200, g: 0, b: 0 }, 1)
            .unwrap();
        settle(&a, &b);

        a.library.remove_custom_color(&red.id).unwrap();
        b.library.set_default_highlight_color(&red.id).unwrap();
        settle(&a, &b);
        b.sync();

        for device in [&a, &b] {
            assert!(
                device
                    .library
                    .highlight_colors()
                    .iter()
                    .all(|c| !c.is_custom)
            );
            assert_eq!(device.library.default_highlight_color().id, "Yellow");
        }
    }

    #[test]
    fn the_markup_of_a_document_that_changed_through_a_sync_is_reported_once() {
        let mut cloud = Cloud::new();
        let (a, b, id) = two_devices_with_a_document(&mut cloud);
        let other = a.import("b.pdf", b"other document").id;
        settle(&a, &b);
        assert!(b.library.take_markup_changes().is_empty());

        highlight(&a, &id, "new");
        a.library.save_progress(&other, &progress(2, 5)).unwrap();
        settle(&a, &b);
        b.sync();

        assert_eq!(b.library.take_markup_changes(), [id]);
        assert!(b.library.take_markup_changes().is_empty());
    }

    #[test]
    fn incoming_reading_progress_counts_as_a_change_of_the_documents() {
        let mut cloud = Cloud::new();
        let (a, b, id) = two_devices_with_a_document(&mut cloud);
        let before = b.library.sync_changes();

        a.library.save_progress(&id, &progress(2, 5)).unwrap();
        settle(&a, &b);

        assert!(b.library.sync_changes() > before);
    }

    #[test]
    fn the_progress_of_documents_not_downloaded_yet_decides_the_download_order() {
        let mut cloud = Cloud::new();
        let (a, b) = (cloud.device(), cloud.device());
        let first = a.import("1.pdf", b"first");
        let second = a.import("2.pdf", b"second");
        let third = a.import("3.pdf", b"third");
        a.library
            .save_progress(&first.id, &progress(0, 300))
            .unwrap();
        a.library
            .save_progress(&second.id, &progress(0, 100))
            .unwrap();
        a.library
            .save_progress(&third.id, &progress(0, 200))
            .unwrap();
        a.sync();

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
                let files = [&first, &third, &second];
                files.iter().position(|d| name.contains(&d.id))
            })
            .collect();
        assert_eq!(downloads, [0, 1, 2]);
        assert_eq!(b.document(&first.id).progress, Some(progress(0, 300)));
    }

    #[test]
    fn a_step_after_markup_has_synced_reads_nothing() {
        let mut cloud = Cloud::new();
        let (a, b, id) = two_devices_with_a_document(&mut cloud);
        highlight(&a, &id, "x");
        a.library
            .add_custom_color(Rgb { r: 1, g: 1, b: 1 }, 1)
            .unwrap();
        settle(&a, &b);
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
    fn markup_and_colors_made_while_disconnected_sync_after_a_restart_too() {
        let mut cloud = Cloud::new();
        let (a, b, id) = two_devices_with_a_document(&mut cloud);
        highlight(&a, &id, "unsent");
        a.library
            .add_custom_color(Rgb { r: 1, g: 1, b: 1 }, 1)
            .unwrap();
        let root = a.home.join("library");
        drop(a);

        let library = Library::open(&root).unwrap();
        library.sync(&cloud.storage()).unwrap();
        b.sync();

        assert_eq!(b.library.markup(&id).unwrap().highlights.len(), 1);
        assert_eq!(b.library.highlight_colors().len(), 7);
    }

    #[test]
    fn a_remove_still_beats_markup_edits_made_elsewhere() {
        let mut cloud = Cloud::new();
        let (a, b, id) = two_devices_with_a_document(&mut cloud);

        a.library.remove(&id).unwrap();
        highlight(&b, &id, "late");
        settle(&a, &b);
        b.sync();

        assert!(a.ids().is_empty() && b.ids().is_empty());
    }

    #[test]
    fn a_remove_deletes_the_document_and_its_file_on_the_other_device_and_in_the_cloud() {
        let mut cloud = Cloud::new();
        let (a, b, id) = two_devices_with_a_document(&mut cloud);
        assert_eq!(cloud.blobs_with(b"shared document").len(), 1);

        a.library.remove(&id).unwrap();
        settle(&a, &b);

        assert!(a.ids().is_empty() && b.ids().is_empty());
        assert!(!b.home.join("library").join(&id).exists());
        assert!(cloud.blobs_with(b"shared document").is_empty());
    }

    #[test]
    fn each_device_deletes_its_own_chunks_of_a_removed_document() {
        let mut cloud = Cloud::new();
        let (a, b, id) = two_devices_with_a_document(&mut cloud);
        highlight(&a, &id, "on a");
        highlight(&b, &id, "on b");
        settle(&a, &b);
        b.sync();
        assert!(!cloud.storage().list(STATE_DIR).unwrap().is_empty());

        a.library.remove(&id).unwrap();
        settle(&a, &b);
        b.sync();

        assert!(cloud.storage().list(STATE_DIR).unwrap().is_empty());
    }

    #[test]
    fn a_remove_does_not_delete_the_file_of_a_document_imported_again_elsewhere() {
        let mut cloud = Cloud::new();
        let (a, b, id) = two_devices_with_a_document(&mut cloud);
        b.library.remove(&id).unwrap();
        b.import("again.pdf", b"shared document");
        b.sync();

        // A removes what it knows of, not the new Import.
        a.library.remove(&id).unwrap();
        a.sync();
        b.sync();
        a.sync();

        assert_eq!(cloud.blobs_with(b"shared document").len(), 1);
        assert_eq!(a.ids(), std::slice::from_ref(&id));
        assert_eq!(b.ids(), [id]);
    }

    #[test]
    fn a_reimport_racing_a_remove_ends_with_the_file_in_the_cloud() {
        let mut cloud = Cloud::new();
        let (a, b, id) = two_devices_with_a_document(&mut cloud);
        highlight(&a, &id, "old");
        settle(&a, &b);

        // A's Remove deletes the File before B's Re-Import got there.
        a.library.remove(&id).unwrap();
        a.sync();
        assert!(cloud.blobs_with(b"shared document").is_empty());
        b.library.remove(&id).unwrap();
        b.import("again.pdf", b"shared document");
        b.sync();
        a.sync();

        assert_eq!(cloud.blobs_with(b"shared document").len(), 1);
        for device in [&a, &b] {
            assert_eq!(device.ids(), std::slice::from_ref(&id));
            assert!(device.library.markup(&id).unwrap().highlights.is_empty());
        }
    }

    #[test]
    fn a_remove_made_while_disconnected_reaches_the_cloud_when_connecting_again() {
        let mut cloud = Cloud::new();
        let (a, b, id) = two_devices_with_a_document(&mut cloud);
        let other = b.import("other.pdf", b"other document").id;

        // A is Disconnected: it syncs nothing while it Removes.
        a.library.remove(&id).unwrap();
        b.sync();
        assert_eq!(b.ids().len(), 2);
        a.sync();
        b.sync();

        assert_eq!(a.ids(), std::slice::from_ref(&other));
        assert_eq!(b.ids(), [other]);
        assert!(cloud.blobs_with(b"shared document").is_empty());
        assert!(!a.home.join("library").join(&id).exists());
    }

    #[test]
    fn a_reimport_after_a_remove_starts_without_the_old_markup() {
        let mut cloud = Cloud::new();
        let (a, b, id) = two_devices_with_a_document(&mut cloud);
        highlight(&a, &id, "old");
        a.library.save_progress(&id, &progress(3, 9)).unwrap();
        settle(&a, &b);
        b.sync();

        b.library.remove(&id).unwrap();
        b.import("again.pdf", b"shared document");
        settle(&a, &b);
        b.sync();
        a.sync();

        for device in [&a, &b] {
            assert!(device.library.markup(&id).unwrap().highlights.is_empty());
            assert_eq!(device.document(&id).progress, None);
        }
    }

    #[test]
    fn importing_a_file_whose_state_arrived_before_its_download_still_imports() {
        let mut cloud = Cloud::new();
        let b = cloud.device();
        let id = format!("{:x}", Sha256::digest(b"shared document"));
        // What a sync leaves when it got the state of a Document, not its File.
        let state_only = b.home.join("library").join(&id);
        fs::create_dir_all(&state_only).unwrap();
        fs::write(state_only.join(".state-left.automerge"), b"x").unwrap();

        let document = b.import("again.pdf", b"shared document");

        assert_eq!(fs::read(&document.path).unwrap(), b"shared document");
    }
}
