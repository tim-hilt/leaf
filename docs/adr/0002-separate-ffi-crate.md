# FFI lives in its own crate

The core is split into `leafpdf-core` (pure Rust domain logic) and `leafpdf-ffi` (the UniFFI surface). The core stays testable and readable without FFI types, and Rust clients (Linux) depend on it directly. Only `leafpdf-ffi` knows how core types cross the language boundary.
