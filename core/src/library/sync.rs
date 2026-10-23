//! Sync: exchanging the Library, the states, the Preferences and the Files with
//! a Cloud Provider's storage (ADR-0009, ADR-0014, ADR-0015, ADR-0016,
//! ADR-0017).
//!
//! The remote layout, versioned so it can change later:
//!
//! Everything is in the one directory `v1`, so one listing tells what is new:
//!
//! - `library.<device>-<number>`: chunks of the Library document, see
//!   `chunks`.
//! - `state.<import>.<device>-<number>`: chunks of the state of each Import
//!   (Markup).
//! - `progress.<import>.<device>-<last read>`: a Device's latest Reading
//!   Progress of a Document, under its first Import (ADR-0020). Each Device
//!   keeps one per Document, replacing it when it saves a newer one.
//! - `preferences.<device>-<number>`: chunks of the Preferences.
//! - `file.<sha256>`: each File once, whichever Device uploaded it first.
//!
//! A Document is listed only once its File is stored here, so a Sync that
//! learns of a Document lists it when its File has arrived. Its state may
//! arrive first, into a folder without a File: that tells the order the Files
//! download in.

use super::*;
use crate::chunks::{self, Outgoing};
use crate::storage::{Blob, Storage, get_bytes, ignore_not_found};

const REMOTE_DIR: &str = "v1";
const LIBRARY_PREFIX: &str = "library.";
const STATE_PREFIX: &str = "state.";
const PREFERENCES_PREFIX: &str = "preferences.";
const PROGRESS_PREFIX: &str = "progress.";
const FILE_PREFIX: &str = "file.";
/// What `Exchanges` calls the Library document, as `PREFERENCES_KEY` does for
/// the Preferences.
const LIBRARY_KEY: &str = "library";

/// The File transfers of one step, counted in Documents.
struct Transfers<'a> {
    total: usize,
    done: usize,
    report: &'a dyn Fn(usize, usize),
}

impl<'a> Transfers<'a> {
    fn new(total: usize, report: &'a dyn Fn(usize, usize)) -> Self {
        Self {
            total,
            done: 0,
            report,
        }
    }

    /// Reports the start, if there is anything to transfer.
    fn start(&self) {
        if self.total > 0 {
            (self.report)(0, self.total);
        }
    }

    fn done(&mut self) {
        self.done += 1;
        (self.report)(self.done, self.total);
    }
}

/// What this Device knows of the exchange stored in the cursor file `path`.
fn read_cursor(path: &Path) -> Cursor {
    Cursor::decode(&fs::read_to_string(path).unwrap_or_default())
}

impl Exchanges {
    /// The cursor of the document `key`, read from `path` when first needed.
    fn cursor(&mut self, key: &str, path: &Path) -> &mut Cursor {
        self.docs
            .entry(key.to_owned())
            .or_insert_with(|| read_cursor(path))
    }
}

/// One synced Automerge document that is stored in a file.
struct Target {
    /// Its key in `Exchanges` and `Dirty`.
    key: String,
    /// The schema version this app knows of it.
    schema: u64,
    /// What its chunks' names start with.
    prefix: String,
    path: PathBuf,
    cursor_path: PathBuf,
}

/// What a step sends once every document it merged is known to be understood:
/// nothing is written to the storage before, so a Device that finds a newer
/// schema version leaves it as it is.
#[derive(Default)]
struct Pending {
    /// This Device's new chunks.
    sends: Vec<Outbound>,
    /// Blobs to delete.
    deletions: Vec<String>,
}

/// This Device's changes to one document, to be written.
struct Outbound {
    /// The document's key in `Exchanges` and `Dirty`.
    key: String,
    cursor_path: PathBuf,
    outgoing: Outgoing,
}

/// A Device's Reading Progress of an Import, as the remote directory lists it.
struct RemoteProgress<'a> {
    name: &'a str,
    import: &'a str,
    device: &'a str,
    last_read: u64,
}

impl<'a> RemoteProgress<'a> {
    fn of(blob: &'a Blob) -> Option<Self> {
        let (import, rest) = blob.name.strip_prefix(PROGRESS_PREFIX)?.split_once('.')?;
        let (device, last_read) = rest.rsplit_once('-')?;
        Some(Self {
            name: &blob.name,
            import,
            device,
            last_read: last_read.parse().ok()?,
        })
    }
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
    /// of Removed Imports. A Device that has many chunks of a document replaces
    /// its own with a snapshot, see `chunks`.
    ///
    /// A step with nothing new costs one listing and loads no document. A File whose bytes don't match its hash is not stored. The
    /// Library is tied to no storage: it sends everything to one that lacks it.
    ///
    /// Three failures are not being offline, see `sync_loop::Status`: rejected
    /// credentials are `PermissionDenied`, a storage without space is
    /// `StorageFull`, and a document of a newer schema version than this app
    /// knows is `Unsupported`. The latter is found before anything is written
    /// to the storage, and nothing of that document is merged.
    pub fn sync(&self, storage: &dyn Storage) -> io::Result<()> {
        self.sync_reporting(storage, &|_, _| {})
    }

    /// `sync`, telling `on_transfer` how many Documents' Files have been
    /// uploaded or downloaded of how many this step transfers: `(0, total)`
    /// first, then after each File, ending at `(total, total)`. Never called
    /// for a step that transfers no File. A step that fails stops short.
    pub fn sync_reporting(
        &self,
        storage: &dyn Storage,
        on_transfer: &dyn Fn(usize, usize),
    ) -> io::Result<()> {
        let mut exchanges = self
            .exchanges
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        let everything = std::mem::take(&mut self.dirty().everything);
        let mut pending = Pending::default();
        let result = storage.list(REMOTE_DIR).and_then(|listing| {
            self.merge_documents(storage, &listing, &mut exchanges, everything, &mut pending)?;
            self.send(storage, &mut exchanges, &mut pending)?;
            self.exchange_progress(storage, &listing)?;
            Ok(listing)
        });
        if result.is_err() {
            self.dirty().everything |= everything;
            // What wasn't sent is found again by the next step.
            for send in &pending.sends {
                self.mark_dirty(&send.key);
            }
        }
        let remote_files: HashSet<String> = result?
            .into_iter()
            .filter_map(|blob| Some(blob.name.strip_prefix(FILE_PREFIX)?.to_owned()))
            .collect();
        self.delete_removed_files(storage, &remote_files)?;
        let uploads = self.files_to_upload(&remote_files)?;
        let downloads = self.files_to_download(&remote_files)?;
        let mut transfers = Transfers::new(uploads.len() + downloads.len(), on_transfer);
        transfers.start();
        self.upload_files(storage, uploads, &mut transfers)?;
        self.download_files(storage, downloads, &mut transfers)
    }

