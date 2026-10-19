//! The Library: the Documents a user has imported, kept as plain folders.
//!
//! Layout (ADR-0012): `<root>/<sha256>/<original file name>`. The hash is the
//! Document's ID (ADR-0007). Imports are staged under `<root>/.staging` and
//! renamed into place, so a Document is either fully there or not at all.
//! Removals go the other way: the folder is renamed into `<root>/.removing`
//! first, then deleted.
//!
//! Next to its File, a Document's folder holds the Document's Automerge
//! document as a hidden file (`STATE`), see `state`. The File is the
//! folder's only non-hidden entry. The state is stored like an Import: written
//! to staging, then renamed into place.

use crate::markup::{self, Highlight, Markup, PageNote, PageRects, Rgb};
use crate::preferences::{self, HighlightColor};
use crate::progress::{self, ReadingProgress};
use crate::state;
use sha2::{Digest, Sha256};
use std::fs::{self, File};
use std::io::{self, Read, Write};
use std::path::{Component, Path, PathBuf};
use std::sync::atomic::{AtomicU32, Ordering::Relaxed};
use std::time::SystemTime;

const STAGING: &str = ".staging";
const REMOVING: &str = ".removing";
const STATE: &str = ".state.automerge";
const PREFERENCES: &str = ".preferences.automerge";

/// A Document in the Library.
#[derive(Debug, Clone, PartialEq)]
pub struct Document {
    /// SHA-256 of the File, lowercase hex.
    pub id: String,
    /// The stored File.
    pub path: PathBuf,
    /// Where the user left off; none if the Document was never opened, or its
    /// state is missing or unreadable.
    pub progress: Option<ReadingProgress>,
}

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
}

impl Library {
    /// Opens the Library at `root`, creating it if needed and discarding
    /// leftovers of Imports and Removals that never finished.
    pub fn open(root: impl Into<PathBuf>) -> io::Result<Self> {
        let library = Library { root: root.into() };
        for dir in [library.staging(), library.removing()] {
            match fs::remove_dir_all(&dir) {
                Err(e) if e.kind() != io::ErrorKind::NotFound => return Err(e),
                _ => {}
            }
            fs::create_dir_all(&dir)?;
        }
        Ok(library)
    }

    /// Copies the File at `source` into the Library, unchanged. Importing a
    /// File that is already there copies nothing and returns its Document as
    /// `AlreadyImported`.
    ///
    /// `progress(copied, total)` is called with the bytes processed so far out
    /// of the File's size: first with 0, last with the total.
    pub fn import(
        &self,
        source: &Path,
        progress: impl FnMut(u64, u64),
    ) -> io::Result<ImportResult> {
        let name = source.file_name().ok_or_else(|| {
            io::Error::new(io::ErrorKind::InvalidInput, "source has no file name")
        })?;

        let staged = self.staging().join(unique_name());
        fs::create_dir(&staged)?;

        let result = copy_hashed(source, &staged.join(name), progress).and_then(|id| {
            let dir = self.root.join(&id);
            let is_new = !dir.exists();
            if is_new {
                fs::rename(&staged, &dir)?;
            }
            Ok((id, is_new))
        });
        // Nothing left to remove after a successful rename.
        let _ = fs::remove_dir_all(&staged);

        let (id, is_new) = result?;
        // A duplicate keeps the name it was first imported under.
        let document = document_in(&self.root.join(&id))?
            .ok_or_else(|| io::Error::other("imported Document is empty"))?;
        Ok(if is_new {
            ImportResult::Imported(document)
        } else {
            ImportResult::AlreadyImported(document)
        })
    }

