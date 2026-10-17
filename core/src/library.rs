//! The Library: the Documents a user has imported, kept as plain folders.
//!
//! Layout (ADR-0012): `<root>/<sha256>/<original file name>`. The hash is the
//! Document's ID (ADR-0007). Imports are staged under `<root>/.staging` and
//! renamed into place, so a Document is either fully there or not at all.
//! Removals go the other way: the folder is renamed into `<root>/.removing`
//! first, then deleted.
//!
//! Next to its File, a Document's folder holds the Document's Automerge
//! document as a hidden file (`STATE`), see `progress`. The File is the
//! folder's only non-hidden entry. The state is stored like an Import: written
//! to staging, then renamed into place.

use crate::progress::{self, ReadingProgress};
use sha2::{Digest, Sha256};
use std::fs::{self, File};
use std::io::{self, Read, Write};
use std::path::{Component, Path, PathBuf};
use std::sync::atomic::{AtomicU32, Ordering::Relaxed};

const STAGING: &str = ".staging";
const REMOVING: &str = ".removing";
const STATE: &str = ".state.automerge";

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
        let mut found = Vec::new();
        for entry in fs::read_dir(&self.root)? {
            let entry = entry?;
            if entry.file_name().to_string_lossy().starts_with('.') || !entry.file_type()?.is_dir()
            {
                continue;
            }
            let meta = entry.metadata()?;
            let imported = meta.created().or_else(|_| meta.modified())?;
            if let Some(document) = document_in(&entry.path())? {
                found.push((imported, document));
            }
        }
        found.sort_by(|a, b| b.0.cmp(&a.0).then_with(|| a.1.id.cmp(&b.1.id)));
        Ok(found.into_iter().map(|(_, document)| document).collect())
    }

    /// Stores `progress` as the Reading Progress of Document `id`, replacing
    /// the previous one. Saving for a Document that isn't in the Library (never
    /// imported, or Removed, even just now) does nothing. An `id` that isn't a
    /// Document ID is `InvalidInput`. A corrupt state is replaced.
    pub fn save_progress(&self, id: &str, progress: &ReadingProgress) -> io::Result<()> {
        let folder = self.folder(id)?;
        let state = folder.join(STATE);
        let existing = match fs::read(&state) {
            Err(e) if e.kind() == io::ErrorKind::NotFound => None,
            result => result.ok(),
        };
        let staged = self.staging().join(unique_name());
        let mut file = File::create_new(&staged)?;
        file.write_all(&progress::write(existing.as_deref(), progress))?;
        file.sync_all()?;
        match fs::rename(&staged, state) {
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

/// The Document stored in the folder `<sha256>`, if it holds a File.
fn document_in(dir: &Path) -> io::Result<Option<Document>> {
    let mut file = None;
    for entry in fs::read_dir(dir)? {
        let entry = entry?;
        if !entry.file_name().to_string_lossy().starts_with('.') {
            file = Some(entry);
            break;
        }
    }
    let Some(file) = file else {
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
    fn the_state_is_a_hidden_automerge_document_with_schema_version_1() {
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
        assert_eq!(version.as_u64(), Some(1));
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
}
