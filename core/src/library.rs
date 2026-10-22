//! The Library: the Documents a user has imported.
//!
//! Layout (ADR-0012): `<root>/<sha256>/<original file name>`. The hash is the
//! Document's ID (ADR-0007). Imports are staged under `<root>/.staging` and
//! renamed into place, so a Document is either fully there or not at all.
//! Removals go the other way: the folder is renamed into `<root>/.removing`
//! first, then deleted.
//!
//! What was Imported and Removed, with each Import's Date Imported, is the
//! Library document (`LIBRARY`), see `library_doc`. It is recorded before the
//! folder changes, so `open` can finish what a crash interrupted.
//!
//! Next to its File, a Document's folder holds the state of each of its Imports
//! as a hidden file (`state_name`), see `state`; the Document reads as the
//! union of them. They are separate Automerge documents, never merged into
//! one, so the Device ID can be the actor in all of them. The File is the folder's only non-hidden entry. A state is
//! stored like an Import: written to staging, then renamed into place. So are
//! the Document's details (`DETAILS`, see `details`), which are never synced,
//! and its Reading Progress (`progress_name`, see `progress`), which `sync`
//! sends as a plain value (ADR-0020).
//!
//! Every local change to an Automerge document is made as the Device ID, which
//! is generated once and kept in `DEVICE`.
//!
//! `sync` exchanges the Library, the states, the Preferences and the Files with
//! a storage, see `sync`. What this Device knows of the exchange of each
//! document is kept in a cursor file: `LIBRARY_CURSOR`, `PREFERENCES_CURSOR`
//! and, next to a state, `cursor_name`.

use crate::chunks::Cursor;
use crate::details::{self, Details, Format, Size};
use crate::epub::{self, Epub};
use crate::library_doc::{Import, LibraryDoc};
use crate::markup::{self, Anchor, Highlight, Markup, PageNote, Rgb};
use crate::preferences::{self, HighlightColor, HighlightColors};
use crate::progress::{self, Place, ReadingProgress};
use crate::state;
use crate::storage;
use crate::storage::{flush_ordered, ignore_not_found, unique_name};
use automerge::{ActorId, AutoCommit};
use sha2::{Digest, Sha256};
use std::collections::{HashMap, HashSet};
use std::fs::{self, File};
use std::io::{self, Read, Write};
use std::path::{Component, Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering::Relaxed};
use std::sync::{Mutex, MutexGuard, PoisonError};
use std::time::{SystemTime, UNIX_EPOCH};

mod sync;

const STAGING: &str = ".staging";
const REMOVING: &str = ".removing";
const LIBRARY: &str = ".library.automerge";
const LIBRARY_CURSOR: &str = ".library.cursor";
const DEVICE: &str = ".device";
const PREFERENCES: &str = ".preferences.automerge";
const PREFERENCES_CURSOR: &str = ".preferences.cursor";
/// What `Dirty` calls the Preferences. No Import ID, which is hex.
const PREFERENCES_KEY: &str = "preferences";
/// The state of a Document before Imports had their own, see `open`.
const LEGACY_STATE: &str = ".state.automerge";
/// A Document's details, in its folder.
const DETAILS: &str = ".details";
/// The fewest Documents `documents` lists on a thread of their own.
const MIN_PER_THREAD: usize = 32;

/// A Document in the Library.
#[derive(Debug, Clone, PartialEq)]
pub struct Document {
    /// SHA-256 of the File, lowercase hex.
    pub id: String,
    /// The stored File.
    pub path: PathBuf,
    /// Date Imported: that of the Document's first Import, in milliseconds
    /// since the Unix epoch.
    pub imported: u64,
    /// Where the user left off; none if the Document was never opened, or its
    /// state is missing or unreadable.
    pub progress: Option<ReadingProgress>,
    /// What was read from the File: by the core at Import for an EPUB, by the
    /// client for a PDF (`set_details`). None until then, or if they are
    /// unreadable.
    pub details: Option<Details>,
}

impl Document {
    /// An EPUB once its details are read, else a PDF.
    pub fn format(&self) -> Format {
        self.details.as_ref().map_or(Format::Pdf, Details::format)
    }

    /// The Title: the title stored in the File, or else its name without
    /// extension.
    pub fn title(&self) -> String {
        match self.details.as_ref().and_then(|d| d.title.clone()) {
            Some(title) => title,
            None => self
                .path
                .file_stem()
                .map_or_else(String::new, |stem| stem.to_string_lossy().into_owned()),
        }
    }

    /// How far the user has got, in whole percent rounded down. For a PDF it
    /// counts the page they are on: 100 only on the last page. For an EPUB it
    /// counts the characters before their place: 100 only at the end. None if
    /// the Document was never opened, its size isn't known yet, or the Reading
    /// Progress is of another Format.
    pub fn percent_read(&self) -> Option<u8> {
        let (reached, total) = match (&self.details.as_ref()?.size, self.progress?.place) {
            (Size::Pages(pages), Place::Pdf { page_index, .. }) => {
                (u64::from(page_index) + 1, u64::from(*pages))
            }
            (
                Size::Characters(items),
                Place::Epub {
                    spine_index,
                    offset,
                },
            ) => {
                let before = items.iter().take(spine_index as usize);
                let in_item = items
                    .get(spine_index as usize)
                    .map_or(0, |&n| offset.min(n));
                (before.sum::<u64>() + in_item, items.iter().sum())
            }
            _ => return None,
        };
        (total > 0).then(|| (100 * u128::from(reached) / u128::from(total)).min(100) as u8)
    }
}

/// Why an Import failed.
#[derive(Debug)]
pub enum ImportError {
    /// Reading or copying the File failed. Nothing was imported.
    Io(io::Error),
    /// The File is an EPUB LeafPDF can't read. Nothing was imported.
    Epub(epub::Error),
}

impl From<io::Error> for ImportError {
    fn from(e: io::Error) -> Self {
        Self::Io(e)
    }
}

impl From<epub::Error> for ImportError {
    fn from(e: epub::Error) -> Self {
        Self::Epub(e)
    }
}

impl std::fmt::Display for ImportError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Io(e) => e.fmt(f),
            Self::Epub(e) => e.fmt(f),
        }
    }
}

impl std::error::Error for ImportError {}

/// What an Import did.
#[derive(Debug, Clone, PartialEq)]
pub enum ImportResult {
    /// The File was copied into the Library as a new Document.
    Imported(Document),
    /// The Library already held a File with the same content, possibly under
    /// another name. Nothing was copied; this is the existing Document.
    AlreadyImported(Document),
}

/// The Library folder.
#[derive(Debug)]
pub struct Library {
    root: PathBuf,
    device_id: ActorId,
    /// The Library document. Imports and Removes change it and the folders
    /// under this lock, so they never interleave.
    doc: Mutex<LibraryDoc>,
    /// What this Device knows of its exchange of its documents with a storage.
    /// Held for a whole `sync`, so only one runs at a time. Taken first.
    exchanges: Mutex<Exchanges>,
    /// Which documents changed locally since `sync` last sent them.
    dirty: Mutex<Dirty>,
    /// Held while a state or the Preferences is read, changed and written, so
    /// local edits and merged chunks never overwrite each other. Taken after
    /// `exchanges`, before `doc`.
    writing: Mutex<()>,
    /// How often a `sync` changed the Documents, see `sync_changes`.
    sync_changes: AtomicU64,
    /// The Documents whose Markup a `sync` changed, see `take_markup_changes`.
    markup_changes: Mutex<Vec<String>>,
    /// The Reading Progress of each Document read so far, by ID, see
    /// `progress_of`. Changed under `writing`, along with the file.
    progress: Mutex<HashMap<String, KnownProgress>>,
    /// The details of each Document read so far, by ID, see `details_of`.
    /// Changed under `writing` by `set_details`, the only writer of the file.
    details: Mutex<HashMap<String, KnownDetails>>,
}

/// A Document's Reading Progress, and the Imports it was read for: when they
/// change, e.g. at a Re-Import, it is read again.
type KnownProgress = (Vec<String>, Option<ReadingProgress>);

/// A Document's details, and the Imports they were read for: a Re-Import
/// starts without details.
type KnownDetails = (Vec<String>, Option<Details>);

/// The cursors of the documents `sync` exchanges.
#[derive(Debug, Default)]
struct Exchanges {
    /// By Import ID, `PREFERENCES_KEY` or `LIBRARY_KEY`; read from disk when
    /// first needed.
    docs: HashMap<String, Cursor>,
}

/// The documents with local changes `sync` hasn't sent, so a step with nothing
/// new loads none of them.
#[derive(Debug)]
struct Dirty {
    /// Every document might have: changes may have been made before the Library
    /// was opened. Cleared by the first `sync` that succeeds.
    everything: bool,
    /// By Import ID, or `PREFERENCES_KEY`.
    keys: HashSet<String>,
}

/// What `documents` needs of one Document, read from the Library document.
struct Entry {
    id: String,
    name: String,
    /// Date Imported: that of the Document's first Import.
    imported: u64,
    /// The IDs of the Document's Imports, first Import first.
    imports: Vec<String>,
}

impl Library {
    /// Opens the Library at `root`, creating it if needed and discarding
    /// leftovers of Imports and Removals that never finished.
    ///
    /// A Library without a Library document migrates: each folder becomes an
    /// Import dated by the folder, and its state becomes the state of that
    /// Import. That state and the Preferences are remade as this Device, so
    /// Sync sends them.
    pub fn open(root: impl Into<PathBuf>) -> io::Result<Self> {
        let root = root.into();
        for dir in [root.join(STAGING), root.join(REMOVING)] {
            ignore_not_found(fs::remove_dir_all(&dir))?;
            fs::create_dir_all(&dir)?;
        }
        let device_id = load_device_id(&root)?;
        let doc = LibraryDoc::load(fs::read(root.join(LIBRARY)).ok().as_deref(), &device_id);
        let library = Library {
            root,
            device_id,
            doc: Mutex::new(doc),
            exchanges: Mutex::default(),
            dirty: Mutex::new(Dirty {
                everything: true,
                keys: HashSet::new(),
            }),
            writing: Mutex::new(()),
            sync_changes: AtomicU64::new(0),
            markup_changes: Mutex::new(Vec::new()),
            progress: Mutex::default(),
            details: Mutex::default(),
        };
        library.reconcile()?;
        Ok(library)
    }

    /// This Device's ID: 32 lowercase hex digits, generated when the Library
    /// was first opened.
    pub fn device_id(&self) -> String {
        self.device_id.to_hex_string()
    }

    /// How often a `sync` has changed the Documents (added, Removed or got
    /// them a File) since this Library was opened, even if that `sync` failed
    /// later. A caller that sees it grow reloads `documents`.
    pub fn sync_changes(&self) -> u64 {
        self.sync_changes.load(Relaxed)
    }

    /// The IDs of the Documents whose Markup a `sync` changed since the last
    /// call, each once. A caller that gets one reloads its `markup`.
    pub fn take_markup_changes(&self) -> Vec<String> {
        std::mem::take(
            &mut *self
                .markup_changes
                .lock()
                .unwrap_or_else(PoisonError::into_inner),
        )
    }

    /// Brings the folders and the Library document in line after a crash, an
    /// older version or a Sync: each folder with a File but no Import gets one,
    /// the folder of a Removed Document is deleted, the File of a Document
    /// takes the name its Library document lists, and every Document's first
    /// Import adopts a state left in the old place.
    fn reconcile(&self) -> io::Result<()> {
        let mut doc = self.catalog();
        let mut folders = Vec::new();
        for entry in fs::read_dir(&self.root)? {
            let entry = entry?;
            let hash = entry.file_name().to_string_lossy().into_owned();
            if !hash.starts_with('.') && entry.file_type()?.is_dir() {
                folders.push((hash, entry.path()));
            }
        }
        let removed_hashes: HashSet<String> =
            doc.removed_files().into_iter().map(str::to_owned).collect();
        let mut changed = false;
        let mut first_imports = Vec::new();
        for (hash, folder) in folders {
            if let Some(import) = doc.live(&hash).next() {
                adopt_name(&folder, &import.name)?;
                first_imports.push((folder, import.id.clone()));
            } else if removed_hashes.contains(&hash) {
                // A Remove that was recorded but never finished.
                fs::remove_dir_all(&folder)?;
            } else if let Some((name, imported)) = stored_file(&folder)? {
                let id = doc.add_import(&hash, &name, imported);
                changed = true;
                first_imports.push((folder, id));
            }
        }
        if changed {
            self.save_catalog(&mut doc)?;
        }
        // Only now, so a crash in between doesn't strand a state.
        for (folder, import) in first_imports {
            self.adopt_legacy_state(&folder, &import)?;
        }
        Ok(())
    }

    /// Makes the state an older LeafPDF left in the Document `folder`, if any,
    /// the state of Import `import`. It is remade as this Device, which Sync
    /// sends; its changes by random actors no Device would.
    fn adopt_legacy_state(&self, folder: &Path, import: &str) -> io::Result<()> {
        let legacy = folder.join(LEGACY_STATE);
        let bytes = match fs::read(&legacy) {
            Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(()),
            result => result?,
        };
        // An unreadable one is dropped, as a corrupt state is replaced.
        if let Some(remade) = state::remake(&bytes, &self.device_id) {
            write_atomically(&self.staging(), &folder.join(state_name(import)), &remade)?;
        }
        fs::remove_file(legacy)
    }