    /// All Documents, newest Import first.
    pub fn documents(&self) -> io::Result<Vec<Document>> {
        let mut folders = Vec::new();
        for entry in fs::read_dir(&self.root)? {
            let entry = entry?;
            if !entry.file_name().to_string_lossy().starts_with('.') && entry.file_type()?.is_dir()
            {
                folders.push(entry.path());
            }
        }
        // Reading each folder (its File and state) dominates, so it is spread
        // over the cores: a Library of 1,000 Documents lists in half the time.
        let threads = std::thread::available_parallelism().map_or(1, usize::from);
        let per_thread = folders.len().div_ceil(threads).max(1);
        let per_chunk = std::thread::scope(|scope| {
            let workers: Vec<_> = folders
                .chunks(per_thread)
                .map(|chunk| {
                    scope.spawn(|| chunk.iter().map(|f| imported_document_in(f)).collect())
                })
                .collect();
            workers
                .into_iter()
                .map(|worker| worker.join().expect("listing a folder doesn't panic"))
                .collect::<io::Result<Vec<Vec<_>>>>()
        })?;
        // Folders without a File (`None`) are skipped.
        let mut found: Vec<_> = per_chunk.into_iter().flatten().flatten().collect();
        found.sort_by(|a, b| b.0.cmp(&a.0).then_with(|| a.1.id.cmp(&b.1.id)));
        Ok(found.into_iter().map(|(_, document)| document).collect())
    }

    /// Stores `progress` as the Reading Progress of Document `id`, replacing
    /// the previous one. Saving for a Document that isn't in the Library (never
    /// imported, or Removed, even just now) does nothing. An `id` that isn't a
    /// Document ID is `InvalidInput`. A corrupt state is replaced.
    pub fn save_progress(&self, id: &str, progress: &ReadingProgress) -> io::Result<()> {
        self.update_state(id, |existing| progress::write(existing, progress))
    }

    /// The Markup of Document `id`: empty if it has none, or the Document isn't
    /// in the Library, or its state is unreadable. An `id` that isn't a
    /// Document ID is `InvalidInput`.
    pub fn markup(&self, id: &str) -> io::Result<Markup> {
        let state = self.folder(id)?.join(STATE);
        Ok(fs::read(state).map_or_else(|_| Markup::default(), |bytes| markup::read(&bytes)))
    }

    /// Adds a Highlight of `quoted_text` at `anchor` in `color`, `created` in
    /// milliseconds since the Unix epoch, to Document `id`, and returns it. It
    /// is independent of any Highlight already there, also on the same text.
    /// Like `save_progress`, it does nothing for a Document that isn't in the
    /// Library, and a corrupt state is replaced.
    pub fn add_highlight(
        &self,
        id: &str,
        anchor: Vec<PageRects>,
        quoted_text: &str,
        color: Rgb,
        created: u64,
    ) -> io::Result<Highlight> {
        let highlight = Highlight {
            id: state::new_id(),
            anchor,
            quoted_text: quoted_text.to_owned(),
            color,
            created,
            note: None,
        };
        self.update_state(id, |existing| markup::add(existing, &highlight))?;
        Ok(highlight)
    }

    /// Sets the color of Highlight `highlight` of Document `id`. Does nothing
    /// for a Highlight that isn't there, or a Document that isn't in the
    /// Library; a Highlight removed on another device stays removed.
    pub fn set_highlight_color(&self, id: &str, highlight: &str, color: Rgb) -> io::Result<()> {
        self.update_state(id, |existing| markup::set_color(existing, highlight, color))
    }

    /// Sets the Note of Highlight `highlight` of Document `id` to `note`, an
    /// edit of the text that merges with concurrent typing. Empty `note`
    /// removes the Note. Does nothing for a Highlight that isn't there, or a
    /// Document that isn't in the Library.
    pub fn set_highlight_note(&self, id: &str, highlight: &str, note: &str) -> io::Result<()> {
        self.update_state(id, |existing| markup::set_note(existing, highlight, note))
    }

    /// Removes Highlight `highlight` from Document `id`, without a trace. Does
    /// nothing for a Highlight that isn't there, or a Document that isn't in the
    /// Library.
    pub fn remove_highlight(&self, id: &str, highlight: &str) -> io::Result<()> {
        self.update_state(id, |existing| markup::remove(existing, highlight))
    }