    fn dirty(&self) -> MutexGuard<'_, Dirty> {
        self.dirty.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Merges the other Devices' chunks of the Library document, the
    /// Preferences and the states, found in `listing` of the remote directory,
    /// and collects what to send in `pending`. Fails with `Unsupported` if one has a newer schema version than this app
    /// knows.
    fn merge_documents(
        &self,
        storage: &dyn Storage,
        listing: &[Blob],
        exchanges: &mut Exchanges,
        everything: bool,
        pending: &mut Pending,
    ) -> io::Result<()> {
        if self.exchange_library(storage, listing, exchanges, pending)? {
            // Removes and names of other Devices.
            self.sync_changes.fetch_add(1, Relaxed);
            self.reconcile()?;
        }
        self.exchange_preferences(storage, listing, exchanges, everything, pending)?;
        self.exchange_states(storage, listing, exchanges, everything, pending)
    }

    /// Does what `pending` holds. The cursor of a document is stored after its
    /// chunk is written, so a chunk is never counted as sent that wasn't.
    fn send(
        &self,
        storage: &dyn Storage,
        exchanges: &mut Exchanges,
        pending: &mut Pending,
    ) -> io::Result<()> {
        for name in &pending.deletions {
            storage.delete(name)?;
        }
        let mut sends = std::mem::take(&mut pending.sends).into_iter();
        while let Some(send) = sends.next() {
            let key = send.key.clone();
            if let Err(e) = self.send_chunk(storage, exchanges, send) {
                self.mark_dirty(&key);
                sends.for_each(|send| self.mark_dirty(&send.key));
                return Err(e);
            }
        }
        Ok(())
    }

    fn send_chunk(
        &self,
        storage: &dyn Storage,
        exchanges: &mut Exchanges,
        send: Outbound,
    ) -> io::Result<()> {
        let cursor = exchanges.cursor(&send.key, &send.cursor_path);
        let before = cursor.clone();
        let sent = chunks::push(storage, REMOTE_DIR, cursor, send.outgoing);
        if *cursor != before {
            self.store_cursor(&send.cursor_path, cursor)?;
        }
        sent
    }

    /// Stores `cursor` in the file `path`. Nothing happens if its folder is
    /// gone: the Document was Removed.
    fn store_cursor(&self, path: &Path, cursor: &Cursor) -> io::Result<()> {
        ignore_not_found(write_atomically(
            &self.staging(),
            path,
            cursor.encode().as_bytes(),
        ))
    }

    /// Merges the other Devices' chunks of the Library document and collects
    /// this Device's own for `pending`. True if the Library document changed.
    fn exchange_library(
        &self,
        storage: &dyn Storage,
        listing: &[Blob],
        exchanges: &mut Exchanges,
        pending: &mut Pending,
    ) -> io::Result<bool> {
        let cursor_path = self.root.join(LIBRARY_CURSOR);
        let cursor = exchanges.cursor(LIBRARY_KEY, &cursor_path);
        let before = cursor.clone();
        let pulled = chunks::pull(
            storage,
            REMOTE_DIR,
            listing,
            LIBRARY_PREFIX,
            &self.device_id(),
            cursor,
        )?;
        let (merged, outgoing) = {
            let mut doc = self.catalog();
            let merged = doc.merge(cursor, &pulled)?;
            if merged && let Err(e) = self.save_catalog(&mut doc) {
                *cursor = before;
                return Err(e);
            }
            (merged, doc.outgoing(cursor, LIBRARY_PREFIX, &pulled))
        };
        // The cursor is stored after the document, so it never counts
        // something as applied that was lost.
        if *cursor != before {
            self.store_cursor(&cursor_path, cursor)?;
        }
        pending.sends.extend(outgoing.map(|outgoing| Outbound {
            key: LIBRARY_KEY.to_owned(),
            cursor_path,
            outgoing,
        }));
        Ok(merged)
    }

    /// Exchanges the Preferences. `everything`: send local changes made before
    /// this Library was opened too.
    fn exchange_preferences(
        &self,
        storage: &dyn Storage,
        listing: &[Blob],
        exchanges: &mut Exchanges,
        everything: bool,
        pending: &mut Pending,
    ) -> io::Result<()> {
        let target = Target {
            key: PREFERENCES_KEY.to_owned(),
            schema: preferences::SCHEMA_VERSION,
            prefix: PREFERENCES_PREFIX.to_owned(),
            path: self.preferences(),
            cursor_path: self.root.join(PREFERENCES_CURSOR),
        };
        // Not `||`: the key is cleared either way.
        let dirty = self.dirty().keys.remove(PREFERENCES_KEY) | everything;
        let cursor = exchanges.cursor(PREFERENCES_KEY, &target.cursor_path);
        let merged = self
            .exchange_doc(storage, &target, listing, cursor, dirty, pending, |bytes| {
                write_atomically(&self.staging(), &target.path, bytes).map(|()| true)
            })
            .inspect_err(|_| self.mark_dirty(PREFERENCES_KEY))?;
        if let Some(Merged { before, after }) = merged
            && preferences::highlight_colors(before.as_deref())
                != preferences::highlight_colors(Some(&after))
        {
            self.sync_changes.fetch_add(1, Relaxed);
        }
        Ok(())
    }