    /// Copies the File at `source` into the Library, unchanged. Importing a
    /// File that is already there copies nothing and returns its Document as
    /// `AlreadyImported`.
    ///
    /// A File that is a zip, or named `.epub`, is an EPUB: if it isn't a valid
    /// reflowable one without DRM, nothing is imported. The core reads the
    /// details of an EPUB itself. Any other File is a PDF, which the client
    /// checks.
    ///
    /// `progress(copied, total)` is called with the bytes processed so far out
    /// of the File's size: first with 0, last with the total.
    pub fn import(
        &self,
        source: &Path,
        progress: impl FnMut(u64, u64),
    ) -> Result<ImportResult, ImportError> {
        let name = source
            .file_name()
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "source has no file name"))?
            .to_string_lossy()
            .into_owned();

        let staged = self.staging().join(unique_name());
        fs::create_dir(&staged)?;

        let result = self.import_staged(source, &staged, &name, progress);
        // Nothing left to remove after a successful rename.
        let _ = fs::remove_dir_all(&staged);

        let (id, is_new) = result?;
        // A duplicate keeps the name it was first imported under.
        let document = self
            .document(&id)?
            .ok_or_else(|| io::Error::other("imported Document is empty"))?;
        Ok(if is_new {
            ImportResult::Imported(document)
        } else {
            ImportResult::AlreadyImported(document)
        })
    }

    /// Copies `source` into the `staged` folder as `name`, checks it and moves
    /// it into the Library. Returns the Document's ID, and whether it is new.
    fn import_staged(
        &self,
        source: &Path,
        staged: &Path,
        name: &str,
        progress: impl FnMut(u64, u64),
    ) -> Result<(String, bool), ImportError> {
        let id = copy_hashed(source, &staged.join(name), progress)?;
        let epub_details = read_epub_details(&staged.join(name), name)?;
        let is_new = self.admit(staged, &id, name)?;
        // Also for a File the Library had without details, e.g. from a Sync.
        if let Some(details) = epub_details {
            self.set_details(&id, &details)?;
        }
        Ok((id, is_new))
    }

    /// Moves the staged Import of the File `id` named `name` into the Library
    /// as a Document, unless it is there already, and records the Import. True
    /// if it moved.
    fn admit(&self, staged: &Path, id: &str, name: &str) -> io::Result<bool> {
        let folder = self.root.join(id);
        let mut doc = self.catalog();
        // A folder without a File holds just a state, which a Sync got before
        // the File.
        if folder.exists() && stored_file(&folder)?.is_some() {
            return Ok(false);
        }
        // The Library may list the File already, e.g. after an interrupted
        // Import: it keeps its Import, and its name.
        let listed = doc.live(id).next().map(|i| i.name.clone());
        let name = match listed {
            Some(listed) if is_file_name(&listed) => {
                fs::rename(staged.join(name), staged.join(&listed))?;
                listed
            }
            Some(_) => name.to_owned(),
            None => {
                doc.add_import(id, name, now());
                self.save_catalog(&mut doc)?;
                name.to_owned()
            }
        };
        if folder.exists() {
            fs::rename(staged.join(&name), folder.join(&name))?;
        } else {
            fs::rename(staged, folder)?;
        }
        Ok(true)
    }

    /// All Documents, newest Import first.
    pub fn documents(&self) -> io::Result<Vec<Document>> {
        let mut entries = self.entries();
        entries.sort_by(|a, b| b.imported.cmp(&a.imported).then_with(|| a.id.cmp(&b.id)));
        // Reading each Document's state dominates, so a large Library is
        // spread over the cores: 1,000 Documents list in half the time. A
        // small one lists on this thread.
        let threads = std::thread::available_parallelism().map_or(1, usize::from);
        let per_thread = chunk_size(entries.len(), threads);
        let list = |chunk: &[Entry]| -> io::Result<Vec<_>> {
            chunk.iter().map(|e| self.document_of(e)).collect()
        };
        let per_chunk = if entries.len() <= per_thread {
            vec![list(&entries)?]
        } else {
            std::thread::scope(|scope| {
                let workers: Vec<_> = entries
                    .chunks(per_thread)
                    .map(|chunk| scope.spawn(move || list(chunk)))
                    .collect();
                workers
                    .into_iter()
                    .map(|worker| worker.join().expect("listing a Document doesn't panic"))
                    .collect::<io::Result<Vec<_>>>()
            })?
        };
        // Documents without a File (`None`) are skipped.
        Ok(per_chunk.into_iter().flatten().flatten().collect())
    }

    /// The Documents the Library document lists, in no order.
    fn entries(&self) -> Vec<Entry> {
        let doc = self.catalog();
        let mut by_hash: HashMap<&str, Vec<&Import>> = HashMap::new();
        for import in doc.imports().iter().filter(|i| !i.removed) {
            by_hash.entry(&import.hash).or_default().push(import);
        }
        by_hash.into_values().map(Entry::new).collect()
    }

    /// The Document `id` the Library document lists, if any.
    fn entry(&self, id: &str) -> Option<Entry> {
        let doc = self.catalog();
        let imports: Vec<_> = doc.live(id).collect();
        (!imports.is_empty()).then(|| Entry::new(imports))
    }

    /// Document `id`, as `documents` lists it; none if it isn't in the
    /// Library or its File isn't stored yet. An `id` that isn't a Document ID
    /// is `InvalidInput`.
    pub fn document(&self, id: &str) -> io::Result<Option<Document>> {
        self.folder(id)?;
        match self.entry(id) {
            Some(entry) => self.document_of(&entry),
            None => Ok(None),
        }
    }

    /// EPUB `id`, opened for reading; none for a PDF, a Document that isn't in
    /// the Library, or an EPUB that can't be opened anymore. An `id` that
    /// isn't a Document ID is `InvalidInput`.
    pub fn open_epub(&self, id: &str) -> io::Result<Option<Epub>> {
        let Some(document) = self.document(id)? else {
            return Ok(None);
        };
        if document.format() != Format::Epub {
            return Ok(None);
        }
        Ok(Epub::open(&document.path).ok())
    }

    /// The bytes of the Cover image of EPUB `id`; none for a PDF, a Document
    /// that isn't in the Library, or an EPUB without images. An `id` that isn't
    /// a Document ID is `InvalidInput`.
    pub fn epub_cover(&self, id: &str) -> io::Result<Option<Vec<u8>>> {
        Ok(self.open_epub(id)?.and_then(|mut epub| epub.cover()))
    }

    /// Keeps `details`, read from the File of Document `id`, on this Device,
    /// replacing any before; `Document::details` returns them as `details`
    /// stores them. Does nothing for a Document that isn't in the Library. An
    /// `id` that isn't a Document ID is `InvalidInput`.
    pub fn set_details(&self, id: &str, details: &Details) -> io::Result<()> {
        let path = self.folder(id)?.join(DETAILS);
        let Some(entry) = self.entry(id) else {
            return Ok(());
        };
        let bytes = details::encode(details);
        // Under `writing`, so the cache ends as the last write left the file.
        let _writing = self.writing();
        let written = write_atomically(&self.staging(), &path, &bytes);
        if written.is_ok() {
            // As stored, i.e. normalized. Kept for the Imports the write was
            // for: should a re-Import have overtaken it, the file is read again.
            let known = (entry.imports, details::decode(&bytes));
            self.known_details().insert(id.to_owned(), known);
        }
        // The folder may be gone: the Document was Removed.
        ignore_not_found(written)
    }

    /// The details of the Document of `entry`. Read once, then kept in memory.
    fn details_of(&self, entry: &Entry) -> Option<Details> {
        if let Some((imports, known)) = self.known_details().get(&entry.id)
            && *imports == entry.imports
        {
            return known.clone();
        }
        let read = fs::read(self.root.join(&entry.id).join(DETAILS))
            .ok()
            .and_then(|bytes| details::decode(&bytes));
        let mut known = self.known_details();
        match known.get(&entry.id) {
            // Set meanwhile.
            Some((imports, set)) if *imports == entry.imports => set.clone(),
            _ => {
                known.insert(entry.id.clone(), (entry.imports.clone(), read.clone()));
                read
            }
        }
    }

    fn known_details(&self) -> MutexGuard<'_, HashMap<String, KnownDetails>> {
        self.details.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// The Document of `entry`, if its File is stored.
    fn document_of(&self, entry: &Entry) -> io::Result<Option<Document>> {
        let Some(path) = self.file_path(entry)? else {
            return Ok(None);
        };
        Ok(Some(Document {
            id: entry.id.clone(),
            path,
            imported: entry.imported,
            progress: self.progress_of(entry),
            details: self.details_of(entry),
        }))
    }

    /// Where the File of `entry` is stored, if it is.
    fn file_path(&self, entry: &Entry) -> io::Result<Option<PathBuf>> {
        // A name from the Library document must not point outside the folder.
        if !is_file_name(&entry.name) {
            return Ok(None);
        }
        let path = self.root.join(&entry.id).join(&entry.name);
        match fs::metadata(&path) {
            Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(None),
            Err(e) => Err(e),
            Ok(meta) => Ok(meta.is_file().then_some(path)),
        }
    }

    /// Stores `progress` as the Reading Progress of Document `id`, replacing
    /// the previous one, without a trace. Saving for a Document that isn't in
    /// the Library (never imported, or Removed, even just now) does nothing.
    /// An `id` that isn't a Document ID is `InvalidInput`.
    pub fn save_progress(&self, id: &str, progress: &ReadingProgress) -> io::Result<()> {
        self.folder(id)?;
        let Some(entry) = self.entry(id) else {
            return Ok(());
        };
        let _writing = self.writing();
        // The folder may be gone: the Document was Removed.
        ignore_not_found(self.write_progress(&entry, progress))
    }

    /// Stores `progress` for the Document of `entry`, under its first Import.
    /// Called under `writing`.
    fn write_progress(&self, entry: &Entry, progress: &ReadingProgress) -> io::Result<()> {
        let path = self
            .root
            .join(&entry.id)
            .join(progress_name(&entry.imports[0]));
        write_atomically(&self.staging(), &path, &progress::encode(progress))?;
        let known = (entry.imports.clone(), Some(*progress));
        self.known_progress().insert(entry.id.clone(), known);
        Ok(())
    }

    /// The Reading Progress of the Document of `entry`: the newest saved for
    /// its Imports, or else the newest an older version kept in their states.
    /// Read once, then kept in memory.
    fn progress_of(&self, entry: &Entry) -> Option<ReadingProgress> {
        if let Some((imports, known)) = self.known_progress().get(&entry.id)
            && *imports == entry.imports
        {
            return *known;
        }
        let folder = self.root.join(&entry.id);
        let newest = |found: Vec<ReadingProgress>| found.into_iter().max_by_key(|p| p.last_read);
        let saved = entry
            .imports
            .iter()
            .filter_map(|i| fs::read(folder.join(progress_name(i))).ok())
            .filter_map(|bytes| progress::decode(&bytes))
            .collect();
        let read = newest(saved).or_else(|| {
            let states = self.read_states(&entry.id, &entry.imports);
            progress::read_all(states.iter().map(Vec::as_slice))
        });
        let mut known = self.known_progress();
        match known.get(&entry.id) {
            // Saved meanwhile.
            Some((imports, saved)) if *imports == entry.imports => *saved,
            _ => {
                known.insert(entry.id.clone(), (entry.imports.clone(), read));
                read
            }
        }
    }

    fn known_progress(&self) -> MutexGuard<'_, HashMap<String, KnownProgress>> {
        self.progress.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// The Markup of Document `id`: empty if it has none, or the Document isn't
    /// in the Library, or its state is unreadable. An `id` that isn't a
    /// Document ID is `InvalidInput`.
    pub fn markup(&self, id: &str) -> io::Result<Markup> {
        self.folder(id)?;
        let states = self.read_states(id, &self.import_ids(id));
        Ok(markup::read_all(states.iter().map(Vec::as_slice)))
    }

    /// Adds a Highlight of `quoted_text` at `anchor` in `color`, `created` in
    /// milliseconds since the Unix epoch, to Document `id`, and returns it. It
    /// is independent of any Highlight already there, also on the same text.
    /// For a Document that isn't in the Library it adds nothing and returns
    /// `None`. A corrupt state is replaced.
    pub fn add_highlight(
        &self,
        id: &str,
        anchor: Anchor,
        quoted_text: &str,
        color: Rgb,
        created: u64,
    ) -> io::Result<Option<Highlight>> {
        let highlight = Highlight {
            id: state::new_id(),
            anchor,
            quoted_text: quoted_text.to_owned(),
            color,
            created,
            note: None,
        };
        let added = self.add_to_state(id, |doc| markup::put_highlight(doc, &highlight))?;
        Ok(added.then_some(highlight))
    }

    /// Sets the color of Highlight `highlight` of Document `id`. Does nothing
    /// for a Highlight that isn't there, or a Document that isn't in the
    /// Library; a Highlight removed on another device stays removed.
    pub fn set_highlight_color(&self, id: &str, highlight: &str, color: Rgb) -> io::Result<()> {
        self.edit_states(id, |doc| markup::put_color(doc, highlight, color))
    }

    /// Sets the Note of Highlight `highlight` of Document `id` to `note`, an
    /// edit of the text that merges with concurrent typing. Empty `note`
    /// removes the Note. Does nothing for a Highlight that isn't there, or a
    /// Document that isn't in the Library.
    pub fn set_highlight_note(&self, id: &str, highlight: &str, note: &str) -> io::Result<()> {
        self.edit_states(id, |doc| markup::put_note(doc, highlight, note))
    }

    /// Removes Highlight `highlight` from Document `id`, without a trace. Does
    /// nothing for a Highlight that isn't there, or a Document that isn't in the
    /// Library.
    pub fn remove_highlight(&self, id: &str, highlight: &str) -> io::Result<()> {
        self.edit_states(id, |doc| markup::remove_highlight(doc, highlight))
    }

    /// Adds a page Note at `place`, a spot of the Format of Document `id`,
    /// `created` in milliseconds since the Unix epoch, and returns it, still without text: it isn't in the Markup until
    /// `set_page_note_text` gives it some. Like `add_highlight`, it adds nothing
    /// and returns `None` for a Document that isn't in the Library.
    pub fn add_page_note(
        &self,
        id: &str,
        place: Place,
        created: u64,
    ) -> io::Result<Option<PageNote>> {
        let note = PageNote {
            id: state::new_id(),
            place,
            created,
            text: String::new(),
        };
        let added = self.add_to_state(id, |doc| markup::put_page_note(doc, &note))?;
        Ok(added.then_some(note))
    }

    /// Sets the text of page Note `note` of Document `id` to `text`, an edit
    /// that merges with concurrent typing. Empty `text` removes the page Note.
    /// Does nothing for a page Note that isn't there, or a Document that isn't
    /// in the Library.
    pub fn set_page_note_text(&self, id: &str, note: &str, text: &str) -> io::Result<()> {
        self.edit_states(id, |doc| markup::put_page_note_text(doc, note, text))
    }

    /// Removes page Note `note` from Document `id`, without a trace. Does
    /// nothing for a page Note that isn't there, or a Document that isn't in the
    /// Library.
    pub fn remove_page_note(&self, id: &str, note: &str) -> io::Result<()> {
        self.edit_states(id, |doc| markup::remove_page_note(doc, note))
    }

    /// The Highlight Colors to choose from, the six built-in ones (yellow
    /// first) then the Custom Colors in the order added, together with the
    /// Default Highlight Color, the color of new Highlights: yellow until the
    /// user picks another, or if the Preferences are unreadable or its Custom
    /// Color was removed. Both come from one load of the Preferences.
    pub fn highlight_colors(&self) -> HighlightColors {
        preferences::highlight_colors(self.read_preferences().as_deref())
    }

    /// Makes the Highlight Color `id`, a built-in color's name or a Custom
    /// Color's ID, the Default Highlight Color. An `id` that is no Highlight
    /// Color is `InvalidInput`. Corrupt Preferences are replaced.
    pub fn set_default_highlight_color(&self, id: &str) -> io::Result<()> {
        if !self.highlight_colors().colors.iter().any(|c| c.id == id) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                format!("{id:?} is not a Highlight Color"),
            ));
        }
        self.edit_preferences(|doc| preferences::set_default_color(doc, id))
    }

    /// Adds `rgb` as a Custom Color after the others, `added` in milliseconds
    /// since the Unix epoch, and returns it. There is no limit. Corrupt
    /// Preferences are replaced.
    pub fn add_custom_color(&self, rgb: Rgb, added: u64) -> io::Result<HighlightColor> {
        let mut color = None;
        self.edit_preferences(|doc| {
            color = Some(preferences::add_custom_color(doc, rgb, added));
        })?;
        Ok(color.expect("the write ran"))
    }

    /// Removes the Custom Color `id`. Highlights keep their color. If it was
    /// the Default Highlight Color, that is yellow again. Does nothing for a
    /// built-in color, which can't be removed, or an unknown `id`.
    pub fn remove_custom_color(&self, id: &str) -> io::Result<()> {
        self.edit_preferences(|doc| preferences::remove_custom_color(doc, id))
    }

    fn read_preferences(&self) -> Option<Vec<u8>> {
        fs::read(self.preferences()).ok()
    }

    fn edit_preferences(&self, change: impl FnOnce(&mut AutoCommit)) -> io::Result<()> {
        self.replace_file(&self.preferences(), |existing| {
            state::update_versioned(
                existing,
                &self.device_id,
                preferences::SCHEMA_VERSION,
                change,
            )
        })?;
        self.mark_dirty(PREFERENCES_KEY);
        Ok(())
    }

    /// Makes `change` to the state of every Import of Document `id`. It does
    /// nothing in a state that holds nothing it changes. Nothing happens if the
    /// Document isn't in the Library.
    fn edit_states(&self, id: &str, change: impl Fn(&mut AutoCommit)) -> io::Result<()> {
        let folder = self.folder(id)?;
        for import in self.import_ids(id) {
            self.update_state(&folder, &import, &change)?;
        }
        Ok(())
    }

    /// Makes `change` to the state of the Document's first Import, which
    /// holds what is added. Whether it was made: not if the Document isn't in
    /// the Library.
    fn add_to_state(&self, id: &str, change: impl FnOnce(&mut AutoCommit)) -> io::Result<bool> {
        let folder = self.folder(id)?;
        match self.import_ids(id).first() {
            Some(import) => self.update_state(&folder, import, change).map(|()| true),
            None => Ok(false),
        }
    }

    fn update_state(
        &self,
        folder: &Path,
        import: &str,
        change: impl FnOnce(&mut AutoCommit),
    ) -> io::Result<()> {
        self.replace_file(&folder.join(state_name(import)), |existing| {
            state::update(existing, &self.device_id, change)
        })?;
        self.mark_dirty(import);
        Ok(())
    }

    /// Notes that the document `key` has local changes for `sync` to send.
    /// Called after the change is stored, so a `sync` that clears the note
    /// first finds the change at the next one.
    fn mark_dirty(&self, key: &str) {
        let mut dirty = self.dirty.lock().unwrap_or_else(PoisonError::into_inner);
        dirty.keys.insert(key.to_owned());
    }

    /// The IDs of the Imports of Document `id`, first Import first.
    fn import_ids(&self, id: &str) -> Vec<String> {
        self.catalog().live(id).map(|i| i.id.clone()).collect()
    }

    /// The stored states of the Imports `imports` of Document `id`.
    fn read_states(&self, id: &str, imports: &[String]) -> Vec<Vec<u8>> {
        let folder = self.root.join(id);
        imports
            .iter()
            .filter_map(|i| fs::read(folder.join(state_name(i))).ok())
            .collect()
    }

    /// Replaces the file `path` with what `write` makes of its content (none if
    /// missing). The file is staged and renamed into place, so it is never half
    /// written.
    fn replace_file(
        &self,
        path: &Path,
        write: impl FnOnce(Option<&[u8]>) -> Vec<u8>,
    ) -> io::Result<()> {
        let _writing = self.writing();
        let existing = fs::read(path).ok();
        // The folder may be gone: the Document was never there or was Removed.
        ignore_not_found(write_atomically(
            &self.staging(),
            path,
            &write(existing.as_deref()),
        ))
    }

    fn writing(&self) -> MutexGuard<'_, ()> {
        self.writing.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// The Library document, locked.
    fn catalog(&self) -> MutexGuard<'_, LibraryDoc> {
        // A panic in another thread leaves the document as it was saved.
        self.doc.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Stores the Library document.
    fn save_catalog(&self, doc: &mut LibraryDoc) -> io::Result<()> {
        write_atomically(&self.staging(), &self.root.join(LIBRARY), &doc.save())
    }

    /// Deletes the Document `id` and its File. Removing a Document that
    /// isn't there does nothing. An `id` that isn't a Document ID (e.g. a
    /// path) is `InvalidInput`.
    ///
    /// The Remove is recorded in the Library document, which a re-Import
    /// doesn't reuse: it starts without state. The folder leaves the Library
    /// in one rename, so a crash mid-delete never leaves a half-deleted
    /// Document listed; `open` finishes the job.
    pub fn remove(&self, id: &str) -> io::Result<()> {
        let folder = self.folder(id)?;
        let doomed = self.removing().join(unique_name());
        {
            let mut doc = self.catalog();
            if doc.remove(id) {
                self.save_catalog(&mut doc)?;
            }
            match fs::rename(folder, &doomed) {
                Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(()),
                result => result?,
            }
        }
        fs::remove_dir_all(doomed)
    }

    /// The folder of Document `id`, which may not exist. `id` must be a plain
    /// name, so it can't point outside the Library.
    fn folder(&self, id: &str) -> io::Result<PathBuf> {
        let mut parts = Path::new(id).components();
        let is_plain_name = matches!(
            (parts.next(), parts.next()),
            (Some(Component::Normal(name)), None) if !name.to_string_lossy().starts_with('.')
        );
        if !is_plain_name {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                format!("{id:?} is not a Document ID"),
            ));
        }
        Ok(self.root.join(id))
    }

    fn staging(&self) -> PathBuf {
        self.root.join(STAGING)
    }

    fn removing(&self) -> PathBuf {
        self.root.join(REMOVING)
    }

    fn preferences(&self) -> PathBuf {
        self.root.join(PREFERENCES)
    }
}