    /// Adds a page Note at (`x`, `y`) in page space on page `page_index` of
    /// Document `id`, `created` in milliseconds since the Unix epoch, and
    /// returns it, still without text: it isn't in the Markup until
    /// `set_page_note_text` gives it some. Like `add_highlight`, it does nothing
    /// for a Document that isn't in the Library.
    pub fn add_page_note(
        &self,
        id: &str,
        page_index: u32,
        x: f64,
        y: f64,
        created: u64,
    ) -> io::Result<PageNote> {
        let note = PageNote {
            id: state::new_id(),
            page_index,
            x,
            y,
            created,
            text: String::new(),
        };
        self.update_state(id, |existing| markup::add_page_note(existing, &note))?;
        Ok(note)
    }

    /// Sets the text of page Note `note` of Document `id` to `text`, an edit
    /// that merges with concurrent typing. Empty `text` removes the page Note.
    /// Does nothing for a page Note that isn't there, or a Document that isn't
    /// in the Library.
    pub fn set_page_note_text(&self, id: &str, note: &str, text: &str) -> io::Result<()> {
        self.update_state(id, |existing| {
            markup::set_page_note_text(existing, note, text)
        })
    }

    /// Removes page Note `note` from Document `id`, without a trace. Does
    /// nothing for a page Note that isn't there, or a Document that isn't in the
    /// Library.
    pub fn remove_page_note(&self, id: &str, note: &str) -> io::Result<()> {
        self.update_state(id, |existing| markup::remove_page_note(existing, note))
    }

    /// The Highlight Colors to choose from: the six built-in ones, yellow
    /// first, then the Custom Colors in the order added.
    pub fn highlight_colors(&self) -> Vec<HighlightColor> {
        preferences::colors(self.read_preferences().as_deref())
    }

    /// The color of new Highlights: yellow until the user picks another, or if
    /// the Preferences are unreadable or its Custom Color was removed.
    pub fn default_highlight_color(&self) -> HighlightColor {
        preferences::default_color(self.read_preferences().as_deref())
    }