    /// Exchanges the state of every Import the Library document lists.
    /// `everything`: send local changes made before this Library was opened
    /// too.
    fn exchange_states(
        &self,
        storage: &dyn Storage,
        listing: &[Blob],
        exchanges: &mut Exchanges,
        everything: bool,
        pending: &mut Pending,
    ) -> io::Result<()> {
        let mut remote: HashMap<&str, Vec<Blob>> = HashMap::new();
        for blob in listing {
            if let Some((import, _)) = blob
                .name
                .strip_prefix(STATE_PREFIX)
                .and_then(|n| n.split_once('.'))
            {
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
        pending
            .deletions
            .extend(self.own_chunks_of(listing, &removed));
        for (import, hash) in imports {
            let folder = self.root.join(&hash);
            let target = Target {
                key: import.clone(),
                schema: state::SCHEMA_VERSION,
                prefix: format!("{STATE_PREFIX}{import}."),
                path: folder.join(state_name(&import)),
                cursor_path: folder.join(cursor_name(&import)),
            };
            let blobs = remote.get(import.as_str()).map_or(&[][..], Vec::as_slice);
            let dirty = self.dirty().keys.remove(&import) | everything;
            let cursor = exchanges.cursor(&import, &target.cursor_path);
            let merged = self
                .exchange_doc(storage, &target, blobs, cursor, dirty, pending, |bytes| {
                    self.store_state(&folder, &import, &target.path, bytes)
                })
                .inspect_err(|_| self.mark_dirty(&import))?;
            if merged.is_some() {
                self.report_markup_change(&hash);
            }
        }
        Ok(())
    }

    /// Exchanges the Reading Progress of every Document the Library document
    /// lists, `listing` being the blobs of the remote directory: fetches
    /// another Device's if it is newer than the one here, else sends the one
    /// here if it is newer than any there, replacing this Device's older ones.
    fn exchange_progress(&self, storage: &dyn Storage, listing: &[Blob]) -> io::Result<()> {
        let device = self.device_id();
        let mut by_import: HashMap<&str, Vec<RemoteProgress>> = HashMap::new();
        for remote in listing.iter().filter_map(RemoteProgress::of) {
            by_import.entry(remote.import).or_default().push(remote);
        }
        for entry in self.entries() {
            let remote: Vec<&RemoteProgress> = entry
                .imports
                .iter()
                .filter_map(|import| by_import.get(import.as_str()))
                .flatten()
                .collect();
            let newest = remote.iter().max_by_key(|r| (r.last_read, r.device));
            let local = self.progress_of(&entry);
            let mut keep = newest.filter(|r| r.device == device).map(|r| r.name);
            if let Some(newest) = newest
                && Some(newest.last_read) > local.map(|p| p.last_read)
            {
                let name = format!("{REMOTE_DIR}/{}", newest.name);
                let fetched = get_bytes(storage, &name)?.and_then(|b| progress::decode(&b));
                if let Some(fetched) = fetched {
                    self.store_progress(&entry, fetched)?;
                }
            } else if let Some(local) = local
                && newest.is_none_or(|r| local.last_read > r.last_read)
            {
                let name = format!(
                    "{PROGRESS_PREFIX}{}.{device}-{}",
                    entry.imports[0], local.last_read
                );
                storage.put(
                    &format!("{REMOTE_DIR}/{name}"),
                    &mut progress::encode(&local).as_slice(),
                )?;
                keep = None;
            }
            for own in remote.iter().filter(|r| r.device == device) {
                if keep != Some(own.name) {
                    storage.delete(&format!("{REMOTE_DIR}/{}", own.name))?;
                }
            }
        }
        Ok(())
    }

    /// Stores `progress`, fetched from another Device, as the Reading Progress
    /// of the Document of `entry`, unless it was Removed or a newer one was
    /// saved meanwhile.
    fn store_progress(&self, entry: &Entry, progress: ReadingProgress) -> io::Result<()> {
        let _writing = self.writing();
        let saved = self.progress_of(entry);
        if saved.is_some_and(|s| s.last_read >= progress.last_read) {
            return Ok(());
        }
        let doc = self.catalog();
        if doc.live(&entry.id).next().is_none() {
            return Ok(());
        }
        // The File may not be here yet.
        fs::create_dir_all(self.root.join(&entry.id))?;
        self.write_progress(entry, &progress)?;
        self.sync_changes.fetch_add(1, Relaxed);
        Ok(())
    }

    /// The names of this Device's chunks and Reading Progress among `listing`,
    /// the blobs of the remote directory, of the Imports `removed`. Other
    /// Devices delete theirs.
    fn own_chunks_of<'a>(
        &'a self,
        listing: &'a [Blob],
        removed: &'a HashSet<String>,
    ) -> impl Iterator<Item = String> + 'a {
        let device = self.device_id();
        listing.iter().filter_map(move |blob| {
            let (import, chunk) = (blob.name.strip_prefix(STATE_PREFIX))
                .or_else(|| blob.name.strip_prefix(PROGRESS_PREFIX))?
                .split_once('.')?;
            let own = chunk.rsplit_once('-')?.0 == device;
            (own && removed.contains(import)).then(|| format!("{REMOTE_DIR}/{}", blob.name))
        })
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
            storage.delete(&format!("{REMOTE_DIR}/{FILE_PREFIX}{hash}"))?;
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

    /// Reports that a merge changed the state of Document `hash`, which holds
    /// little but its Markup, without reading what changed.
    fn report_markup_change(&self, hash: &str) {
        let mut changed = self
            .markup_changes
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        if !changed.iter().any(|id| id == hash) {
            changed.push(hash.to_owned());
        }
    }

    /// Exchanges the document `target` with `storage`, `blobs` being the
    /// listing of its directory: merges other Devices' new chunks into it and
    /// collects this Device's own changes for `pending`. Loads the document
    /// only if there is something to do: `dirty`, new chunks or chunks the
    /// storage lost. `store` writes merged bytes and tells whether it did (the
    /// document may be gone). Returns what a merge changed. Fails with
    /// `Unsupported`, storing nothing, if the document has a newer schema
    /// version than this app knows.
    #[allow(clippy::too_many_arguments)]
    fn exchange_doc(
        &self,
        storage: &dyn Storage,
        target: &Target,
        blobs: &[Blob],
        cursor: &mut Cursor,
        dirty: bool,
        pending: &mut Pending,
        store: impl FnOnce(&[u8]) -> io::Result<bool>,
    ) -> io::Result<Option<Merged>> {
        let before = cursor.clone();
        let device = self.device_id();
        let pulled = chunks::pull(storage, REMOTE_DIR, blobs, &target.prefix, &device, cursor)?;
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
            let changed = cursor.apply(&mut doc, &pulled);
            if let Err(e) = state::check_schema(&doc, target.schema) {
                *cursor = before;
                return Err(e);
            }
            if changed {
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
            (merged, cursor.outgoing(&mut doc, &target.prefix, &pulled))
        };
        // The cursor is stored after the document, so it never counts
        // something as applied that was lost.
        if *cursor != before {
            self.store_cursor(&target.cursor_path, cursor)?;
        }
        pending.sends.extend(outgoing.map(|outgoing| Outbound {
            key: target.key.clone(),
            cursor_path: target.cursor_path.clone(),
            outgoing,
        }));
        Ok(merged)
    }

    /// The listed Documents whose stored File isn't among `remote`, with its path.
    fn files_to_upload(&self, remote: &HashSet<String>) -> io::Result<Vec<(String, PathBuf)>> {
        let mut found = Vec::new();
        for entry in self.entries().iter().filter(|e| !remote.contains(&e.id)) {
            if let Some(path) = self.file_path(entry)? {
                found.push((entry.id.clone(), path));
            }
        }
        Ok(found)
    }

    fn upload_files(
        &self,
        storage: &dyn Storage,
        files: Vec<(String, PathBuf)>,
        transfers: &mut Transfers,
    ) -> io::Result<()> {
        for (id, path) in files {
            match File::open(path) {
                // Removed meanwhile.
                Err(e) if e.kind() == io::ErrorKind::NotFound => {}
                file => storage.put(&format!("{REMOTE_DIR}/{FILE_PREFIX}{id}"), &mut file?)?,
            }
            transfers.done();
        }
        Ok(())
    }

    /// The listed Documents that are among `remote` and not stored here, those
    /// Read last first, then those Imported last first.
    fn files_to_download(&self, remote: &HashSet<String>) -> io::Result<Vec<Entry>> {
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
        Ok(missing.into_iter().map(|(_, entry)| entry).collect())
    }

    fn download_files(
        &self,
        storage: &dyn Storage,
        entries: Vec<Entry>,
        transfers: &mut Transfers,
    ) -> io::Result<()> {
        for entry in entries {
            self.download_file(storage, &entry)?;
            transfers.done();
        }
        Ok(())
    }

    /// When the Document of `entry` was last read, if ever.
    fn last_read(&self, entry: &Entry) -> Option<u64> {
        self.progress_of(entry).map(|p| p.last_read)
    }

    /// Downloads the File of `entry` into its folder, unless the Document was
    /// Removed or got its File meanwhile.
    fn download_file(&self, storage: &dyn Storage, entry: &Entry) -> io::Result<()> {
        let Some(mut data) = storage.get(&format!("{REMOTE_DIR}/{FILE_PREFIX}{}", entry.id))?
        else {
            return Ok(());
        };
        let staged = self.staging().join(unique_name());
        fs::create_dir(&staged)?;
        let result = stream_hashed(&mut data, &staged.join(&entry.name), 0, |_, _| {})
            .and_then(|hash| self.install(&staged, entry, &hash));
        // Nothing left to remove after a successful rename.
        let _ = fs::remove_dir_all(&staged);
        if result? {
            // Details are never synced: an EPUB's are read here, as at Import. A
            // File that isn't a readable EPUB has none, and reads as a PDF.
            let file = self.root.join(&entry.id).join(&entry.name);
            let details = match format_of(&file) {
                Ok(Some(Format::Epub)) => read_epub_details(&file).ok(),
                _ => None,
            };
            let stored = details.map_or(Ok(()), |d| self.set_details(&entry.id, &d));
            // After the details, so a caller that sees the change finds them.
            self.sync_changes.fetch_add(1, Relaxed);
            stored?;
        }
        Ok(())
    }

    /// Moves the downloaded File in `staged` into the Document folder of
    /// `entry`, if its bytes are those of the Document, the Library document
    /// still lists it and its File isn't there already. Whether it did.
    fn install(&self, staged: &Path, entry: &Entry, hash: &str) -> io::Result<bool> {
        let doc = self.catalog();
        let folder = self.root.join(&entry.id);
        if hash != entry.id || doc.live(&entry.id).next().is_none() {
            return Ok(false);
        }
        if !folder.exists() {
            fs::rename(staged, folder)?;
        } else if self.file_path(entry)?.is_none() {
            // The folder may hold a state already.
            fs::rename(staged.join(&entry.name), folder.join(&entry.name))?;
        } else {
            return Ok(false);
        }
        Ok(true)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::markup::{Anchor, EpubPosition, Highlight, PageRects, Rgb};
    use crate::storage::DirStorage;
    use automerge::transaction::Transactable;
    use std::sync::atomic::{AtomicU32, AtomicUsize};
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
                "leaf-sync-{}-{}",
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

    /// The bytes of a File that is a PDF with `content`.
    fn pdf(content: &[u8]) -> Vec<u8> {
        [b"%PDF-", content].concat()
    }

    struct Device {
        library: Library,
        home: PathBuf,
        storage: DirStorage,
    }

    impl Device {
        /// Imports a File with `bytes`; as a PDF's content (see `pdf`) if it is named `.pdf`.
        fn import(&self, name: &str, bytes: &[u8]) -> Document {
            let source = self.home.join(name);
            let bytes = if name.ends_with(".pdf") {
                pdf(bytes)
            } else {
                bytes.to_vec()
            };
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

        /// A step, and the File transfers it reported: Documents done of total.
        fn sync_reporting(&self) -> Vec<(usize, usize)> {
            let reports = Mutex::new(Vec::new());
            self.library
                .sync_reporting(&self.storage, &|done, total| {
                    reports.lock().unwrap().push((done, total))
                })
                .unwrap();
            reports.into_inner().unwrap()
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

    /// Wraps a storage and records the names of the blobs read and the number of
    /// listings.
    struct Recording {
        inner: DirStorage,
        gets: Mutex<Vec<String>>,
        lists: AtomicUsize,
    }

    impl Recording {
        fn new(inner: DirStorage) -> Self {
            Self {
                inner,
                gets: Mutex::new(Vec::new()),
                lists: AtomicUsize::new(0),
            }
        }
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
            self.lists.fetch_add(1, Relaxed);
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
        assert_eq!(fs::read(&document.path).unwrap(), pdf(b"paper bytes"));
        assert_eq!(document.path.file_name().unwrap(), "Paper.pdf");
        assert!(document.progress.is_none());
    }

    #[test]
    fn details_stay_on_their_device() {
        let mut cloud = Cloud::new();
        let (a, b) = (cloud.device(), cloud.device());
        let imported = a.import("Paper.pdf", b"paper bytes");
        let details = crate::details::Details {
            title: Some("Paper".to_owned()),
            author: None,
            size: crate::details::Size::Pages(1),
        };
        a.library.set_details(&imported.id, &details).unwrap();

        a.sync();
        b.sync();

        assert_eq!(b.document(&imported.id).details, None);
        assert_eq!(a.document(&imported.id).details, Some(details));
    }

    #[test]
    fn an_epub_reaches_another_device_as_an_epub_with_its_details() {
        let mut cloud = Cloud::new();
        let (a, b) = (cloud.device(), cloud.device());
        let book = crate::epub::fixtures::Book::new("<dc:title>Emma</dc:title>").bytes();
        let imported = a.import("Emma.epub", &book);

        a.sync();
        b.sync();

        let downloaded = b.document(&imported.id);
        assert_eq!(downloaded.format(), crate::details::Format::Epub);
        assert_eq!(downloaded.title(), "Emma");
        assert_eq!(fs::read(&downloaded.path).unwrap(), book);
    }

    #[test]
    fn uploads_and_downloads_report_documents_done_of_total_ending_at_total() {
        let mut cloud = Cloud::new();
        let (a, b) = (cloud.device(), cloud.device());
        for name in ["1", "2", "3"] {
            a.import(&format!("{name}.pdf"), name.as_bytes());
        }
        let expected = vec![(0, 3), (1, 3), (2, 3), (3, 3)];

        assert_eq!(a.sync_reporting(), expected, "uploads");
        assert_eq!(b.sync_reporting(), expected, "downloads");
    }

    #[test]
    fn a_step_without_file_transfers_reports_none() {
        let mut cloud = Cloud::new();
        let (a, b) = (cloud.device(), cloud.device());
        let imported = a.import("a.pdf", b"on a");
        a.sync();
        b.sync();
        a.library
            .add_highlight(
                &imported.id,
                Anchor::Pdf(vec![]),
                "quoted",
                Rgb { r: 1, g: 2, b: 3 },
                1,
            )
            .unwrap()
            .unwrap();

        assert_eq!(a.sync_reporting(), []);
        assert_eq!(b.sync_reporting(), []);
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
            let read = |id: &str| fs::read(&device.document(id).path).unwrap();
            assert_eq!(read(&on_a.id), pdf(b"on a"));
            assert_eq!(read(&on_b.id), pdf(b"on b"));
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
            let progress = ReadingProgress::pdf(1, 0.0, 0.0, last_read);
            b.library.save_progress(&document.id, &progress).unwrap();
        }
        b.sync();
        // The Files get lost on this Device, the Library keeps listing them.
        for document in [&old, &read_early, &read_late, &newest] {
            fs::remove_file(&document.path).unwrap();
        }

        let recording = Recording::new(cloud.storage());
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
            pdf(b"shared")
        );
    }

    #[test]
    fn a_file_the_library_lists_but_the_cloud_lacks_is_uploaded_again() {
        let mut cloud = Cloud::new();
        let (a, b) = (cloud.device(), cloud.device());
        a.import("a.pdf", b"precious");
        a.sync();
        let blobs = cloud.blobs_with(&pdf(b"precious"));
        assert_eq!(blobs.len(), 1);
        fs::remove_file(&blobs[0]).unwrap();

        a.sync();
        b.sync();

        assert_eq!(cloud.blobs_with(&pdf(b"precious")).len(), 1);
        assert_eq!(b.ids().len(), 1);
    }

    #[test]
    fn another_device_that_has_the_file_uploads_it_when_the_cloud_lacks_it() {
        let mut cloud = Cloud::new();
        let (a, b, c) = (cloud.device(), cloud.device(), cloud.device());
        let document = a.import("a.pdf", b"precious");
        a.sync();
        b.sync();
        fs::remove_file(&cloud.blobs_with(&pdf(b"precious"))[0]).unwrap();
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

        let recording = Recording::new(cloud.storage());
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
        let recording = Recording::new(cloud.storage());
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
        let blob = cloud.blobs_with(&pdf(b"genuine")).remove(0);
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
        let progress = ReadingProgress::pdf(3, 1.0, 2.0, 5);
        a.library.save_progress(&document.id, &progress).unwrap();
        a.sync();
        fs::remove_file(&document.path).unwrap();
        assert!(a.ids().is_empty());

        a.sync();

        assert_eq!(a.document(&document.id).progress, Some(progress));
    }

    fn progress(page_index: u32, last_read: u64) -> ReadingProgress {
        ReadingProgress::pdf(page_index, 0.0, 0.0, last_read)
    }

    fn highlight_value(id: &str) -> Highlight {
        Highlight {
            id: id.to_owned(),
            anchor: Anchor::Pdf(vec![]),
            quoted_text: "quoted".to_owned(),
            color: Rgb { r: 1, g: 2, b: 3 },
            created: 1,
            note: None,
        }
    }

    fn highlight(device: &Device, id: &str, text: &str) -> Highlight {
        let anchor = Anchor::Pdf(vec![PageRects {
            page_index: 0,
            rects: vec![],
        }]);
        let color = Rgb { r: 1, g: 2, b: 3 };
        device
            .library
            .add_highlight(id, anchor, text, color, 1)
            .unwrap()
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
    fn epub_reading_progress_reaches_the_other_device_and_the_newest_last_read_wins() {
        let mut cloud = Cloud::new();
        let (a, b) = (cloud.device(), cloud.device());
        let book = crate::epub::fixtures::Book::new("").chapters(&["<p>a</p>", "<p>b</p>"]);
        let id = a.import("book.epub", &book.bytes()).id;
        a.sync();
        b.sync();

        a.library
            .save_progress(&id, &ReadingProgress::epub(1, 0, 100))
            .unwrap();
        settle(&a, &b);
        assert_eq!(
            b.document(&id).progress,
            Some(ReadingProgress::epub(1, 0, 100))
        );
        assert_eq!(b.document(&id).percent_read(), Some(50));

        b.library
            .save_progress(&id, &ReadingProgress::epub(0, 1, 50))
            .unwrap();
        a.library
            .save_progress(&id, &ReadingProgress::epub(1, 1, 200))
            .unwrap();
        settle(&a, &b);
        b.sync();

        for device in [&a, &b] {
            let document = device.document(&id);
            assert_eq!(document.progress, Some(ReadingProgress::epub(1, 1, 200)));
            assert_eq!(document.percent_read(), Some(100));
        }
    }

    fn pdf_spot(page_index: u32, x: f64, y: f64) -> Place {
        Place::Pdf { page_index, x, y }
    }

    #[test]
    fn epub_page_notes_reach_the_other_device_and_removing_one_removes_it_there() {
        let mut cloud = Cloud::new();
        let (a, b) = (cloud.device(), cloud.device());
        let book = crate::epub::fixtures::Book::new("").chapters(&["<p>a</p>", "<p>b</p>"]);
        let id = a.import("book.epub", &book.bytes()).id;
        a.sync();
        b.sync();
        let spot = Place::Epub {
            spine_index: 1,
            offset: 1,
        };

        let kept = a.library.add_page_note(&id, spot, 1).unwrap().unwrap();
        a.library.set_page_note_text(&id, &kept.id, "kept").unwrap();
        let gone = a.library.add_page_note(&id, spot, 2).unwrap().unwrap();
        a.library.set_page_note_text(&id, &gone.id, "gone").unwrap();
        settle(&a, &b);
        let on_b = b.library.markup(&id).unwrap().page_notes;
        assert_eq!(on_b.len(), 2);
        assert_eq!(on_b[0].place, spot);
        assert_eq!(on_b[0].text, "kept");

        b.library.remove_page_note(&id, &gone.id).unwrap();
        settle(&b, &a);

        for device in [&a, &b] {
            let notes = device.library.markup(&id).unwrap().page_notes;
            assert_eq!(notes.len(), 1);
            assert_eq!(notes[0].id, kept.id);
        }
    }

    #[test]
    fn epub_highlights_and_their_notes_reach_the_other_device() {
        let mut cloud = Cloud::new();
        let (a, b) = (cloud.device(), cloud.device());
        let book = crate::epub::fixtures::Book::new("").chapters(&["<p>a</p>", "<p>b</p>"]);
        let id = a.import("book.epub", &book.bytes()).id;
        a.sync();
        b.sync();
        let position = |spine_index, offset| EpubPosition {
            spine_index,
            offset,
        };
        let anchor = Anchor::Epub {
            start: position(0, 0),
            end: position(1, 1),
        };

        let added = a
            .library
            .add_highlight(&id, anchor, "a\nb", Rgb { r: 1, g: 2, b: 3 }, 1)
            .unwrap()
            .unwrap();
        settle(&a, &b);
        b.library
            .set_highlight_note(&id, &added.id, "a note")
            .unwrap();
        settle(&b, &a);

        for device in [&a, &b] {
            let highlights = device.library.markup(&id).unwrap().highlights;
            assert_eq!(highlights.len(), 1);
            assert_eq!(highlights[0].anchor, added.anchor);
            assert_eq!(highlights[0].quoted_text, "a\nb");
            assert_eq!(highlights[0].note.as_deref(), Some("a note"));
        }
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
        let note_a = a
            .library
            .add_page_note(&id, pdf_spot(0, 1.0, 2.0), 1)
            .unwrap()
            .unwrap()
            .id;
        a.library
            .set_page_note_text(&id, &note_a, "from a")
            .unwrap();
        let note_b = b
            .library
            .add_page_note(&id, pdf_spot(1, 3.0, 4.0), 2)
            .unwrap()
            .unwrap()
            .id;
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
                .colors
                .into_iter()
                .filter(|c| c.is_custom)
                .collect();
            assert_eq!(custom, [red.clone(), blue.clone()]);
            assert_eq!(device.library.highlight_colors().default_color, red);
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
                    .colors
                    .iter()
                    .all(|c| !c.is_custom)
            );
            assert_eq!(device.library.highlight_colors().default_color.id, "Yellow");
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

        let recording = Recording::new(cloud.storage());
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

    /// The names of the Reading Progress blobs in the cloud.
    fn progress_blobs(cloud: &Cloud) -> Vec<String> {
        let mut blobs = cloud.storage().list(REMOTE_DIR).unwrap();
        blobs.retain(|blob| blob.name.starts_with(PROGRESS_PREFIX));
        blobs.into_iter().map(|blob| blob.name).collect()
    }

    #[test]
    fn a_device_keeps_one_reading_progress_per_document_in_the_cloud_and_no_state() {
        let mut cloud = Cloud::new();
        let (a, b, id) = two_devices_with_a_document(&mut cloud);
        let before = cloud.storage().list(REMOTE_DIR).unwrap().len();

        for n in 1..=20 {
            a.library
                .save_progress(&id, &progress(n, u64::from(n)))
                .unwrap();
            a.sync();
        }
        b.sync();

        assert_eq!(progress_blobs(&cloud).len(), 1);
        assert_eq!(cloud.storage().list(REMOTE_DIR).unwrap().len(), before + 1);
        assert_eq!(b.document(&id).progress, Some(progress(20, 20)));
        // B read it, it sends nothing back.
        b.sync();
        assert_eq!(progress_blobs(&cloud).len(), 1);
    }

    #[test]
    fn a_step_after_reading_progress_has_synced_reads_nothing() {
        let mut cloud = Cloud::new();
        let (a, b, id) = two_devices_with_a_document(&mut cloud);
        a.library.save_progress(&id, &progress(4, 100)).unwrap();
        settle(&a, &b);

        let recording = Recording::new(cloud.storage());
        a.library.sync(&recording).unwrap();
        b.library.sync(&recording).unwrap();

        assert!(recording.gets.lock().unwrap().is_empty());
    }

    #[test]
    fn the_reading_progress_of_a_removed_document_leaves_the_cloud() {
        let mut cloud = Cloud::new();
        let (a, b, id) = two_devices_with_a_document(&mut cloud);
        a.library.save_progress(&id, &progress(4, 100)).unwrap();
        b.library.save_progress(&id, &progress(5, 200)).unwrap();
        settle(&a, &b);

        a.library.remove(&id).unwrap();
        settle(&a, &b);

        assert!(progress_blobs(&cloud).is_empty());
    }

    #[test]
    fn changes_made_before_the_first_step_are_sent_once() {
        let mut cloud = Cloud::new();
        let (a, _b, id) = two_devices_with_a_document(&mut cloud);
        let root = a.home.join("library");
        drop(a);
        let library = Library::open(&root).unwrap();
        library
            .add_highlight(&id, Anchor::Pdf(vec![]), "q", Rgb { r: 1, g: 2, b: 3 }, 1)
            .unwrap();

        library.sync(&cloud.storage()).unwrap();

        assert!(library.dirty().keys.is_empty());
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

        let recording = Recording::new(cloud.storage());
        a.library.sync(&recording).unwrap();
        b.library.sync(&recording).unwrap();

        assert!(recording.gets.lock().unwrap().is_empty());
    }

    #[test]
    fn a_library_from_before_device_ids_sends_its_progress_markup_and_colors() {
        let mut cloud = Cloud::new();
        // Stored the way an older Leaf did: every write by a random actor.
        let home = cloud.dir.join("legacy");
        let root = home.join("library");
        let id = hex::encode(Sha256::digest(b"legacy bytes"));
        fs::create_dir_all(root.join(&id)).unwrap();
        fs::write(root.join(&id).join("Old.pdf"), b"legacy bytes").unwrap();
        let mut state = state::update(None, &ActorId::random(), |doc| {
            progress::put_progress(doc, &progress(3, 100));
        });
        state = state::update(Some(&state), &ActorId::random(), |doc| {
            markup::put_highlight(doc, &highlight_value("h"));
            markup::put_note(doc, "h", "a note");
        });
        fs::write(root.join(&id).join(LEGACY_STATE), state).unwrap();
        let colors = state::update_versioned(
            None,
            &ActorId::random(),
            preferences::SCHEMA_VERSION,
            |doc| {
                preferences::add_custom_color(doc, Rgb { r: 9, g: 9, b: 9 }, 1);
            },
        );
        fs::write(root.join(PREFERENCES), colors).unwrap();
        let a = Device {
            library: Library::open(&root).unwrap(),
            home,
            storage: cloud.storage(),
        };
        let b = cloud.device();

        a.sync();
        b.sync();

        assert_eq!(b.document(&id).progress, Some(progress(3, 100)));
        let highlights = b.library.markup(&id).unwrap().highlights;
        assert_eq!(highlights.len(), 1);
        assert_eq!(highlights[0].note.as_deref(), Some("a note"));
        assert_eq!(b.library.highlight_colors(), a.library.highlight_colors());
        assert_eq!(b.library.highlight_colors().colors.len(), 7);
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
        assert_eq!(b.library.highlight_colors().colors.len(), 7);
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
        assert_eq!(cloud.blobs_with(&pdf(b"shared document")).len(), 1);

        a.library.remove(&id).unwrap();
        settle(&a, &b);

        assert!(a.ids().is_empty() && b.ids().is_empty());
        assert!(!b.home.join("library").join(&id).exists());
        assert!(cloud.blobs_with(&pdf(b"shared document")).is_empty());
    }

    fn state_chunks(cloud: &Cloud) -> Vec<Blob> {
        let mut blobs = cloud.storage().list(REMOTE_DIR).unwrap();
        blobs.retain(|blob| blob.name.starts_with(STATE_PREFIX));
        blobs
    }

    #[test]
    fn each_device_deletes_its_own_chunks_of_a_removed_document() {
        let mut cloud = Cloud::new();
        let (a, b, id) = two_devices_with_a_document(&mut cloud);
        highlight(&a, &id, "on a");
        highlight(&b, &id, "on b");
        settle(&a, &b);
        b.sync();
        assert!(!state_chunks(&cloud).is_empty());

        a.library.remove(&id).unwrap();
        settle(&a, &b);
        b.sync();

        assert!(state_chunks(&cloud).is_empty());
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

        assert_eq!(cloud.blobs_with(&pdf(b"shared document")).len(), 1);
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
        assert!(cloud.blobs_with(&pdf(b"shared document")).is_empty());
        b.library.remove(&id).unwrap();
        b.import("again.pdf", b"shared document");
        b.sync();
        a.sync();

        assert_eq!(cloud.blobs_with(&pdf(b"shared document")).len(), 1);
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
        assert!(cloud.blobs_with(&pdf(b"shared document")).is_empty());
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
        let id = hex::encode(Sha256::digest(pdf(b"shared document")));
        // What a sync leaves when it got the state of a Document, not its File.
        let state_only = b.home.join("library").join(&id);
        fs::create_dir_all(&state_only).unwrap();
        fs::write(state_only.join(".state-left.automerge"), b"x").unwrap();

        let document = b.import("again.pdf", b"shared document");

        assert_eq!(fs::read(&document.path).unwrap(), pdf(b"shared document"));
    }

    /// Everything in the cloud, by path.
    fn cloud_contents(cloud: &Cloud) -> std::collections::BTreeMap<PathBuf, Vec<u8>> {
        let mut found = std::collections::BTreeMap::new();
        let mut todo = vec![cloud.dir.join("cloud")];
        while let Some(dir) = todo.pop() {
            for entry in fs::read_dir(dir).unwrap() {
                let path = entry.unwrap().path();
                if path.is_dir() {
                    todo.push(path);
                } else {
                    found.insert(path.clone(), fs::read(path).unwrap());
                }
            }
        }
        found
    }

    /// Makes another Device store a chunk `name` of a document with schema
    /// version `version`, which this app doesn't know.
    fn plant_schema_version(cloud: &Cloud, name: &str, version: u64) {
        let mut doc = AutoCommit::new().with_actor(ActorId::random());
        doc.put(automerge::ROOT, "version", version).unwrap();
        let bytes: Vec<u8> = doc
            .get_changes(&[])
            .iter()
            .flat_map(|change| change.raw_bytes().to_vec())
            .collect();
        cloud
            .storage()
            .put(&format!("{REMOTE_DIR}/{name}"), &mut bytes.as_slice())
            .unwrap();
    }

    #[test]
    fn a_newer_schema_version_in_any_synced_document_pauses_sync_with_nothing_written() {
        for case in ["library", "preferences", "state"] {
            let mut cloud = Cloud::new();
            let (a, b, id) = two_devices_with_a_document(&mut cloud);
            let import = a.library.import_ids(&id)[0].clone();
            let device = "f".repeat(32);
            let name = match case {
                "library" => format!("{LIBRARY_PREFIX}{device}-1"),
                "preferences" => format!("{PREFERENCES_PREFIX}{device}-1"),
                _ => format!("{STATE_PREFIX}{import}.{device}-1"),
            };
            plant_schema_version(&cloud, &name, 99);
            let before = cloud_contents(&cloud);

            // Local changes in every kind of document, ready to be sent.
            a.import("new.pdf", b"imported after");
            a.library.save_progress(&id, &progress(4, 100)).unwrap();
            a.library
                .set_default_highlight_color(
                    &a.library
                        .add_custom_color(Rgb { r: 1, g: 2, b: 3 }, 1)
                        .unwrap()
                        .id,
                )
                .unwrap();
            let error = a.library.sync(&a.storage).unwrap_err();

            assert_eq!(error.kind(), io::ErrorKind::Unsupported, "{case}");
            assert_eq!(cloud_contents(&cloud), before, "{case}: nothing written");
            assert_eq!(a.ids().len(), 2, "{case}: local state is untouched");
            assert_eq!(b.document(&id).progress, None);

            // Once the newer state is gone, nothing was lost.
            fs::remove_file(cloud.dir.join("cloud").join(REMOTE_DIR).join(&name)).unwrap();
            a.sync();
            b.sync();
            assert_eq!(b.ids().len(), 2, "{case}");
            assert_eq!(b.document(&id).progress, Some(progress(4, 100)), "{case}");
            assert_eq!(b.library.highlight_colors().colors.len(), 7, "{case}");
        }
    }

    #[test]
    fn local_state_of_a_newer_schema_version_is_never_stamped_lower_and_pauses_sync() {
        let mut cloud = Cloud::new();
        let (a, _b, id) = two_devices_with_a_document(&mut cloud);
        highlight(&a, &id, "q");
        let import = a.library.import_ids(&id)[0].clone();
        let path = a.home.join("library").join(&id).join(state_name(&import));
        let mut newer = AutoCommit::load(&fs::read(&path).unwrap()).unwrap();
        newer.put(automerge::ROOT, "version", 99_u64).unwrap();
        fs::write(&path, newer.save()).unwrap();

        a.library
            .add_highlight(&id, Anchor::Pdf(vec![]), "q", Rgb { r: 1, g: 2, b: 3 }, 1)
            .unwrap()
            .unwrap();

        let stored = AutoCommit::load(&fs::read(&path).unwrap()).unwrap();
        assert_eq!(state::version(&stored), 99);
        let before = cloud_contents(&cloud);
        let error = a.library.sync(&a.storage).unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::Unsupported);
        assert_eq!(cloud_contents(&cloud), before);
    }

    /// The names in the cloud of the chunks of `device`.
    fn chunks_of(cloud: &Cloud, device: &Device) -> Vec<String> {
        let id = device.library.device_id();
        let mut blobs = cloud.storage().list(REMOTE_DIR).unwrap();
        blobs.retain(|blob| blob.name.contains(&id) && !blob.name.starts_with(FILE_PREFIX));
        blobs.into_iter().map(|blob| blob.name).collect()
    }

    #[test]
    fn a_devices_chunks_stay_few_and_every_device_still_converges_from_them() {
        let mut cloud = Cloud::new();
        let (a, b, id) = two_devices_with_a_document(&mut cloud);
        let mut most = 0;
        for n in 0..60 {
            a.library
                .save_progress(&id, &progress(n, 100 + u64::from(n)))
                .unwrap();
            if n % 10 == 0 {
                highlight(&a, &id, &format!("passage {n}"));
                a.import(&format!("{n}.pdf"), format!("document {n}").as_bytes());
            }
            a.sync();
            most = most.max(chunks_of(&cloud, &a).len());
            if n % 25 == 0 {
                b.sync();
            }
        }
        // Library, Preferences and one state at most.
        assert!(most <= 3 * chunks::MAX_OWN_CHUNKS, "{most} chunks");
        let fresh = cloud.device();

        b.sync();
        fresh.sync();

        for device in [&b, &fresh] {
            assert_eq!(device.document(&id).progress, Some(progress(59, 159)));
            assert_eq!(device.library.markup(&id).unwrap().highlights.len(), 6);
            assert_eq!(device.ids().len(), 7);
        }
    }

    /// Two Devices with `count` Documents with Reading Progress, in sync, then
    /// a step on each with nothing new: it must do one listing and read no
    /// blob.
    fn assert_idle_steps_are_cheap(count: u32) {
        let mut cloud = Cloud::new();
        let (a, b) = (cloud.device(), cloud.device());
        for n in 0..count {
            let document = a.import(&format!("{n}.pdf"), format!("document {n}").as_bytes());
            let read = progress(n, 1 + u64::from(n));
            a.library.save_progress(&document.id, &read).unwrap();
        }
        a.sync();
        b.sync();
        a.sync();
        assert_eq!(b.ids().len(), count as usize);

        let recording = Recording::new(cloud.storage());
        a.library.sync(&recording).unwrap();
        b.library.sync(&recording).unwrap();

        assert_eq!(recording.lists.load(Relaxed), 2, "one listing per step");
        assert!(recording.gets.lock().unwrap().is_empty());
    }

    #[test]
    fn a_step_with_nothing_new_does_one_listing_and_loads_no_document() {
        assert_idle_steps_are_cheap(20);
    }

    /// Setting up 1000 Documents takes a minute: run with
    /// `cargo test -- --ignored 1000_documents`.
    #[test]
    #[ignore = "takes a minute; run it explicitly"]
    fn a_step_with_nothing_new_does_one_listing_and_loads_no_document_for_1000_documents() {
        assert_idle_steps_are_cheap(1_000);
    }
}