impl Entry {
    /// The Document of `imports`, its first Import first.
    fn new(imports: Vec<&Import>) -> Self {
        let first = imports[0];
        Self {
            id: first.hash.clone(),
            name: first.name.clone(),
            imported: first.imported,
            imports: imports.iter().map(|i| i.id.clone()).collect(),
        }
    }
}

/// The name of the file holding the state of Import `import`. Hidden, so the
/// File stays the folder's only non-hidden entry.
fn state_name(import: &str) -> String {
    format!(".state-{import}.automerge")
}

/// Documents per thread when listing `len` of them on up to `threads`: a
/// thread isn't worth starting for fewer than `MIN_PER_THREAD`.
fn chunk_size(len: usize, threads: usize) -> usize {
    len.div_ceil(threads).max(MIN_PER_THREAD)
}

/// The name of the file holding the Reading Progress saved for Import
/// `import`: that of its Document, if it is the Document's first Import.
fn progress_name(import: &str) -> String {
    format!(".progress-{import}")
}

/// The name of the file holding what this Device knows of the exchange of the
/// state of Import `import` with a storage.
fn cursor_name(import: &str) -> String {
    format!(".cursor-{import}")
}

/// The details of the EPUB `file` named `name`; none if it isn't meant to be
/// one: a File that is a zip, or has the extension `.epub`, unless it is a PDF.
fn read_epub_details(file: &Path, name: &str) -> Result<Option<Details>, epub::Error> {
    let mut head = [0; 5];
    let read = File::open(file).and_then(|mut f| f.read(&mut head));
    let head = &head[..read.unwrap_or(0)];
    let is_epub = !head.starts_with(b"%PDF-")
        && (head.starts_with(b"PK\x03\x04") || name.to_lowercase().ends_with(".epub"));
    if !is_epub {
        return Ok(None);
    }
    let mut epub = Epub::open(file)?;
    Ok(Some(Details {
        title: epub.title().map(str::to_owned),
        author: epub.author().map(str::to_owned),
        size: Size::Characters(epub.characters()),
    }))
}

/// Whether `name` is a plain file name, not a path.
fn is_file_name(name: &str) -> bool {
    Path::new(name).file_name().is_some_and(|n| n == name)
}

/// Milliseconds since the Unix epoch.
pub(crate) fn now() -> u64 {
    millis(SystemTime::now())
}

fn millis(time: SystemTime) -> u64 {
    time.duration_since(UNIX_EPOCH)
        .map_or(0, |d| u64::try_from(d.as_millis()).unwrap_or(u64::MAX))
}

/// The Device ID stored in the Library folder `root`, generated first if there
/// is none. Preferences from before Device IDs are then remade as it, see
/// `state::remake`; before it is stored, so a crash doesn't skip that.
fn load_device_id(root: &Path) -> io::Result<ActorId> {
    let path = root.join(DEVICE);
    let stored = fs::read_to_string(&path)
        .ok()
        .and_then(|hex| ActorId::try_from(hex.trim()).ok());
    if let Some(id) = stored {
        return Ok(id);
    }
    let id = ActorId::random();
    let preferences = root.join(PREFERENCES);
    if let Some(remade) = fs::read(&preferences)
        .ok()
        .and_then(|bytes| state::remake(&bytes, &id))
    {
        write_atomically(&root.join(STAGING), &preferences, &remade)?;
    }
    write_atomically(&root.join(STAGING), &path, id.to_hex_string().as_bytes())?;
    Ok(id)
}

/// `storage::write_atomically` for `bytes`.
fn write_atomically(staging: &Path, path: &Path, mut bytes: &[u8]) -> io::Result<()> {
    storage::write_atomically(staging, path, &mut bytes)
}

/// Streams the file `from` into a new file at `to`, returning the SHA-256 of
/// the bytes.
fn copy_hashed(from: &Path, to: &Path, progress: impl FnMut(u64, u64)) -> io::Result<String> {
    let mut input = File::open(from)?;
    let total = input.metadata()?.len();
    stream_hashed(&mut input, to, total, progress)
}

/// Streams `input`, `total` bytes long, into a new file at `to`, returning the
/// SHA-256 of the bytes. `progress` is called as in `Library::import`.
fn stream_hashed(
    input: &mut dyn Read,
    to: &Path,
    total: u64,
    mut progress: impl FnMut(u64, u64),
) -> io::Result<String> {
    let mut copied = 0;
    progress(copied, total);
    let mut output = File::create_new(to)?;
    let mut hasher = Sha256::new();
    let mut buffer = vec![0; 256 * 1024];
    loop {
        let n = match input.read(&mut buffer) {
            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
            result => result?,
        };
        if n == 0 {
            break;
        }
        hasher.update(&buffer[..n]);
        output.write_all(&buffer[..n])?;
        copied += n as u64;
        progress(copied, total);
    }
    flush_ordered(&output)?;
    Ok(hex(&hasher.finalize()))
}

/// `bytes` as lowercase hex, e.g. a SHA-256 digest as a Document's id.
fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// Renames the File in the Document folder `folder` to `name`, if it has
/// another one and `name` is a plain file name. Does nothing if there is no
/// File, or the folder already has one under `name`.
fn adopt_name(folder: &Path, name: &str) -> io::Result<()> {
    if !is_file_name(name) || folder.join(name).is_file() {
        return Ok(());
    }
    if let Some((stored, _)) = stored_file(folder)? {
        fs::rename(folder.join(stored), folder.join(name))?;
    }
    Ok(())
}