    /// Makes the Highlight Color `id`, a built-in color's name or a Custom
    /// Color's ID, the Default Highlight Color. An `id` that is no Highlight
    /// Color is `InvalidInput`. Corrupt Preferences are replaced.
    pub fn set_default_highlight_color(&self, id: &str) -> io::Result<()> {
        if !self.highlight_colors().iter().any(|c| c.id == id) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                format!("{id:?} is not a Highlight Color"),
            ));
        }
        self.replace_file(&self.preferences(), |existing| {
            preferences::set_default_color(existing, id)
        })
    }

    /// Adds `rgb` as a Custom Color after the others, `added` in milliseconds
    /// since the Unix epoch, and returns it. There is no limit. Corrupt
    /// Preferences are replaced.
    pub fn add_custom_color(&self, rgb: Rgb, added: u64) -> io::Result<HighlightColor> {
        let mut color = None;
        self.replace_file(&self.preferences(), |existing| {
            let (bytes, new) = preferences::add_custom_color(existing, rgb, added);
            color = Some(new);
            bytes
        })?;
        Ok(color.expect("the write ran"))
    }

    /// Removes the Custom Color `id`. Highlights keep their color. If it was
    /// the Default Highlight Color, that is yellow again. Does nothing for a
    /// built-in color, which can't be removed, or an unknown `id`.
    pub fn remove_custom_color(&self, id: &str) -> io::Result<()> {
        self.replace_file(&self.preferences(), |existing| {
            preferences::remove_custom_color(existing, id)
        })
    }

    fn read_preferences(&self) -> Option<Vec<u8>> {
        fs::read(self.preferences()).ok()
    }

    /// Replaces the state of Document `id` with what `write` makes of the
    /// stored one (none if missing). Nothing happens if the Document isn't in
    /// the Library.
    fn update_state(
        &self,
        id: &str,
        write: impl FnOnce(Option<&[u8]>) -> Vec<u8>,
    ) -> io::Result<()> {
        let state = self.folder(id)?.join(STATE);
        self.replace_file(&state, write)
    }

    /// Replaces the file `path` with what `write` makes of its content (none if
    /// missing). The file is staged and renamed into place, so it is never half
    /// written.
    fn replace_file(
        &self,
        path: &Path,
        write: impl FnOnce(Option<&[u8]>) -> Vec<u8>,
    ) -> io::Result<()> {
        let existing = fs::read(path).ok();
        let staged = self.staging().join(unique_name());
        let mut file = File::create_new(&staged)?;
        file.write_all(&write(existing.as_deref()))?;
        file.sync_all()?;
        match fs::rename(&staged, path) {
            // The folder is gone: the Document was never there or was Removed.
            Err(e) if e.kind() == io::ErrorKind::NotFound => {
                let _ = fs::remove_file(&staged);
                Ok(())
            }
            result => result,
        }
    }

    /// Deletes the Document `id` and its File. Removing a Document that
    /// isn't there does nothing. An `id` that isn't a Document ID (e.g. a
    /// path) is `InvalidInput`.
    ///
    /// The folder leaves the Library in one rename, so a crash mid-delete
    /// never leaves a half-deleted Document listed; `open` finishes the job.
    /// Nothing is remembered about the Document, so it can be Imported again.
    pub fn remove(&self, id: &str) -> io::Result<()> {
        let folder = self.folder(id)?;
        let doomed = self.removing().join(unique_name());
        match fs::rename(folder, &doomed) {
            Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(()),
            result => result?,
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

/// A name no other call in this process, or an earlier one, has used for a
/// scratch folder.
fn unique_name() -> String {
    static NEXT: AtomicU32 = AtomicU32::new(0);
    format!("{}-{}", std::process::id(), NEXT.fetch_add(1, Relaxed))
}

/// Streams `from` into a new file at `to`, returning the SHA-256 of the bytes.
fn copy_hashed(from: &Path, to: &Path, mut progress: impl FnMut(u64, u64)) -> io::Result<String> {
    let mut input = File::open(from)?;
    let total = input.metadata()?.len();
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
    output.sync_all()?;
    Ok(format!("{:x}", hasher.finalize()))
}

/// `document_in(dir)` with when it was Imported.
fn imported_document_in(dir: &Path) -> io::Result<Option<(SystemTime, Document)>> {
    let meta = fs::metadata(dir)?;
    let imported = meta.created().or_else(|_| meta.modified())?;
    Ok(document_in(dir)?.map(|document| (imported, document)))
}

/// The Document stored in the folder `<sha256>`, if it holds a File.
fn document_in(dir: &Path) -> io::Result<Option<Document>> {
    let is_hidden = |entry: &io::Result<fs::DirEntry>| matches!(entry, Ok(e) if e.file_name().to_string_lossy().starts_with('.'));
    let Some(file) = fs::read_dir(dir)?.find(|e| !is_hidden(e)).transpose()? else {
        return Ok(None);
    };
    let progress = fs::read(dir.join(STATE))
        .ok()
        .and_then(|bytes| progress::read(&bytes));
    Ok(Some(Document {
        id: dir
            .file_name()
            .unwrap_or_default()
            .to_string_lossy()
            .into_owned(),
        path: file.path(),
        progress,
    }))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::markup::Rect;
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

    fn import(library: &Library, source: &Path) -> io::Result<ImportResult> {
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
        assert_eq!(
            fs::read_dir(scratch.0.join("library")).unwrap().count(),
            // The Document plus the (empty) staging and removal folders.
            3
        );
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

        assert_eq!(again, first);
        assert_eq!(library.documents().unwrap(), vec![first]);
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

    fn progress(page_index: u32, last_read: u64) -> ReadingProgress {
        ReadingProgress {
            page_index,
            x: 12.5,
            y: 700.25,
            last_read,
        }
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
    fn the_state_file_does_not_hide_the_file() {
        let scratch = Scratch::new();
        let library = scratch.library();
        let document = import_new(&library, &scratch.file("a.pdf", b"abc"));
        library
            .save_progress(&document.id, &progress(1, 1))
            .unwrap();

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
        library
            .save_progress(&document.id, &progress(1, 1))
            .unwrap();

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
    fn a_corrupt_state_file_lists_as_never_opened_and_is_replaced_by_the_next_save() {
        let scratch = Scratch::new();
        let library = scratch.library();
        let document = import_new(&library, &scratch.file("a.pdf", b"abc"));
        library
            .save_progress(&document.id, &progress(3, 5))
            .unwrap();
        let state = fs::read_dir(document.path.parent().unwrap())
            .unwrap()
            .map(|e| e.unwrap().path())
            .find(|p| p != &document.path)
            .unwrap();
        fs::write(&state, b"not automerge").unwrap();

        assert_eq!(listed_progress(&library, &document.id), None);

        library
            .save_progress(&document.id, &progress(4, 6))
            .unwrap();
        assert_eq!(
            listed_progress(&library, &document.id),
            Some(progress(4, 6))
        );
    }

    #[test]
    fn a_state_file_without_progress_lists_as_never_opened() {
        let scratch = Scratch::new();
        let library = scratch.library();
        let document = import_new(&library, &scratch.file("a.pdf", b"abc"));
        let empty = automerge::AutoCommit::new().save();
        fs::write(document.path.parent().unwrap().join(STATE), empty).unwrap();

        assert_eq!(listed_progress(&library, &document.id), None);
    }

    fn anchor() -> Vec<PageRects> {
        vec![
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
        ]
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
        let state = document.path.parent().unwrap().join(STATE);
        let mut v1 = AutoCommit::load(&progress::write(None, &progress(7, 1_000))).unwrap();
        v1.put(ROOT, "version", 1_u64).unwrap();
        fs::write(&state, v1.save()).unwrap();

        assert_eq!(library.markup(&document.id).unwrap(), Markup::default());
        highlight(&library, &document.id, "the passage", 1_000);

        assert_eq!(
            listed_progress(&library, &document.id),
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

    #[test]
    fn a_page_note_survives_reopening_the_library_and_emptying_it_removes_it() {
        let scratch = Scratch::new();
        let library = scratch.library();
        let document = import_new(&library, &scratch.file("a.pdf", b"abc"));

        let added = library
            .add_page_note(&document.id, 4, 100.5, 200.5, 1_000)
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
        assert_eq!((added.page_index, added.x, added.y), (4, 100.5, 200.5));
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
    fn a_removed_page_note_is_gone_after_reopening_the_library() {
        let scratch = Scratch::new();
        let library = scratch.library();
        let document = import_new(&library, &scratch.file("a.pdf", b"abc"));
        let first = library.add_page_note(&document.id, 0, 1.0, 2.0, 1).unwrap();
        let second = library.add_page_note(&document.id, 1, 3.0, 4.0, 2).unwrap();
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
        let added = library.add_page_note(&document.id, 0, 1.0, 2.0, 1).unwrap();
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
        let added = library.add_page_note(&document.id, 0, 1.0, 2.0, 1).unwrap();
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
    fn highlighting_in_a_document_that_is_not_there_does_nothing() {
        let scratch = Scratch::new();
        let library = scratch.library();
        library
            .add_highlight("0123", anchor(), "x", YELLOW, 1)
            .unwrap();
        assert_eq!(library.markup("0123").unwrap(), Markup::default());
        assert!(!scratch.0.join("library/0123").exists());
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
        let state = document.path.parent().unwrap().join(STATE);
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
            .into_iter()
            .map(|c| c.id)
            .collect();
        assert_eq!(names, ["Yellow", "Green", "Blue", "Pink", "Purple", "Red"]);
    }

    #[test]
    fn the_default_highlight_color_is_yellow_until_set() {
        let scratch = Scratch::new();
        let library = scratch.library();
        assert_eq!(library.default_highlight_color().id, "Yellow");
    }

    #[test]
    fn the_default_highlight_color_survives_reopening_the_library() {
        let scratch = Scratch::new();
        let library = scratch.library();

        library.set_default_highlight_color("Purple").unwrap();
        assert_eq!(library.default_highlight_color().id, "Purple");
        drop(library);

        let library = scratch.library();
        let purple = library.default_highlight_color();
        assert_eq!(purple.id, "Purple");
        assert_eq!(purple, library.highlight_colors()[4]);
        library.set_default_highlight_color("Yellow").unwrap();
        assert_eq!(scratch.library().default_highlight_color().id, "Yellow");
    }

    #[test]
    fn setting_an_unknown_default_highlight_color_is_invalid_input() {
        let scratch = Scratch::new();
        let library = scratch.library();
        library.set_default_highlight_color("Green").unwrap();

        let err = library.set_default_highlight_color("Teal").unwrap_err();

        assert_eq!(err.kind(), io::ErrorKind::InvalidInput);
        assert_eq!(library.default_highlight_color().id, "Green");
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
        assert_eq!(scratch.library().highlight_colors()[6..], [teal, brown]);
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
        assert_eq!(library.highlight_colors().len(), 6 + 50);
    }

    #[test]
    fn a_custom_color_can_be_the_default_highlight_color_and_survives_reopening() {
        let scratch = Scratch::new();
        let library = scratch.library();
        let teal = library.add_custom_color(TEAL, 100).unwrap();

        library.set_default_highlight_color(&teal.id).unwrap();

        assert_eq!(scratch.library().default_highlight_color(), teal);
    }

    #[test]
    fn removing_a_custom_color_makes_yellow_the_default_again() {
        let scratch = Scratch::new();
        let library = scratch.library();
        let teal = library.add_custom_color(TEAL, 100).unwrap();
        library.set_default_highlight_color(&teal.id).unwrap();

        library.remove_custom_color(&teal.id).unwrap();

        assert_eq!(library.highlight_colors().len(), 6);
        assert_eq!(library.default_highlight_color().id, "Yellow");
        let err = library.set_default_highlight_color(&teal.id).unwrap_err();
        assert_eq!(err.kind(), io::ErrorKind::InvalidInput);
    }

    #[test]
    fn built_in_colors_cannot_be_removed() {
        let scratch = Scratch::new();
        let library = scratch.library();

        library.remove_custom_color("Yellow").unwrap();

        assert_eq!(library.highlight_colors().len(), 6);
        assert_eq!(library.highlight_colors()[0].id, "Yellow");
    }

    #[test]
    fn a_highlight_keeps_its_color_when_the_custom_color_is_removed() {
        let scratch = Scratch::new();
        let library = scratch.library();
        let document = import_new(&library, &scratch.file("a.pdf", b"abc"));
        let teal = library.add_custom_color(TEAL, 100).unwrap();
        let added = library
            .add_highlight(&document.id, vec![], "x", teal.rgb, 1)
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
        assert_eq!(library.default_highlight_color().id, "Yellow");

        library.set_default_highlight_color("Red").unwrap();

        assert_eq!(library.default_highlight_color().id, "Red");
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
    fn a_documents_state_stays_under_64_kb_after_1000_saves() {
        let scratch = Scratch::new();
        let library = scratch.library();
        let document = import_new(&library, &scratch.file("a.pdf", b"abc"));

        for n in 0..1_000 {
            library
                .save_progress(&document.id, &progress(n % 300, u64::from(n) + 1))
                .unwrap();
        }

        let state = fs::read(document.path.parent().unwrap().join(STATE)).unwrap();
        assert!(state.len() < 64 * 1024, "state is {} bytes", state.len());
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
