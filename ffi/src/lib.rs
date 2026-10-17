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

/// A Document in the Library: its ID and the path of its stored File.
#[derive(uniffi::Record)]
pub struct Document {
    pub id: String,
    pub path: String,
}

impl From<leafpdf_core::library::Document> for Document {
    fn from(d: leafpdf_core::library::Document) -> Self {
        Self {
            id: d.id,
            path: d.path.to_string_lossy().into_owned(),
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

    pub fn documents(&self) -> Result<Vec<Document>, LibraryError> {
        Ok(self.0.documents()?.into_iter().map(Into::into).collect())
    }
}
