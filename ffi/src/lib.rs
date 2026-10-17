//! Foreign-language interface of the LeafPDF core, exported via UniFFI.
//!
//! This crate is the only place that knows about FFI: it adapts
//! `leafpdf-core` types to UniFFI-compatible ones and nothing else. Keep
//! domain logic in `leafpdf-core` so it stays testable without bindings.

uniffi::setup_scaffolding!();

/// Version of the linked core. Clients use it to verify at runtime that
/// they talk to the core they were built against.
#[uniffi::export]
pub fn core_version() -> String {
    leafpdf_core::VERSION.to_owned()
}
