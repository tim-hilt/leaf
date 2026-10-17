//! Foreign-language interface of the LeafPDF core, exported via UniFFI.
//!
//! This crate is the only place that knows about FFI: it adapts
//! `leafpdf-core` types to UniFFI-compatible ones and nothing else. Keep
//! domain logic in `leafpdf-core` so it stays testable without bindings.

use std::sync::Arc;

uniffi::setup_scaffolding!();

/// Version of the linked core. Clients use it to verify at runtime that
/// they talk to the core they were built against.
#[uniffi::export]
pub fn core_version() -> String {
    leafpdf_core::VERSION.to_owned()
}

/// The one error crossing the FFI: the system's message for what failed.
#[derive(Debug, uniffi::Error)]
#[uniffi(flat_error)]
pub enum LibraryError {
    Failed(String),
}

impl std::fmt::Display for LibraryError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let Self::Failed(message) = self;
        f.write_str(message)
    }
}

impl From<std::io::Error> for LibraryError {
    fn from(e: std::io::Error) -> Self {
        Self::Failed(e.to_string())
    }
}

/// Where the user left off, see `leafpdf_core::progress::ReadingProgress`.
/// `last_read` is milliseconds since the Unix epoch.
#[derive(uniffi::Record)]
pub struct ReadingProgress {
    pub page_index: u32,
    pub x: f64,
    pub y: f64,
    pub last_read: u64,
}

impl From<leafpdf_core::progress::ReadingProgress> for ReadingProgress {
    fn from(p: leafpdf_core::progress::ReadingProgress) -> Self {
        Self {
            page_index: p.page_index,
            x: p.x,
            y: p.y,
            last_read: p.last_read,
        }
    }
}

impl From<ReadingProgress> for leafpdf_core::progress::ReadingProgress {
    fn from(p: ReadingProgress) -> Self {
        Self {
            page_index: p.page_index,
            x: p.x,
            y: p.y,
            last_read: p.last_read,
        }
    }
}

/// A Document in the Library: its ID, the path of its stored File and its
/// Reading Progress, if it was ever opened.
#[derive(uniffi::Record)]
pub struct Document {
    pub id: String,
    pub path: String,
    pub progress: Option<ReadingProgress>,
}

impl From<leafpdf_core::library::Document> for Document {
    fn from(d: leafpdf_core::library::Document) -> Self {
        Self {
            id: d.id,
            path: d.path.to_string_lossy().into_owned(),
            progress: d.progress.map(Into::into),
        }
    }
}

/// What an Import did, see `leafpdf_core::library::ImportResult`.
#[derive(uniffi::Enum)]
pub enum ImportResult {
    Imported(Document),
    AlreadyImported(Document),
}

impl From<leafpdf_core::library::ImportResult> for ImportResult {
    fn from(r: leafpdf_core::library::ImportResult) -> Self {
        use leafpdf_core::library::ImportResult as Core;
        match r {
            Core::Imported(d) => Self::Imported(d.into()),
            Core::AlreadyImported(d) => Self::AlreadyImported(d.into()),
        }
    }
}

/// Receives the progress of an Import. Implemented by the client and called
/// from the thread that runs the Import, not the main thread.
#[uniffi::export(with_foreign)]
pub trait ImportProgress: Send + Sync {
    /// `copied` bytes of the File's `total` are processed.
    fn report(&self, copied: u64, total: u64);
}

/// The Library folder, see `leafpdf_core::library::Library`.
#[derive(uniffi::Object)]
pub struct Library(leafpdf_core::library::Library);

#[uniffi::export]
impl Library {
    #[uniffi::constructor]
    pub fn open(root: String) -> Result<Arc<Self>, LibraryError> {
        Ok(Arc::new(Self(leafpdf_core::library::Library::open(root)?)))
    }

    pub fn import(
        &self,
        source: String,
        progress: Arc<dyn ImportProgress>,
    ) -> Result<ImportResult, LibraryError> {
        let result = self.0.import(source.as_ref(), |copied, total| {
            progress.report(copied, total)
        })?;
        Ok(result.into())
    }

    pub fn remove(&self, id: String) -> Result<(), LibraryError> {
        Ok(self.0.remove(&id)?)
    }

    pub fn save_progress(&self, id: String, progress: ReadingProgress) -> Result<(), LibraryError> {
        Ok(self.0.save_progress(&id, &progress.into())?)
    }

    pub fn documents(&self) -> Result<Vec<Document>, LibraryError> {
        Ok(self.0.documents()?.into_iter().map(Into::into).collect())
    }
}
