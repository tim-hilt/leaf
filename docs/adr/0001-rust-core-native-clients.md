# Rust core with native clients

All platform-independent logic (library, markup, reading progress, sync) lives in one Rust core; each platform gets a fully native client (SwiftUI on Apple, later Kotlin/Compose on Android and GTK via gtk-rs on Linux). Rust has no GC or runtime, binds cleanly to Swift and Kotlin via UniFFI, and keeps behaviour identical everywhere.

## Considered Options

- **Kotlin Multiplatform**: heavy and less idiomatic on iOS, our Tier 1.
- **Swift everywhere**: tooling and libraries on Android/Linux still thin.
- **Flutter / React Native**: violate "native UI wherever possible".
