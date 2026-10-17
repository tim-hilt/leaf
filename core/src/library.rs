//! The Library: the Documents a user has imported, kept as plain folders.
//!
//! Layout (ADR-0012): `<root>/<sha256>/<original file name>`. The hash is the
//! Document's ID (ADR-0007). Imports are staged under `<root>/.staging` and
//! renamed into place, so a Document is either fully there or not at all.

use sha2::{Digest, Sha256};
use std::fs::{self, File};
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU32, Ordering::Relaxed};

const STAGING: &str = ".staging";

/// A Document in the Library.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Document {
    /// SHA-256 of the File, lowercase hex.
    pub id: String,
    /// The stored File.
    pub path: PathBuf,
}

/// The Library folder.
#[derive(Debug)]
pub struct Library {
    root: PathBuf,
}

impl Library {
    /// Opens the Library at `root`, creating it if needed and discarding
    /// leftovers of Imports that never finished.
    pub fn open(root: impl Into<PathBuf>) -> io::Result<Self> {
        let library = Library { root: root.into() };
        match fs::remove_dir_all(library.staging()) {
            Err(e) if e.kind() != io::ErrorKind::NotFound => return Err(e),
            _ => {}
        }
        fs::create_dir_all(library.staging())?;
        Ok(library)
    }

    /// Copies the File at `source` into the Library, unchanged. Importing a
    /// File that is already there copies nothing and returns its Document.
    ///
    /// `progress(copied, total)` is called with the bytes processed so far out
    /// of the File's size: first with 0, last with the total.
    pub fn import(&self, source: &Path, progress: impl FnMut(u64, u64)) -> io::Result<Document> {
        let name = source.file_name().ok_or_else(|| {
            io::Error::new(io::ErrorKind::InvalidInput, "source has no file name")
        })?;

        static NEXT: AtomicU32 = AtomicU32::new(0);
        let staged = self.staging().join(format!(
            "{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Relaxed)
        ));
        fs::create_dir(&staged)?;

        let result = copy_hashed(source, &staged.join(name), progress).and_then(|id| {
            let dir = self.root.join(&id);
            if !dir.exists() {
                fs::rename(&staged, &dir)?;
            }
            Ok(id)
        });
        // Nothing left to remove after a successful rename.
        let _ = fs::remove_dir_all(&staged);

        let id = result?;
        let dir = self.root.join(&id);
        // A duplicate keeps the name it was first imported under.
        document_in(&dir)?.ok_or_else(|| io::Error::other("imported Document is empty"))
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

    fn staging(&self) -> PathBuf {
        self.root.join(STAGING)
    }
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
        let n = input.read(&mut buffer)?;
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
    let Some(file) = fs::read_dir(dir)?.next().transpose()? else {
        return Ok(None);
    };
    Ok(Some(Document {
        id: dir
            .file_name()
            .unwrap_or_default()
            .to_string_lossy()
            .into_owned(),
        path: file.path(),
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

    fn import(library: &Library, source: &Path) -> io::Result<Document> {
        library.import(source, |_, _| {})
    }

    // SHA-256 of "abc", from FIPS 180-2.
    const ABC_SHA256: &str = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";

    #[test]
    fn import_stores_a_byte_identical_file_under_its_hash_and_original_name() {
        let scratch = Scratch::new();
        let library = scratch.library();
        let source = scratch.file("Paper.pdf", b"abc");

        let document = import(&library, &source).unwrap();

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
        let first = import(&library, &scratch.file("a.pdf", b"first")).unwrap();
        sleep(Duration::from_millis(20));
        let second = import(&library, &scratch.file("b.pdf", b"second")).unwrap();

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
        import(&library, &scratch.file("a.pdf", b"abc")).unwrap();

        assert!(
            library
                .import(&scratch.0.join("missing.pdf"), |_, _| {})
                .is_err()
        );

        assert_eq!(library.documents().unwrap().len(), 1);
        assert_eq!(
            fs::read_dir(scratch.0.join("library")).unwrap().count(),
            // The Document plus the (empty) staging folder.
            2
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
    fn importing_the_same_bytes_again_adds_no_second_document() {
        let scratch = Scratch::new();
        let library = scratch.library();
        let first = import(&library, &scratch.file("a.pdf", b"abc")).unwrap();

        let again = import(&library, &scratch.file("b.pdf", b"abc")).unwrap();

        assert_eq!(again, first);
        assert_eq!(library.documents().unwrap(), vec![first]);
    }
}