/// The name of the File in the Document folder `dir`, and when the folder was
/// created in milliseconds since the Unix epoch. None if it holds no File.
fn stored_file(dir: &Path) -> io::Result<Option<(String, u64)>> {
    let meta = fs::metadata(dir)?;
    let created = meta.created().or_else(|_| meta.modified())?;
    for entry in fs::read_dir(dir)? {
        let name = entry?.file_name().to_string_lossy().into_owned();
        if !name.starts_with('.') {
            return Ok(Some((name, millis(created))));
        }
    }
    Ok(None)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::markup::{EpubPosition, PageRects, Rect};
    use automerge::{ActorId, AutoCommit};
    use std::fs;
    use std::thread::sleep;
    use std::time::Duration;

    /// A fresh folder under the system temp dir, removed on drop.
    struct Scratch(PathBuf);

    impl Scratch {
        fn new() -> Self {
            use std::sync::atomic::{AtomicU32, Ordering::Relaxed};
            static NEXT: AtomicU32 = AtomicU32::new(0);
            let dir = std::env::temp_dir().join(format!(
                "leafpdf-test-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Relaxed)
            ));
            fs::create_dir_all(&dir).unwrap();
            Scratch(dir)
        }

        fn file(&self, name: &str, bytes: &[u8]) -> PathBuf {
            let path = self.0.join(name);
            fs::write(&path, bytes).unwrap();
            path
        }

        fn library(&self) -> Library {
            Library::open(self.0.join("library")).unwrap()
        }
    }

    impl Drop for Scratch {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    fn import(library: &Library, source: &Path) -> Result<ImportResult, ImportError> {
        library.import(source, |_, _| {})
    }

    /// Imports a File that is expected to be new.
    fn import_new(library: &Library, source: &Path) -> Document {
        match import(library, source).unwrap() {
            ImportResult::Imported(document) => document,
            other => panic!("expected Imported, got {other:?}"),
        }
    }

    // SHA-256 of "abc", from FIPS 180-2.
    const ABC_SHA256: &str = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";

    #[test]
    fn import_stores_a_byte_identical_file_under_its_hash_and_original_name() {
        let scratch = Scratch::new();
        let library = scratch.library();
        let source = scratch.file("Paper.pdf", b"abc");

        let document = import_new(&library, &source);

        assert_eq!(document.id, ABC_SHA256);
        assert_eq!(
            document.path,
            scratch.0.join("library").join(ABC_SHA256).join("Paper.pdf")
        );
        assert_eq!(fs::read(&document.path).unwrap(), b"abc");
        assert_eq!(fs::read(&source).unwrap(), b"abc");
    }

    #[test]
    fn import_reports_bytes_copied_until_it_reaches_the_total() {
        let scratch = Scratch::new();
        let library = scratch.library();
        let size = 600 * 1024;
        let source = scratch.file("big.pdf", &vec![7; size]);

        let mut reports = Vec::new();
        library
            .import(&source, |copied, total| reports.push((copied, total)))
            .unwrap();

        let total = size as u64;
        assert!(reports.len() > 2, "expected progress in steps: {reports:?}");
        assert!(
            reports
                .iter()
                .all(|&(copied, t)| t == total && copied <= total)
        );
        assert!(reports.windows(2).all(|w| w[0].0 <= w[1].0));
        assert_eq!(reports.last(), Some(&(total, total)));
    }

    #[test]
    fn documents_lists_newest_import_first() {
        let scratch = Scratch::new();
        let library = scratch.library();
        let first = import_new(&library, &scratch.file("a.pdf", b"first"));
        sleep(Duration::from_millis(20));
        let second = import_new(&library, &scratch.file("b.pdf", b"second"));

        assert_eq!(library.documents().unwrap(), vec![second, first]);
    }

    #[test]
    fn an_empty_library_has_no_documents() {
        let scratch = Scratch::new();
        assert_eq!(scratch.library().documents().unwrap(), vec![]);
    }

    use crate::epub::fixtures::Book;

    fn emma() -> Book {
        Book::new("<dc:title>Emma</dc:title><dc:creator>Jane Austen</dc:creator>")
            .chapters(&["<p>Hello</p>", "<p>world</p>"])
    }

    #[test]
    fn an_imported_epub_is_a_document_with_format_title_author_and_size() {
        let scratch = Scratch::new();
        let library = scratch.library();
        let bytes = emma().bytes();

        let document = import_new(&library, &scratch.file("book.epub", &bytes));

        assert_eq!(document.format(), Format::Epub);
        assert_eq!(document.title(), "Emma");
        let details = document.details.as_ref().unwrap();
        assert_eq!(details.author.as_deref(), Some("Jane Austen"));
        assert_eq!(details.size, Size::Characters(vec![5, 5]));
        // Listed that way too, and the File stays as it was.
        assert_eq!(
            library.documents().unwrap(),
            std::slice::from_ref(&document)
        );
        assert_eq!(fs::read(&document.path).unwrap(), bytes);
        assert_eq!(document.path.file_name().unwrap(), "book.epub");
    }

    #[test]
    fn an_epub_is_recognised_by_its_content_not_its_name() {
        let scratch = Scratch::new();
        let library = scratch.library();
        let document = import_new(&library, &scratch.file("book", &emma().bytes()));
        assert_eq!(document.format(), Format::Epub);
    }

    #[test]
    fn an_epub_without_a_title_is_titled_by_its_file_name() {
        let scratch = Scratch::new();
        let library = scratch.library();
        let book = Book::new("").bytes();
        let document = import_new(&library, &scratch.file("Walden.epub", &book));
        assert_eq!(document.title(), "Walden");
        assert_eq!(document.details.unwrap().author, None);
    }

    #[test]
    fn a_pdf_stays_a_pdf_whatever_its_name() {
        let scratch = Scratch::new();
        let library = scratch.library();
        let document = import_new(&library, &scratch.file("paper.epub", b"%PDF-1.7 ..."));
        assert_eq!(document.format(), Format::Pdf);
        assert_eq!(library.epub_cover(&document.id).unwrap(), None);
    }

    #[test]
    fn an_epubs_cover_is_its_declared_one_else_the_first_image_else_none() {
        let scratch = Scratch::new();
        let library = scratch.library();
        let cover = |book: Book, name: &str| {
            let document = import_new(&library, &scratch.file(name, &book.bytes()));
            library.epub_cover(&document.id).unwrap()
        };

        let declared = Book::new("")
            .manifest(
                r#"<item id="i" href="c.png" media-type="image/png" properties="cover-image"/>"#,
            )
            .chapters(&[r#"<img src="first.png"/>"#])
            .file("OEBPS/c.png", b"declared")
            .file("OEBPS/text/first.png", b"first");
        assert_eq!(cover(declared, "a.epub"), Some(b"declared".to_vec()));

        let undeclared = Book::new("x")
            .chapters(&[r#"<img src="first.png"/>"#])
            .file("OEBPS/text/first.png", b"first");
        assert_eq!(cover(undeclared, "b.epub"), Some(b"first".to_vec()));

        assert_eq!(cover(Book::new("y"), "c.epub"), None);
    }

    #[test]
    fn the_cover_of_a_missing_document_is_none_and_of_a_bad_id_an_error() {
        let scratch = Scratch::new();
        let library = scratch.library();
        assert_eq!(library.epub_cover(ABC_SHA256).unwrap(), None);
        assert!(library.epub_cover("../x").is_err());
    }

    #[test]
    fn an_epub_already_imported_is_recognised_by_content() {
        let scratch = Scratch::new();
        let library = scratch.library();
        let bytes = emma().bytes();
        let first = import_new(&library, &scratch.file("a.epub", &bytes));

        let again = import(&library, &scratch.file("copy of a.epub", &bytes)).unwrap();

        assert_eq!(again, ImportResult::AlreadyImported(first));
        assert_eq!(library.documents().unwrap().len(), 1);
    }

    #[test]
    fn epubs_that_cant_be_read_are_rejected_each_for_its_reason() {
        let scratch = Scratch::new();
        let library = scratch.library();
        let drm = r#"<encryption xmlns:enc="http://www.w3.org/2001/04/xmlenc#"><enc:EncryptedData>
<enc:EncryptionMethod Algorithm="http://www.w3.org/2001/04/xmlenc#aes128-cbc"/></enc:EncryptedData></encryption>"#;
        let fixed = Book::new(r#"<meta property="rendition:layout">pre-paginated</meta>"#);
        let drm = emma().file("META-INF/encryption.xml", drm.as_bytes());
        let no_mimetype = crate::epub::fixtures::zip(&[("a.txt", b"a")], &[]);
        let cases: [(&str, Vec<u8>, epub::Error); 5] = [
            ("drm.epub", drm.bytes(), epub::Error::DrmProtected),
            ("fixed.epub", fixed.bytes(), epub::Error::FixedLayout),
            ("garbage.epub", b"not a zip".to_vec(), epub::Error::Invalid),
            ("empty.epub", Vec::new(), epub::Error::Invalid),
            ("zip.zip", no_mimetype, epub::Error::Invalid),
        ];

        for (name, bytes, reason) in cases {
            let rejected = import(&library, &scratch.file(name, &bytes));
            assert!(
                matches!(&rejected, Err(ImportError::Epub(why)) if *why == reason),
                "{name}: {rejected:?}"
            );
        }

        assert_eq!(library.documents().unwrap(), []);
        let folders = fs::read_dir(scratch.0.join("library")).unwrap();
        let stored = folders.filter(|e| {
            !e.as_ref()
                .unwrap()
                .file_name()
                .to_string_lossy()
                .starts_with('.')
        });
        assert_eq!(stored.count(), 0);
        let staged = fs::read_dir(scratch.0.join("library").join(STAGING)).unwrap();
        assert_eq!(staged.count(), 0);
    }

    #[test]
    fn an_epub_opens_to_its_spine_in_reading_order_with_each_items_content() {
        let scratch = Scratch::new();
        let library = scratch.library();
        let book = emma()
            .manifest(r#"<item id="css" href="style.css" media-type="text/css"/>"#)
            .file("OEBPS/style.css", b"p{}");
        let document = import_new(&library, &scratch.file("emma.epub", &book.bytes()));

        let mut epub = library.open_epub(&document.id).unwrap().unwrap();

        assert_eq!(
            epub.spine(),
            ["OEBPS/text/chapter0.xhtml", "OEBPS/text/chapter1.xhtml"]
        );
        let second = epub.resource("OEBPS/text/chapter1.xhtml").unwrap();
        assert_eq!(second.media_type, "application/xhtml+xml");
        assert!(String::from_utf8(second.bytes).unwrap().contains("world"));
        let css = epub.resource("OEBPS/style.css").unwrap();
        assert_eq!(css.media_type, "text/css");
        assert_eq!(css.bytes, b"p{}");
    }

    #[test]
    fn an_epub_opens_to_its_table_of_contents_pointing_into_its_text() {
        let scratch = Scratch::new();
        let library = scratch.library();
        let nav = r#"<html xmlns:epub="x"><body><nav epub:type="toc"><ol><li><a href="text/chapter1.xhtml">Second</a></li></ol></nav></body></html>"#;
        let book = emma()
            .manifest(r#"<item id="n" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>"#)
            .file("OEBPS/nav.xhtml", nav.as_bytes());
        let document = import_new(&library, &scratch.file("emma.epub", &book.bytes()));

        let contents = library.open_epub(&document.id).unwrap().unwrap().contents();

        assert_eq!(contents.len(), 1);
        assert_eq!(contents[0].title, "Second");
        assert_eq!(
            contents[0].place,
            Some(Place::Epub {
                spine_index: 1,
                offset: 0
            })
        );
    }

    #[test]
    fn only_an_epub_in_the_library_opens() {
        let scratch = Scratch::new();
        let library = scratch.library();
        let pdf = import_new(&library, &scratch.file("a.pdf", b"abc"));

        assert!(library.open_epub(&pdf.id).unwrap().is_none());
        assert!(library.open_epub(ABC_SHA256).unwrap().is_none());
        assert!(library.open_epub("../x").is_err());
    }

    #[test]
    fn an_epub_sorts_and_removes_like_a_pdf() {
        let scratch = Scratch::new();
        let library = scratch.library();
        let pdf = import_new(&library, &scratch.file("a.pdf", b"abc"));
        let epub = import_new(&library, &scratch.file("b.epub", &emma().bytes()));
        assert_eq!(library.documents().unwrap(), [epub.clone(), pdf]);

        library.remove(&epub.id).unwrap();

        assert_eq!(library.documents().unwrap().len(), 1);
        assert!(!epub.path.exists());
    }

    #[test]
    fn a_failed_import_leaves_the_library_unchanged() {
        let scratch = Scratch::new();
        let library = scratch.library();
        import_new(&library, &scratch.file("a.pdf", b"abc"));

        assert!(
            library
                .import(&scratch.0.join("missing.pdf"), |_, _| {})
                .is_err()
        );

        assert_eq!(library.documents().unwrap().len(), 1);
        let folders = fs::read_dir(scratch.0.join("library"))
            .unwrap()
            .filter(|e| e.as_ref().unwrap().file_type().unwrap().is_dir())
            .count();
        // The Document plus the (empty) staging and removal folders.
        assert_eq!(folders, 3);
        assert_eq!(
            fs::read_dir(scratch.0.join("library/.staging"))
                .unwrap()
                .count(),
            0
        );
    }

    #[test]
    fn open_removes_leftover_staging_folders() {
        let scratch = Scratch::new();
        let library = scratch.library();
        let leftover = scratch.0.join("library/.staging/crashed");
        fs::create_dir_all(&leftover).unwrap();
        fs::write(leftover.join("half.pdf"), b"ab").unwrap();
        drop(library);

        let library = scratch.library();

        assert!(!leftover.exists());
        assert_eq!(library.documents().unwrap(), vec![]);
    }

    #[test]
    fn importing_the_same_bytes_again_reports_the_existing_document() {
        let scratch = Scratch::new();
        let library = scratch.library();
        let first = import_new(&library, &scratch.file("a.pdf", b"abc"));

        let again = import(&library, &scratch.file("b.pdf", b"abc")).unwrap();

        assert_eq!(again, ImportResult::AlreadyImported(first));
    }

    #[test]
    fn a_duplicate_import_leaves_the_library_unchanged() {
        let scratch = Scratch::new();
        let library = scratch.library();
        let first = import_new(&library, &scratch.file("a.pdf", b"abc"));

        import(&library, &scratch.file("renamed.pdf", b"abc")).unwrap();

        assert_eq!(library.documents().unwrap(), vec![first.clone()]);
        let folder = first.path.parent().unwrap();
        assert_eq!(fs::read_dir(folder).unwrap().count(), 1);
        assert_eq!(
            fs::read_dir(scratch.0.join("library/.staging"))
                .unwrap()
                .count(),
            0
        );
    }

    #[test]
    fn remove_deletes_the_document_and_its_file() {
        let scratch = Scratch::new();
        let library = scratch.library();
        let keep = import_new(&library, &scratch.file("a.pdf", b"first"));
        let gone = import_new(&library, &scratch.file("b.pdf", b"second"));

        library.remove(&gone.id).unwrap();

        assert_eq!(library.documents().unwrap(), vec![keep]);
        assert!(!gone.path.exists());
        assert_eq!(
            fs::read_dir(scratch.0.join("library/.removing"))
                .unwrap()
                .count(),
            0
        );
    }

    #[test]
    fn removing_a_document_that_is_not_there_does_nothing() {
        let scratch = Scratch::new();
        let library = scratch.library();
        let kept = import_new(&library, &scratch.file("a.pdf", b"abc"));

        library.remove("0123").unwrap();

        assert_eq!(library.documents().unwrap(), vec![kept]);
    }

    #[test]
    fn remove_refuses_an_id_that_points_outside_the_library() {
        let scratch = Scratch::new();
        let library = scratch.library();
        let outside = scratch.0.join("outside");
        fs::create_dir(&outside).unwrap();

        for id in ["../outside", "", ".", ".staging", "a/b"] {
            let err = library.remove(id).unwrap_err();
            assert_eq!(err.kind(), io::ErrorKind::InvalidInput, "id {id:?}");
        }
        assert!(outside.exists());
        assert!(scratch.0.join("library/.staging").exists());
    }

    #[test]
    fn a_removed_document_can_be_imported_again() {
        let scratch = Scratch::new();
        let library = scratch.library();
        let source = scratch.file("a.pdf", b"abc");
        let first = import_new(&library, &source);
        library.remove(&first.id).unwrap();

        let again = import_new(&library, &source);

        assert_eq!((&again.id, &again.path), (&first.id, &first.path));
        assert_eq!(library.documents().unwrap(), vec![again]);
    }

    #[test]
    fn open_removes_leftover_removal_folders() {
        let scratch = Scratch::new();
        let library = scratch.library();
        let leftover = scratch.0.join("library/.removing/interrupted");
        fs::create_dir_all(&leftover).unwrap();
        fs::write(leftover.join("half.pdf"), b"ab").unwrap();
        drop(library);

        let library = scratch.library();

        assert!(!leftover.exists());
        assert_eq!(library.documents().unwrap(), vec![]);
    }

    /// The path of the state of the first Import of Document `id`.
    fn first_state_path(library: &Library, id: &str) -> PathBuf {
        let import = library.import_ids(id).remove(0);
        library.folder(id).unwrap().join(state_name(&import))
    }

    /// The path of the Reading Progress of the first Import of Document `id`.
    fn first_progress_path(library: &Library, id: &str) -> PathBuf {
        let import = library.import_ids(id).remove(0);
        library.folder(id).unwrap().join(progress_name(&import))
    }

    /// The path of the state of `document`'s first Import.
    fn state_path(library: &Library, document: &Document) -> PathBuf {
        first_state_path(library, &document.id)
    }

    /// A state holding only `progress`, as any Device would write it.
    fn stored_progress(progress: &ReadingProgress) -> Vec<u8> {
        state::update(None, &ActorId::random(), |doc| {
            progress::put_progress(doc, progress);
        })
    }

    fn progress(page_index: u32, last_read: u64) -> ReadingProgress {
        ReadingProgress::pdf(page_index, 12.5, 700.25, last_read)
    }

    /// The Reading Progress `library` lists for `id`.
    fn listed_progress(library: &Library, id: &str) -> Option<ReadingProgress> {
        let documents = library.documents().unwrap();
        documents.into_iter().find(|d| d.id == id).unwrap().progress
    }

    #[test]
    fn a_never_opened_document_lists_without_reading_progress() {
        let scratch = Scratch::new();
        let library = scratch.library();
        let document = import_new(&library, &scratch.file("a.pdf", b"abc"));

        assert_eq!(document.progress, None);
        assert_eq!(listed_progress(&library, &document.id), None);
    }

    #[test]
    fn saved_reading_progress_is_listed_and_survives_reopening_the_library() {
        let scratch = Scratch::new();
        let library = scratch.library();
        let document = import_new(&library, &scratch.file("a.pdf", b"abc"));

        library
            .save_progress(&document.id, &progress(7, 1_000))
            .unwrap();
        assert_eq!(
            listed_progress(&library, &document.id),
            Some(progress(7, 1_000))
        );
        drop(library);

        let library = scratch.library();
        assert_eq!(
            listed_progress(&library, &document.id),
            Some(progress(7, 1_000))
        );
    }

    #[test]
    fn saving_again_replaces_the_reading_progress_as_a_whole() {
        let scratch = Scratch::new();
        let library = scratch.library();
        let document = import_new(&library, &scratch.file("a.pdf", b"abc"));

        library
            .save_progress(&document.id, &progress(7, 1_000))
            .unwrap();
        library
            .save_progress(&document.id, &progress(2, 2_000))
            .unwrap();

        assert_eq!(
            listed_progress(&library, &document.id),
            Some(progress(2, 2_000))
        );
    }

    #[test]
    fn the_state_and_progress_files_do_not_hide_the_file() {
        let scratch = Scratch::new();
        let library = scratch.library();
        let document = import_new(&library, &scratch.file("a.pdf", b"abc"));
        library
            .save_progress(&document.id, &progress(1, 1))
            .unwrap();
        highlight(&library, &document.id, "the passage", 1);

        let listed = library.documents().unwrap();

        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].path, document.path);
    }

    #[test]
    fn the_state_is_a_hidden_automerge_document_with_schema_version_2() {
        use automerge::{ROOT, ReadDoc};
        let scratch = Scratch::new();
        let library = scratch.library();
        let document = import_new(&library, &scratch.file("a.pdf", b"abc"));
        highlight(&library, &document.id, "the passage", 1);

        let folder = document.path.parent().unwrap();
        let hidden: Vec<_> = fs::read_dir(folder)
            .unwrap()
            .map(|e| e.unwrap().path())
            .filter(|p| p != &document.path)
            .collect();
        assert_eq!(hidden.len(), 1);
        assert!(
            hidden[0]
                .file_name()
                .unwrap()
                .to_string_lossy()
                .starts_with('.')
        );
        let state = automerge::AutoCommit::load(&fs::read(&hidden[0]).unwrap()).unwrap();
        let (version, _) = state.get(ROOT, "version").unwrap().unwrap();
        assert_eq!(version.as_u64(), Some(2));
    }

    #[test]
    fn saving_leaves_nothing_in_staging() {
        let scratch = Scratch::new();
        let library = scratch.library();
        let document = import_new(&library, &scratch.file("a.pdf", b"abc"));

        library
            .save_progress(&document.id, &progress(1, 1))
            .unwrap();

        let staging = scratch.0.join("library/.staging");
        assert_eq!(fs::read_dir(staging).unwrap().count(), 0);
    }

    #[test]
    fn saving_for_an_unknown_document_does_nothing_and_creates_no_folder() {
        let scratch = Scratch::new();
        let library = scratch.library();

        library.save_progress("0123", &progress(1, 1)).unwrap();

        assert!(!scratch.0.join("library/0123").exists());
        assert_eq!(library.documents().unwrap(), vec![]);
    }

    fn details(title: Option<&str>, author: Option<&str>, page_count: u32) -> Details {
        Details {
            title: title.map(str::to_owned),
            author: author.map(str::to_owned),
            size: Size::Pages(page_count),
        }
    }

    #[test]
    fn a_document_has_no_details_until_set_and_keeps_them_after_reopening() {
        let scratch = Scratch::new();
        let library = scratch.library();
        let document = import_new(&library, &scratch.file("a.pdf", b"abc"));
        assert_eq!(document.details, None);

        let moby = details(Some("Moby-Dick"), Some("Melville"), 635);
        library.set_details(&document.id, &moby).unwrap();

        assert_eq!(library.documents().unwrap()[0].details, Some(moby.clone()));
        let reopened = scratch.library();
        assert_eq!(reopened.documents().unwrap()[0].details, Some(moby));
    }

    #[test]
    fn details_are_kept_as_stored() {
        let scratch = Scratch::new();
        let library = scratch.library();
        let document = import_new(&library, &scratch.file("a.pdf", b"abc"));

        library
            .set_details(&document.id, &details(Some(" "), Some(" Melville\n"), 3))
            .unwrap();

        let stored = library.document(&document.id).unwrap().unwrap().details;
        assert_eq!(stored, Some(details(None, Some("Melville"), 3)));
    }

    #[test]
    fn details_of_a_removed_document_are_gone_and_not_written() {
        let scratch = Scratch::new();
        let library = scratch.library();
        let source = scratch.file("a.pdf", b"abc");
        let document = import_new(&library, &source);
        let moby = details(Some("Moby-Dick"), None, 1);
        library.set_details(&document.id, &moby).unwrap();
        library.remove(&document.id).unwrap();

        library.set_details(&document.id, &moby).unwrap();

        assert!(!scratch.0.join("library").join(&document.id).exists());
        assert_eq!(import_new(&library, &source).details, None);
    }

    #[test]
    fn details_read_back_as_stored_and_a_reimport_has_no_stale_ones() {
        let scratch = Scratch::new();
        let library = scratch.library();
        let source = scratch.file("a.pdf", b"abc");
        let document = import_new(&library, &source);
        let first = details(Some("Moby-Dick"), None, 1);
        let second = details(Some("Dracula"), Some("Stoker"), 2);
        library.set_details(&document.id, &first).unwrap();
        assert_eq!(library.documents().unwrap()[0].details, Some(first));
        library.set_details(&document.id, &second).unwrap();
        for _ in 0..2 {
            assert_eq!(
                library.documents().unwrap()[0].details,
                Some(second.clone())
            );
        }

        library.remove(&document.id).unwrap();
        assert!(library.documents().unwrap().is_empty());
        let again = import_new(&library, &source);
        assert_eq!(again.details, None);
        assert_eq!(library.documents().unwrap()[0].details, None);
    }

    #[test]
    fn small_libraries_list_on_one_thread_and_large_ones_in_big_chunks() {
        assert_eq!(chunk_size(0, 8), MIN_PER_THREAD);
        assert_eq!(chunk_size(31, 8), MIN_PER_THREAD);
        assert_eq!(chunk_size(100, 8), MIN_PER_THREAD);
        assert_eq!(chunk_size(1000, 8), 125);
        assert_eq!(chunk_size(1000, 1), 1000);
    }

    #[test]
    fn setting_details_refuses_an_id_that_points_outside_the_library() {
        let scratch = Scratch::new();
        let library = scratch.library();
        for id in ["../x", "/tmp", "", ".staging"] {
            let err = library
                .set_details(id, &details(None, None, 1))
                .unwrap_err();
            assert_eq!(err.kind(), io::ErrorKind::InvalidInput, "{id:?}");
        }
    }

    #[test]
    fn the_title_is_the_stored_one_or_else_the_file_name_without_extension() {
        let scratch = Scratch::new();
        let library = scratch.library();
        let document = import_new(&library, &scratch.file("scan0042.pdf", b"abc"));
        assert_eq!(document.title(), "scan0042");

        library
            .set_details(&document.id, &details(None, Some("Melville"), 1))
            .unwrap();
        assert_eq!(library.documents().unwrap()[0].title(), "scan0042");

        library
            .set_details(&document.id, &details(Some("Moby-Dick"), None, 1))
            .unwrap();
        assert_eq!(library.documents().unwrap()[0].title(), "Moby-Dick");
    }

    #[test]
    fn percent_read_is_the_page_reached_of_the_page_count_rounded_down() {
        let document = |page_index, page_count| Document {
            id: String::new(),
            path: PathBuf::from("a.pdf"),
            imported: 0,
            progress: Some(progress(page_index, 1)),
            details: Some(details(None, None, page_count)),
        };
        for (page_index, page_count, percent) in [
            (0, 4, 25),
            (3, 4, 100),
            (1, 3, 66),
            (0, 200, 0),
            (9, 4, 100),
        ] {
            let read = document(page_index, page_count).percent_read();
            assert_eq!(read, Some(percent), "page {page_index} of {page_count}");
        }
        assert_eq!(document(0, 0).percent_read(), None, "no pages");
        let never_opened = Document {
            progress: None,
            ..document(0, 4)
        };
        assert_eq!(never_opened.percent_read(), None);
        let unknown_page_count = Document {
            details: None,
            ..document(0, 4)
        };
        assert_eq!(unknown_page_count.percent_read(), None);
    }

    #[test]
    fn epub_reading_progress_is_saved_listed_and_survives_reopening_the_library() {
        let scratch = Scratch::new();
        let library = scratch.library();
        let document = import_new(&library, &scratch.file("book.epub", &emma().bytes()));
        assert_eq!(document.progress, None);

        library
            .save_progress(&document.id, &ReadingProgress::epub(1, 3, 1_000))
            .unwrap();
        library
            .save_progress(&document.id, &ReadingProgress::epub(1, 4, 2_000))
            .unwrap();

        for library in [&library, &scratch.library()] {
            let listed = listed_progress(library, &document.id);
            assert_eq!(listed, Some(ReadingProgress::epub(1, 4, 2_000)));
        }
    }

    #[test]
    fn percent_read_of_an_epub_is_the_characters_reached_of_all_rounded_down() {
        let document = |spine_index, offset| Document {
            id: String::new(),
            path: PathBuf::from("a.epub"),
            imported: 0,
            progress: Some(ReadingProgress::epub(spine_index, offset, 1)),
            details: Some(Details {
                title: None,
                author: None,
                size: Size::Characters(vec![30, 60, 10]),
            }),
        };
        // The characters before the item count too, and only what is read.
        for (spine_index, offset, percent) in [
            (0, 0, 0),
            (0, 29, 29),
            (1, 0, 30),
            (1, 30, 60),
            (2, 5, 95),
            (2, 10, 100),
            (2, 99, 100),
            (9, 0, 100),
        ] {
            let read = document(spine_index, offset).percent_read();
            assert_eq!(read, Some(percent), "item {spine_index}, offset {offset}");
        }
        let pdf_progress = Document {
            progress: Some(progress(0, 1)),
            ..document(0, 0)
        };
        assert_eq!(pdf_progress.percent_read(), None, "another Format's place");
        let empty = Document {
            details: Some(Details {
                size: Size::Characters(vec![0]),
                ..document(0, 0).details.unwrap()
            }),
            ..document(0, 0)
        };
        assert_eq!(empty.percent_read(), None, "no text");
    }

    #[test]
    fn a_document_is_found_by_id_while_it_is_in_the_library() {
        let scratch = Scratch::new();
        let library = scratch.library();
        let document = import_new(&library, &scratch.file("a.pdf", b"abc"));
        library
            .save_progress(&document.id, &progress(1, 1))
            .unwrap();

        let found = library.document(&document.id).unwrap();
        assert_eq!(found, Some(library.documents().unwrap().remove(0)));

        library.remove(&document.id).unwrap();
        assert_eq!(library.document(&document.id).unwrap(), None);
        assert_eq!(
            library.document("../x").unwrap_err().kind(),
            io::ErrorKind::InvalidInput
        );
    }

    #[test]
    fn saving_for_a_removed_document_does_nothing() {
        let scratch = Scratch::new();
        let library = scratch.library();
        let document = import_new(&library, &scratch.file("a.pdf", b"abc"));
        library.remove(&document.id).unwrap();

        library
            .save_progress(&document.id, &progress(1, 1))
            .unwrap();

        assert!(!scratch.0.join("library").join(&document.id).exists());
    }

    #[test]
    fn saving_refuses_an_id_that_points_outside_the_library() {
        let scratch = Scratch::new();
        let library = scratch.library();

        for id in ["../outside", "", ".staging", "a/b"] {
            let err = library.save_progress(id, &progress(1, 1)).unwrap_err();
            assert_eq!(err.kind(), io::ErrorKind::InvalidInput, "id {id:?}");
        }
    }

    #[test]
    fn remove_deletes_the_state_along_with_the_file() {
        let scratch = Scratch::new();
        let library = scratch.library();
        let document = import_new(&library, &scratch.file("a.pdf", b"abc"));
        library
            .save_progress(&document.id, &progress(3, 5))
            .unwrap();

        library.remove(&document.id).unwrap();
        assert_eq!(library.documents().unwrap(), vec![]);

        // Imported again, the Document is as good as new.
        let again = import_new(&library, &scratch.file("a.pdf", b"abc"));
        assert_eq!(again.progress, None);
    }

    #[test]
    fn a_corrupt_progress_file_lists_as_never_opened_and_is_replaced_by_the_next_save() {
        let scratch = Scratch::new();
        let library = scratch.library();
        let document = import_new(&library, &scratch.file("a.pdf", b"abc"));
        library
            .save_progress(&document.id, &progress(3, 5))
            .unwrap();
        fs::write(first_progress_path(&library, &document.id), b"garbage").unwrap();

        assert_eq!(listed_progress(&scratch.library(), &document.id), None);

        library
            .save_progress(&document.id, &progress(4, 6))
            .unwrap();
        assert_eq!(
            listed_progress(&library, &document.id),
            Some(progress(4, 6))
        );
    }

    #[test]
    fn reading_progress_in_an_older_state_is_read_until_the_document_has_its_own() {
        let scratch = Scratch::new();
        let library = scratch.library();
        let document = import_new(&library, &scratch.file("a.pdf", b"abc"));
        fs::write(
            state_path(&library, &document),
            stored_progress(&progress(9, 2_000)),
        )
        .unwrap();
        assert_eq!(
            listed_progress(&scratch.library(), &document.id),
            Some(progress(9, 2_000))
        );

        library
            .save_progress(&document.id, &progress(1, 1_500))
            .unwrap();

        for library in [library, scratch.library()] {
            assert_eq!(
                listed_progress(&library, &document.id),
                Some(progress(1, 1_500))
            );
        }
    }

    #[test]
    fn a_state_file_without_progress_lists_as_never_opened() {
        let scratch = Scratch::new();
        let library = scratch.library();
        let document = import_new(&library, &scratch.file("a.pdf", b"abc"));
        let empty = automerge::AutoCommit::new().save();
        fs::write(state_path(&library, &document), empty).unwrap();

        assert_eq!(listed_progress(&library, &document.id), None);
    }

    fn anchor() -> Anchor {
        Anchor::Pdf(vec![
            PageRects {
                page_index: 2,
                rects: vec![Rect {
                    x: 72.0,
                    y: 700.5,
                    width: 200.0,
                    height: 12.0,
                }],
            },
            PageRects {
                page_index: 3,
                rects: vec![
                    Rect {
                        x: 72.0,
                        y: 720.0,
                        width: 100.0,
                        height: 12.0,
                    },
                    Rect {
                        x: 72.0,
                        y: 706.0,
                        width: 40.0,
                        height: 12.0,
                    },
                ],
            },
        ])
    }

    fn epub_anchor(start: (u32, u64), end: (u32, u64)) -> Anchor {
        let position = |(spine_index, offset)| EpubPosition {
            spine_index,
            offset,
        };
        Anchor::Epub {
            start: position(start),
            end: position(end),
        }
    }

    /// An imported EPUB whose chapters read "Call me Ishmael. 😀 Ishmael" and
    /// "Some years ago", in a Library of its own.
    fn moby(scratch: &Scratch) -> (Library, Document) {
        let library = scratch.library();
        let book = Book::new("").chapters(&[
            "<p>Call me Ishmael.</p><p> \u{1F600} Ishmael</p>",
            "<p>Some years ago</p>",
        ]);
        let document = import_new(&library, &scratch.file("moby.epub", &book.bytes()));
        (library, document)
    }

    #[test]
    fn an_epub_highlight_is_stored_with_its_positions_and_quoted_text_and_survives_reopening() {
        let scratch = Scratch::new();
        let (library, document) = moby(&scratch);

        let added = library
            .add_highlight(
                &document.id,
                epub_anchor((0, 8), (1, 4)),
                "Ishmael. \u{1F600} Ishmael\nSome",
                YELLOW,
                7,
            )
            .unwrap()
            .unwrap();
        library
            .set_highlight_note(&document.id, &added.id, "whale")
            .unwrap();

        let reopened = scratch.library();
        let stored = reopened.markup(&document.id).unwrap().highlights;
        assert_eq!(stored.len(), 1);
        assert_eq!(stored[0].anchor, epub_anchor((0, 8), (1, 4)));
        assert_eq!(stored[0].quoted_text, "Ishmael. \u{1F600} Ishmael\nSome");
        assert_eq!(stored[0].note.as_deref(), Some("whale"));
        assert_eq!(stored[0].created, 7);
    }

    #[test]
    fn overlapping_epub_highlights_stay_separate() {
        let scratch = Scratch::new();
        let (library, document) = moby(&scratch);
        let add = |start, end, quoted: &str| {
            library
                .add_highlight(&document.id, epub_anchor(start, end), quoted, YELLOW, 1)
                .unwrap()
                .unwrap()
        };
        let (first, second) = (
            add((0, 0), (0, 7), "Call me"),
            add((0, 5), (0, 15), "e Ishmael"),
        );

        library.remove_highlight(&document.id, &first.id).unwrap();

        let left = library.markup(&document.id).unwrap().highlights;
        assert_eq!(left, vec![second]);
    }

    /// Where EPUB `document` of `library` says the passage `quoted` really is.
    fn relocated(
        library: &Library,
        document: &Document,
        anchor: Anchor,
        quoted: &str,
    ) -> Option<Anchor> {
        let Anchor::Epub { start, end } = anchor else {
            panic!("an EPUB anchor");
        };
        let (start, end) = library
            .open_epub(&document.id)
            .unwrap()
            .unwrap()
            .relocate(start, end, quoted)?;
        Some(Anchor::Epub { start, end })
    }

    #[test]
    fn an_epub_highlight_that_still_matches_its_text_stays_where_it_is() {
        let scratch = Scratch::new();
        let (library, document) = moby(&scratch);
        let anchor = epub_anchor((0, 8), (1, 4));
        let quoted = "Ishmael. \u{1F600} Ishmael\nSome";

        assert_eq!(
            relocated(&library, &document, anchor.clone(), quoted),
            Some(anchor)
        );
    }

    #[test]
    fn an_epub_highlight_whose_offsets_no_longer_match_is_found_by_its_quoted_text() {
        let scratch = Scratch::new();
        let (library, document) = moby(&scratch);
        let found = |anchor, quoted| relocated(&library, &document, anchor, quoted);

        // Within one spine item, in UTF-16 offsets (the emoji counts two).
        assert_eq!(
            found(epub_anchor((0, 0), (0, 3)), "Ishmael."),
            Some(epub_anchor((0, 8), (0, 16)))
        );
        // Across spine items.
        assert_eq!(
            found(epub_anchor((1, 99), (1, 99)), "Ishmael\nSome"),
            Some(epub_anchor((0, 20), (1, 4)))
        );
        // Of several occurrences, the one nearest to where it was.
        assert_eq!(
            found(epub_anchor((0, 17), (0, 24)), "Ishmael"),
            Some(epub_anchor((0, 20), (0, 27)))
        );
        assert_eq!(
            found(epub_anchor((0, 1), (0, 8)), "Ishmael"),
            Some(epub_anchor((0, 8), (0, 15)))
        );
    }

    #[test]
    fn an_epub_highlight_whose_text_is_nowhere_is_not_found() {
        let scratch = Scratch::new();
        let (library, document) = moby(&scratch);

        assert_eq!(
            relocated(
                &library,
                &document,
                epub_anchor((0, 8), (0, 15)),
                "Queequeg"
            ),
            None
        );
        assert_eq!(
            relocated(&library, &document, epub_anchor((0, 8), (0, 15)), ""),
            None
        );
    }

    const YELLOW: Rgb = Rgb {
        r: 255,
        g: 235,
        b: 60,
    };

    fn highlight(library: &Library, id: &str, quoted_text: &str, created: u64) -> Highlight {
        library
            .add_highlight(id, anchor(), quoted_text, YELLOW, created)
            .unwrap()
            .unwrap()
    }

    #[test]
    fn a_document_without_markup_has_no_highlights() {
        let scratch = Scratch::new();
        let library = scratch.library();
        let document = import_new(&library, &scratch.file("a.pdf", b"abc"));
        assert_eq!(library.markup(&document.id).unwrap(), Markup::default());
    }

    #[test]
    fn an_added_highlight_is_in_the_markup_and_survives_reopening_the_library() {
        let scratch = Scratch::new();
        let library = scratch.library();
        let document = import_new(&library, &scratch.file("a.pdf", b"abc"));

        let added = highlight(&library, &document.id, "the passage", 1_000);

        assert_eq!(added.anchor, anchor());
        assert_eq!(added.quoted_text, "the passage");
        assert_eq!(added.color, YELLOW);
        assert_eq!(added.created, 1_000);
        let expected = Markup {
            highlights: vec![added],
            ..Markup::default()
        };
        assert_eq!(library.markup(&document.id).unwrap(), expected);
        drop(library);
        assert_eq!(scratch.library().markup(&document.id).unwrap(), expected);
    }

    #[test]
    fn every_highlight_gets_its_own_id_and_the_markup_lists_them_oldest_first() {
        let scratch = Scratch::new();
        let library = scratch.library();
        let document = import_new(&library, &scratch.file("a.pdf", b"abc"));

        let later = highlight(&library, &document.id, "later", 2_000);
        let earlier = highlight(&library, &document.id, "earlier", 1_000);

        assert_ne!(earlier.id, later.id);
        assert_eq!(
            library.markup(&document.id).unwrap().highlights,
            vec![earlier, later]
        );
    }

    #[test]
    fn markup_and_reading_progress_are_kept_side_by_side() {
        let scratch = Scratch::new();
        let library = scratch.library();
        let document = import_new(&library, &scratch.file("a.pdf", b"abc"));

        library
            .save_progress(&document.id, &progress(7, 1_000))
            .unwrap();
        highlight(&library, &document.id, "the passage", 1_000);
        library
            .save_progress(&document.id, &progress(8, 2_000))
            .unwrap();

        assert_eq!(
            listed_progress(&library, &document.id),
            Some(progress(8, 2_000))
        );
        assert_eq!(library.markup(&document.id).unwrap().highlights.len(), 1);
    }

    #[test]
    fn a_state_of_schema_version_1_keeps_its_progress_and_is_upgraded_by_a_highlight() {
        use automerge::{AutoCommit, ROOT, ReadDoc, transaction::Transactable};
        let scratch = Scratch::new();
        let library = scratch.library();
        let document = import_new(&library, &scratch.file("a.pdf", b"abc"));
        let state = state_path(&library, &document);
        let mut v1 = AutoCommit::load(&stored_progress(&progress(7, 1_000))).unwrap();
        v1.put(ROOT, "version", 1_u64).unwrap();
        fs::write(&state, v1.save()).unwrap();

        assert_eq!(library.markup(&document.id).unwrap(), Markup::default());
        highlight(&library, &document.id, "the passage", 1_000);

        assert_eq!(
            listed_progress(&scratch.library(), &document.id),
            Some(progress(7, 1_000))
        );
        let upgraded = AutoCommit::load(&fs::read(&state).unwrap()).unwrap();
        let (version, _) = upgraded.get(ROOT, "version").unwrap().unwrap();
        assert_eq!(version.as_u64(), Some(2));
    }

    #[test]
    fn remove_takes_the_markup_along() {
        let scratch = Scratch::new();
        let library = scratch.library();
        let source = scratch.file("a.pdf", b"abc");
        let document = import_new(&library, &source);
        highlight(&library, &document.id, "the passage", 1_000);

        library.remove(&document.id).unwrap();
        import_new(&library, &source);

        assert_eq!(library.markup(&document.id).unwrap(), Markup::default());
    }

    const GREEN: Rgb = Rgb { r: 0, g: 200, b: 0 };

    #[test]
    fn a_recolored_highlight_keeps_its_color_after_reopening_the_library() {
        let scratch = Scratch::new();
        let library = scratch.library();
        let document = import_new(&library, &scratch.file("a.pdf", b"abc"));
        let first = highlight(&library, &document.id, "first", 1_000);
        let second = highlight(&library, &document.id, "second", 2_000);

        library
            .set_highlight_color(&document.id, &first.id, GREEN)
            .unwrap();

        let expected = vec![
            Highlight {
                color: GREEN,
                ..first
            },
            second,
        ];
        assert_eq!(library.markup(&document.id).unwrap().highlights, expected);
        let reopened = scratch.library();
        assert_eq!(reopened.markup(&document.id).unwrap().highlights, expected);
    }

    #[test]
    fn a_note_survives_reopening_the_library_and_emptying_it_removes_it() {
        let scratch = Scratch::new();
        let library = scratch.library();
        let document = import_new(&library, &scratch.file("a.pdf", b"abc"));
        let added = highlight(&library, &document.id, "first", 1_000);

        library
            .set_highlight_note(&document.id, &added.id, "my thought")
            .unwrap();

        let reopened = scratch.library();
        let markup = reopened.markup(&document.id).unwrap();
        assert_eq!(markup.highlights[0].note.as_deref(), Some("my thought"));

        reopened
            .set_highlight_note(&document.id, &added.id, "")
            .unwrap();
        assert_eq!(
            scratch.library().markup(&document.id).unwrap().highlights,
            vec![added]
        );
    }

    #[test]
    fn removing_a_highlight_removes_its_note() {
        let scratch = Scratch::new();
        let library = scratch.library();
        let document = import_new(&library, &scratch.file("a.pdf", b"abc"));
        let added = highlight(&library, &document.id, "first", 1_000);
        library
            .set_highlight_note(&document.id, &added.id, "x")
            .unwrap();

        library.remove_highlight(&document.id, &added.id).unwrap();

        assert_eq!(library.markup(&document.id).unwrap(), Markup::default());
    }

    #[test]
    fn a_removed_highlight_is_gone_after_reopening_the_library() {
        let scratch = Scratch::new();
        let library = scratch.library();
        let document = import_new(&library, &scratch.file("a.pdf", b"abc"));
        let first = highlight(&library, &document.id, "first", 1_000);
        let second = highlight(&library, &document.id, "second", 2_000);

        library.remove_highlight(&document.id, &first.id).unwrap();

        let reopened = scratch.library();
        assert_eq!(
            reopened.markup(&document.id).unwrap().highlights,
            vec![second]
        );
    }

    fn pdf_spot(page_index: u32, x: f64, y: f64) -> Place {
        Place::Pdf { page_index, x, y }
    }

    #[test]
    fn a_page_note_survives_reopening_the_library_and_emptying_it_removes_it() {
        let scratch = Scratch::new();
        let library = scratch.library();
        let document = import_new(&library, &scratch.file("a.pdf", b"abc"));

        let added = library
            .add_page_note(&document.id, pdf_spot(4, 100.5, 200.5), 1_000)
            .unwrap()
            .unwrap();
        assert_eq!(library.markup(&document.id).unwrap(), Markup::default());
        library
            .set_page_note_text(&document.id, &added.id, "my thought")
            .unwrap();

        let reopened = scratch.library();
        let expected = PageNote {
            text: "my thought".to_owned(),
            ..added.clone()
        };
        assert_eq!(
            reopened.markup(&document.id).unwrap().page_notes,
            vec![expected]
        );
        assert_eq!(added.place, pdf_spot(4, 100.5, 200.5));
        assert_eq!(added.created, 1_000);

        reopened
            .set_page_note_text(&document.id, &added.id, "")
            .unwrap();
        assert_eq!(
            scratch.library().markup(&document.id).unwrap(),
            Markup::default()
        );
    }

    #[test]
    fn an_epub_page_note_is_stored_with_its_spot_and_survives_reopening() {
        let scratch = Scratch::new();
        let (library, document) = moby(&scratch);
        let spot = Place::Epub {
            spine_index: 1,
            offset: 5,
        };

        let added = library
            .add_page_note(&document.id, spot, 1_000)
            .unwrap()
            .unwrap();
        assert_eq!(added.place, spot);
        library
            .set_page_note_text(&document.id, &added.id, "years")
            .unwrap();

        let expected = PageNote {
            text: "years".to_owned(),
            ..added
        };
        assert_eq!(
            scratch.library().markup(&document.id).unwrap().page_notes,
            vec![expected]
        );
    }

    #[test]
    fn a_removed_page_note_is_gone_after_reopening_the_library() {
        let scratch = Scratch::new();
        let library = scratch.library();
        let document = import_new(&library, &scratch.file("a.pdf", b"abc"));
        let first = library
            .add_page_note(&document.id, pdf_spot(0, 1.0, 2.0), 1)
            .unwrap()
            .unwrap();
        let second = library
            .add_page_note(&document.id, pdf_spot(1, 3.0, 4.0), 2)
            .unwrap()
            .unwrap();
        for note in [&first, &second] {
            library
                .set_page_note_text(&document.id, &note.id, "x")
                .unwrap();
        }

        library.remove_page_note(&document.id, &first.id).unwrap();

        let ids: Vec<_> = scratch
            .library()
            .markup(&document.id)
            .unwrap()
            .page_notes
            .into_iter()
            .map(|n| n.id)
            .collect();
        assert_eq!(ids, [second.id]);
    }

    #[test]
    fn changing_or_removing_an_unknown_page_note_does_nothing() {
        let scratch = Scratch::new();
        let library = scratch.library();
        let document = import_new(&library, &scratch.file("a.pdf", b"abc"));
        let added = library
            .add_page_note(&document.id, pdf_spot(0, 1.0, 2.0), 1)
            .unwrap()
            .unwrap();
        library
            .set_page_note_text(&document.id, &added.id, "x")
            .unwrap();

        library
            .set_page_note_text(&document.id, "nope", "y")
            .unwrap();
        library.remove_page_note(&document.id, "nope").unwrap();

        assert_eq!(library.markup(&document.id).unwrap().page_notes.len(), 1);
    }

    #[test]
    fn remove_takes_page_notes_along() {
        let scratch = Scratch::new();
        let library = scratch.library();
        let document = import_new(&library, &scratch.file("a.pdf", b"abc"));
        let added = library
            .add_page_note(&document.id, pdf_spot(0, 1.0, 2.0), 1)
            .unwrap()
            .unwrap();
        library
            .set_page_note_text(&document.id, &added.id, "x")
            .unwrap();

        library.remove(&document.id).unwrap();

        assert_eq!(library.markup(&document.id).unwrap(), Markup::default());
    }

    #[test]
    fn changing_or_removing_an_unknown_highlight_does_nothing() {
        let scratch = Scratch::new();
        let library = scratch.library();
        let document = import_new(&library, &scratch.file("a.pdf", b"abc"));
        let added = highlight(&library, &document.id, "first", 1_000);

        library
            .set_highlight_color(&document.id, "nope", GREEN)
            .unwrap();
        library
            .set_highlight_note(&document.id, "nope", "x")
            .unwrap();
        library.remove_highlight(&document.id, "nope").unwrap();

        assert_eq!(
            library.markup(&document.id).unwrap().highlights,
            vec![added]
        );
    }

    #[test]
    fn editing_highlights_of_a_document_that_is_not_there_does_nothing() {
        let scratch = Scratch::new();
        let library = scratch.library();
        library.set_highlight_color("0123", "a", GREEN).unwrap();
        library.set_highlight_note("0123", "a", "x").unwrap();
        library.remove_highlight("0123", "a").unwrap();
        assert!(!scratch.0.join("library/0123").exists());
    }

    #[test]
    fn editing_highlights_refuses_an_id_that_points_outside_the_library() {
        let scratch = Scratch::new();
        let library = scratch.library();
        for id in ["../x", "/tmp", "", ".staging"] {
            let err = library.set_highlight_color(id, "a", GREEN).unwrap_err();
            assert_eq!(err.kind(), io::ErrorKind::InvalidInput, "{id:?}");
            let err = library.set_highlight_note(id, "a", "x").unwrap_err();
            assert_eq!(err.kind(), io::ErrorKind::InvalidInput, "{id:?}");
            let err = library.remove_highlight(id, "a").unwrap_err();
            assert_eq!(err.kind(), io::ErrorKind::InvalidInput, "{id:?}");
        }
    }

    #[test]
    fn highlighting_in_a_document_that_is_not_there_adds_nothing() {
        let scratch = Scratch::new();
        let library = scratch.library();
        let added = library
            .add_highlight("0123", anchor(), "x", YELLOW, 1)
            .unwrap();
        assert_eq!(added, None);
        assert_eq!(library.markup("0123").unwrap(), Markup::default());
        assert!(!scratch.0.join("library/0123").exists());
    }

    #[test]
    fn adding_a_page_note_to_a_removed_document_adds_nothing() {
        let scratch = Scratch::new();
        let library = scratch.library();
        let document = import_new(&library, &scratch.file("a.pdf", b"abc"));
        library.remove(&document.id).unwrap();

        let added = library
            .add_page_note(&document.id, pdf_spot(0, 1.0, 2.0), 1)
            .unwrap();

        assert_eq!(added, None);
        assert!(!scratch.0.join("library").join(&document.id).exists());
    }

    #[test]
    fn markup_refuses_an_id_that_points_outside_the_library() {
        let scratch = Scratch::new();
        let library = scratch.library();
        for id in ["../x", "/tmp", "", ".staging"] {
            let err = library.markup(id).unwrap_err();
            assert_eq!(err.kind(), io::ErrorKind::InvalidInput, "{id:?}");
            let err = library
                .add_highlight(id, anchor(), "x", YELLOW, 1)
                .unwrap_err();
            assert_eq!(err.kind(), io::ErrorKind::InvalidInput, "{id:?}");
        }
    }

    #[test]
    fn a_corrupt_state_has_no_markup_and_is_replaced_by_the_next_highlight() {
        let scratch = Scratch::new();
        let library = scratch.library();
        let document = import_new(&library, &scratch.file("a.pdf", b"abc"));
        let state = state_path(&library, &document);
        fs::write(&state, b"garbage").unwrap();
        assert_eq!(library.markup(&document.id).unwrap(), Markup::default());

        let added = highlight(&library, &document.id, "the passage", 1_000);

        assert_eq!(
            library.markup(&document.id).unwrap().highlights,
            vec![added]
        );
    }

    #[test]
    fn the_highlight_colors_are_the_six_built_in_ones_yellow_first() {
        let scratch = Scratch::new();
        let names: Vec<_> = scratch
            .library()
            .highlight_colors()
            .colors
            .into_iter()
            .map(|c| c.id)
            .collect();
        assert_eq!(names, ["Yellow", "Green", "Blue", "Pink", "Purple", "Red"]);
    }

    #[test]
    fn the_default_highlight_color_is_yellow_until_set() {
        let scratch = Scratch::new();
        let library = scratch.library();
        assert_eq!(library.highlight_colors().default_color.id, "Yellow");
    }

    #[test]
    fn the_default_highlight_color_survives_reopening_the_library() {
        let scratch = Scratch::new();
        let library = scratch.library();

        library.set_default_highlight_color("Purple").unwrap();
        assert_eq!(library.highlight_colors().default_color.id, "Purple");
        drop(library);

        let library = scratch.library();
        let HighlightColors {
            colors,
            default_color: purple,
        } = library.highlight_colors();
        assert_eq!(purple.id, "Purple");
        assert_eq!(purple, colors[4]);
        library.set_default_highlight_color("Yellow").unwrap();
        assert_eq!(
            scratch.library().highlight_colors().default_color.id,
            "Yellow"
        );
    }

    #[test]
    fn setting_an_unknown_default_highlight_color_is_invalid_input() {
        let scratch = Scratch::new();
        let library = scratch.library();
        library.set_default_highlight_color("Green").unwrap();

        let err = library.set_default_highlight_color("Teal").unwrap_err();

        assert_eq!(err.kind(), io::ErrorKind::InvalidInput);
        assert_eq!(library.highlight_colors().default_color.id, "Green");
    }

    const TEAL: Rgb = Rgb {
        r: 0,
        g: 128,
        b: 128,
    };

    #[test]
    fn a_custom_color_is_listed_after_the_built_in_ones_and_survives_reopening() {
        let scratch = Scratch::new();
        let library = scratch.library();

        let teal = library.add_custom_color(TEAL, 100).unwrap();
        let brown = library
            .add_custom_color(
                Rgb {
                    r: 150,
                    g: 75,
                    b: 0,
                },
                200,
            )
            .unwrap();

        assert!(teal.is_custom && teal.rgb == TEAL);
        drop(library);
        assert_eq!(
            scratch.library().highlight_colors().colors[6..],
            [teal, brown]
        );
    }

    #[test]
    fn there_is_no_limit_to_custom_colors() {
        let scratch = Scratch::new();
        let library = scratch.library();
        for n in 0..50 {
            library
                .add_custom_color(Rgb { r: n, g: 0, b: 0 }, 1)
                .unwrap();
        }
        assert_eq!(library.highlight_colors().colors.len(), 6 + 50);
    }

    #[test]
    fn a_custom_color_can_be_the_default_highlight_color_and_survives_reopening() {
        let scratch = Scratch::new();
        let library = scratch.library();
        let teal = library.add_custom_color(TEAL, 100).unwrap();

        library.set_default_highlight_color(&teal.id).unwrap();

        assert_eq!(scratch.library().highlight_colors().default_color, teal);
    }

    #[test]
    fn removing_a_custom_color_makes_yellow_the_default_again() {
        let scratch = Scratch::new();
        let library = scratch.library();
        let teal = library.add_custom_color(TEAL, 100).unwrap();
        library.set_default_highlight_color(&teal.id).unwrap();

        library.remove_custom_color(&teal.id).unwrap();

        let after = library.highlight_colors();
        assert_eq!(after.colors.len(), 6);
        assert_eq!(after.default_color.id, "Yellow");
        let err = library.set_default_highlight_color(&teal.id).unwrap_err();
        assert_eq!(err.kind(), io::ErrorKind::InvalidInput);
    }

    #[test]
    fn built_in_colors_cannot_be_removed() {
        let scratch = Scratch::new();
        let library = scratch.library();

        library.remove_custom_color("Yellow").unwrap();

        assert_eq!(library.highlight_colors().colors.len(), 6);
        assert_eq!(library.highlight_colors().colors[0].id, "Yellow");
    }

    #[test]
    fn a_highlight_keeps_its_color_when_the_custom_color_is_removed() {
        let scratch = Scratch::new();
        let library = scratch.library();
        let document = import_new(&library, &scratch.file("a.pdf", b"abc"));
        let teal = library.add_custom_color(TEAL, 100).unwrap();
        let added = library
            .add_highlight(&document.id, Anchor::Pdf(vec![]), "x", teal.rgb, 1)
            .unwrap()
            .unwrap();

        library.remove_custom_color(&teal.id).unwrap();

        assert_eq!(
            library.markup(&document.id).unwrap().highlights,
            vec![added]
        );
    }

    #[test]
    fn corrupt_preferences_read_as_yellow_and_are_replaced_by_the_next_choice() {
        let scratch = Scratch::new();
        let library = scratch.library();
        fs::write(scratch.0.join("library").join(PREFERENCES), b"garbage").unwrap();
        let corrupt = library.highlight_colors();
        assert_eq!(corrupt.default_color.id, "Yellow");
        assert_eq!(corrupt.colors.len(), 6);

        library.set_default_highlight_color("Red").unwrap();

        assert_eq!(library.highlight_colors().default_color.id, "Red");
    }

    #[test]
    fn the_highlight_colors_and_the_default_come_together() {
        let scratch = Scratch::new();
        let library = scratch.library();
        let teal = library.add_custom_color(TEAL, 100).unwrap();
        library.set_default_highlight_color(&teal.id).unwrap();

        let both = library.highlight_colors();
        assert_eq!(both.colors.len(), 7);
        assert_eq!(both.colors[6], teal);
        assert_eq!(both.default_color, teal);

        library.remove_custom_color(&teal.id).unwrap();
        let both = library.highlight_colors();
        assert_eq!(both.colors.len(), 6);
        assert_eq!(both.default_color.id, "Yellow");
    }

    #[test]
    fn preferences_are_a_hidden_file_at_the_library_root_and_no_document() {
        let scratch = Scratch::new();
        let library = scratch.library();
        let document = import_new(&library, &scratch.file("a.pdf", b"abc"));

        library.set_default_highlight_color("Blue").unwrap();

        assert!(scratch.0.join("library/.preferences.automerge").is_file());
        assert_eq!(library.documents().unwrap(), vec![document]);
        assert_eq!(
            fs::read_dir(scratch.0.join("library/.staging"))
                .unwrap()
                .count(),
            0
        );
    }

    /// Every Automerge document stored under `dir`, the Library's own, the
    /// Preferences and the states.
    fn automerge_files(dir: &Path) -> Vec<PathBuf> {
        let mut found = Vec::new();
        for entry in fs::read_dir(dir).unwrap() {
            let path = entry.unwrap().path();
            if path.is_dir() {
                found.extend(automerge_files(&path));
            } else if path.extension().is_some_and(|e| e == "automerge") {
                found.push(path);
            }
        }
        found
    }

    /// The actors of all changes in the stored Automerge document `path`.
    fn actors_of(path: &Path) -> Vec<String> {
        let mut doc = AutoCommit::load(&fs::read(path).unwrap()).unwrap();
        let mut actors: Vec<_> = doc
            .get_changes(&[])
            .iter()
            .map(|c| c.actor_id().to_hex_string())
            .collect();
        actors.dedup();
        actors
    }

    fn assert_all_changes_are_by(scratch: &Scratch, device: &str) {
        let files = automerge_files(&scratch.0.join("library"));
        // The Library document, the Preferences and a state.
        assert!(files.len() >= 3, "{files:?}");
        for file in files {
            assert_eq!(actors_of(&file), [device], "{file:?}");
        }
    }

    #[test]
    fn the_device_id_is_generated_once_and_differs_between_libraries() {
        let one = Scratch::new();
        let other = Scratch::new();

        let id = one.library().device_id();

        assert_eq!(id.len(), 32);
        assert!(id.chars().all(|c| c.is_ascii_hexdigit()));
        assert_eq!(one.library().device_id(), id);
        assert_ne!(other.library().device_id(), id);
    }

    #[test]
    fn every_local_change_carries_the_device_id_as_actor_also_after_reopening() {
        let scratch = Scratch::new();
        let library = scratch.library();
        let device = library.device_id();
        let source = scratch.file("a.pdf", b"abc");
        let kept = import_new(&library, &source);
        let gone = import_new(&library, &scratch.file("b.pdf", b"def"));
        let work = |library: &Library| {
            library
                .save_progress(&kept.id, &progress(7, 1_000))
                .unwrap();
            let added = highlight(library, &kept.id, "the passage", 1);
            library
                .set_highlight_note(&kept.id, &added.id, "my thought")
                .unwrap();
            let note = library
                .add_page_note(&kept.id, pdf_spot(0, 1.0, 2.0), 1)
                .unwrap()
                .unwrap();
            library.set_page_note_text(&kept.id, &note.id, "x").unwrap();
            library.add_custom_color(TEAL, 100).unwrap();
            library.set_default_highlight_color("Green").unwrap();
        };
        work(&library);
        library.remove(&gone.id).unwrap();
        assert_all_changes_are_by(&scratch, &device);
        drop(library);

        let library = scratch.library();
        work(&library);
        library.remove(&kept.id).unwrap();
        import_new(&library, &source);
        highlight(&library, &kept.id, "again", 1);
        assert_eq!(library.device_id(), device);
        assert_all_changes_are_by(&scratch, &device);
    }

    /// A Document stored the way a Library without a Library document kept it:
    /// a folder with its File and the state next to it.
    fn legacy_document(
        scratch: &Scratch,
        id: &str,
        name: &str,
        progress: &ReadingProgress,
        highlight: &Highlight,
    ) {
        let folder = scratch.0.join("library").join(id);
        fs::create_dir_all(&folder).unwrap();
        fs::write(folder.join(name), id).unwrap();
        let state = state::update(None, &ActorId::random(), |doc| {
            progress::put_progress(doc, progress);
            markup::put_highlight(doc, highlight);
        });
        fs::write(folder.join(".state.automerge"), state).unwrap();
    }

    fn a_highlight(id: &str) -> Highlight {
        Highlight {
            id: id.to_owned(),
            anchor: anchor(),
            quoted_text: format!("passage {id}"),
            color: YELLOW,
            created: 1,
            note: None,
        }
    }

    #[test]
    fn an_existing_library_migrates_on_first_open_keeping_dates_progress_and_markup() {
        let scratch = Scratch::new();
        legacy_document(
            &scratch,
            "old",
            "old.pdf",
            &progress(3, 1_000),
            &a_highlight("h"),
        );
        sleep(Duration::from_millis(20));
        legacy_document(
            &scratch,
            "new",
            "new.pdf",
            &progress(5, 2_000),
            &a_highlight("i"),
        );

        for _ in 0..2 {
            let library = scratch.library();
            let documents = library.documents().unwrap();

            let ids: Vec<_> = documents.iter().map(|d| d.id.as_str()).collect();
            assert_eq!(ids, ["new", "old"]);
            assert_eq!(documents[0].progress, Some(progress(5, 2_000)));
            assert_eq!(documents[1].progress, Some(progress(3, 1_000)));
            assert_eq!(documents[1].path, scratch.0.join("library/old/old.pdf"));
            assert_eq!(
                library.markup("old").unwrap().highlights,
                vec![a_highlight("h")]
            );
            assert!(!scratch.0.join("library/old/.state.automerge").exists());
        }
        // A Document imported after the migration is the newest.
        let library = scratch.library();
        let fresh = import_new(&library, &scratch.file("c.pdf", b"c"));
        assert_eq!(library.documents().unwrap()[0], fresh);
    }

    #[test]
    fn a_state_left_behind_by_an_interrupted_migration_is_adopted_on_open() {
        let scratch = Scratch::new();
        legacy_document(
            &scratch,
            "old",
            "old.pdf",
            &progress(3, 1_000),
            &a_highlight("h"),
        );
        let library = scratch.library();
        // The Import was recorded, but the state wasn't moved yet.
        let folder = scratch.0.join("library/old");
        fs::rename(
            first_state_path(&library, "old"),
            folder.join(".state.automerge"),
        )
        .unwrap();
        drop(library);

        let library = scratch.library();

        assert_eq!(
            library.documents().unwrap()[0].progress,
            Some(progress(3, 1_000))
        );
    }

    #[test]
    fn a_re_imported_document_is_the_newest_again() {
        let scratch = Scratch::new();
        let library = scratch.library();
        let source = scratch.file("a.pdf", b"first");
        let first = import_new(&library, &source);
        sleep(Duration::from_millis(5));
        let second = import_new(&library, &scratch.file("b.pdf", b"second"));
        sleep(Duration::from_millis(5));
        library.remove(&first.id).unwrap();

        let again = import_new(&library, &source);

        assert_eq!(library.documents().unwrap(), vec![again, second]);
    }

    #[test]
    fn a_re_import_starts_fresh_even_if_the_old_state_was_never_deleted() {
        let scratch = Scratch::new();
        let library = scratch.library();
        let source = scratch.file("a.pdf", b"abc");
        let first = import_new(&library, &source);
        library.save_progress(&first.id, &progress(3, 5)).unwrap();
        highlight(&library, &first.id, "the passage", 1);
        let old_state = state_path(&library, &first);
        let old_bytes = fs::read(&old_state).unwrap();
        library.remove(&first.id).unwrap();

        let again = import_new(&library, &source);
        // A state of the Removed Import coming back, e.g. from another Device.
        fs::write(&old_state, old_bytes).unwrap();

        assert_eq!(again.progress, None);
        assert_eq!(library.documents().unwrap()[0].progress, None);
        assert_eq!(library.markup(&again.id).unwrap(), Markup::default());
    }

    #[test]
    fn a_folder_of_a_recorded_remove_is_deleted_on_open() {
        let scratch = Scratch::new();
        let library = scratch.library();
        let document = import_new(&library, &scratch.file("a.pdf", b"abc"));
        {
            // The Remove was recorded, but the folder wasn't renamed yet.
            let mut doc = library.catalog();
            assert!(doc.remove(&document.id));
            library.save_catalog(&mut doc).unwrap();
        }
        drop(library);

        let library = scratch.library();

        assert!(!document.path.exists());
        assert_eq!(library.documents().unwrap(), vec![]);
        let again = import_new(&library, &scratch.file("a.pdf", b"abc"));
        assert_eq!(again.progress, None);
    }

    /// Records another Import of Document `id`, as Sync would, and returns its
    /// ID.
    fn add_import(library: &Library, id: &str, imported: u64) -> String {
        let mut doc = library.catalog();
        let import = doc.add_import(id, "a.pdf", imported);
        library.save_catalog(&mut doc).unwrap();
        import
    }

    #[test]
    fn a_document_with_several_imports_is_listed_once_and_reads_as_the_merge_of_their_states() {
        let scratch = Scratch::new();
        let library = scratch.library();
        let document = import_new(&library, &scratch.file("a.pdf", b"abc"));
        library
            .save_progress(&document.id, &progress(3, 1_000))
            .unwrap();
        library
            .add_highlight(&document.id, anchor(), "first", YELLOW, 1)
            .unwrap()
            .unwrap();
        let second = add_import(&library, &document.id, u64::MAX / 2);
        let other = a_highlight("other");
        let other_state = state::update(None, &ActorId::random(), |doc| {
            markup::put_highlight(doc, &other);
        });
        let folder = document.path.parent().unwrap();
        fs::write(
            folder.join(format!(".state-{second}.automerge")),
            other_state,
        )
        .unwrap();

        let documents = library.documents().unwrap();
        assert_eq!(documents.len(), 1);
        assert_eq!(documents[0].progress, Some(progress(3, 1_000)));
        assert_eq!(library.markup(&document.id).unwrap().highlights.len(), 2);

        // Edits reach the Import that holds what they change.
        library
            .set_highlight_color(&document.id, "other", GREEN)
            .unwrap();
        let colors: Vec<_> = library
            .markup(&document.id)
            .unwrap()
            .highlights
            .iter()
            .map(|h| h.color)
            .collect();
        assert!(colors.contains(&GREEN) && colors.contains(&YELLOW));
        library
            .save_progress(&document.id, &progress(1, 3_000))
            .unwrap();
        assert_eq!(
            library.documents().unwrap()[0].progress,
            Some(progress(1, 3_000))
        );
        library.remove_highlight(&document.id, "other").unwrap();
        assert_eq!(library.markup(&document.id).unwrap().highlights.len(), 1);

        // Removing the Document removes every Import.
        library.remove(&document.id).unwrap();
        drop(library);
        assert_eq!(scratch.library().documents().unwrap(), vec![]);
    }

    #[test]
    fn an_import_listed_without_its_file_is_not_a_document_until_the_file_is_imported() {
        let scratch = Scratch::new();
        let library = scratch.library();
        add_import(&library, ABC_SHA256, 5);
        assert_eq!(library.documents().unwrap(), vec![]);

        let document = import_new(&library, &scratch.file("other-name.pdf", b"abc"));

        // It is stored under the listed name and keeps the listed Import.
        assert_eq!(document.path.file_name().unwrap(), "a.pdf");
        assert_eq!(library.catalog().live(ABC_SHA256).count(), 1);
        assert_eq!(library.documents().unwrap(), vec![document]);
    }

    #[test]
    fn a_listed_file_name_that_points_outside_the_document_is_not_a_document() {
        let scratch = Scratch::new();
        let library = scratch.library();
        fs::write(scratch.0.join("library/outside.pdf"), b"x").unwrap();
        fs::create_dir(scratch.0.join("library/evil")).unwrap();
        let mut doc = library.catalog();
        doc.add_import("evil", "../outside.pdf", 1);
        drop(doc);

        assert_eq!(library.documents().unwrap(), vec![]);
    }

    #[test]
    fn imports_on_several_threads_are_all_listed() {
        let scratch = Scratch::new();
        let library = scratch.library();
        let sources: Vec<_> = (0..8)
            .map(|n| scratch.file(&format!("{n}.pdf"), format!("document {n}").as_bytes()))
            .collect();

        std::thread::scope(|scope| {
            for source in &sources {
                scope.spawn(|| import_new(&library, source));
            }
        });

        assert_eq!(library.documents().unwrap().len(), 8);
        assert_eq!(scratch.library().documents().unwrap().len(), 8);
    }

    /// Imports `count` distinct Documents and saves Reading Progress for each.
    fn library_of_opened_documents(scratch: &Scratch, count: u32) -> Library {
        let library = scratch.library();
        for n in 0..count {
            let source = scratch.file("source.pdf", format!("document {n}").as_bytes());
            let document = import_new(&library, &source);
            library
                .save_progress(&document.id, &progress(n, u64::from(n) + 1))
                .unwrap();
        }
        library
    }

    #[test]
    fn saving_reading_progress_keeps_no_history() {
        let scratch = Scratch::new();
        let library = scratch.library();
        let document = import_new(&library, &scratch.file("a.pdf", b"abc"));

        for n in 0..1_000 {
            library
                .save_progress(&document.id, &progress(n % 300, u64::from(n) + 1))
                .unwrap();
        }

        assert!(!state_path(&library, &document).exists());
        let stored = fs::read(first_progress_path(&library, &document.id)).unwrap();
        assert!(stored.len() < 64, "progress is {} bytes", stored.len());
        assert_eq!(
            listed_progress(&library, &document.id),
            Some(progress(999 % 300, 1_000))
        );
    }

    /// Debug timings mean nothing: run with
    /// `cargo test --release -- --ignored listing_1000`.
    #[test]
    #[ignore = "timing budget; run in a release build"]
    fn listing_1000_documents_with_reading_progress_takes_under_100_ms() {
        let scratch = Scratch::new();
        let library = library_of_opened_documents(&scratch, 1_000);

        let start = std::time::Instant::now();
        let documents = library.documents().unwrap();
        let elapsed = start.elapsed();

        assert_eq!(documents.len(), 1_000);
        assert!(documents.iter().all(|d| d.progress.is_some()));
        assert!(elapsed < Duration::from_millis(100), "took {elapsed:?}");
    }
}
