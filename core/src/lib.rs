//! Platform-independent heart of LeafPDF.
//!
//! Owns everything that must behave identically on every platform: the
//! library of imported PDFs, markup, reading progress and cloud sync.
//! It never renders or parses PDFs; clients do that with the platform's
//! native PDF engine (see `docs/adr/0003-native-pdf-rendering.md`).
//!
//! The crate is plain Rust with no FFI concerns, so Rust clients (Linux)
//! can depend on it directly. Foreign-language clients go through
//! `leafpdf-ffi`.

/// Semantic version of the core, as declared in the workspace manifest.
pub const VERSION: &str = env!("CARGO_PKG_VERSION");

pub(crate) mod chunks;
pub mod details;
pub mod library;
pub(crate) mod library_doc;
pub mod listing;
pub mod markup;
pub mod preferences;
pub mod progress;
pub(crate) mod state;
pub mod storage;
pub mod sync_loop;
pub mod webdav;
