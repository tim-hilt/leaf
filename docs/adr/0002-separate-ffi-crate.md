# FFI lives in its own crate

The core is split into `leaf-core` (pure Rust domain logic) and `leaf-ffi` (the UniFFI surface). The core stays testable and readable without FFI types, and Rust clients (Linux) depend on it directly. Only `leaf-ffi` knows how core types cross the language boundary.
