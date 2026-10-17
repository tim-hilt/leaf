# Cloud providers sit behind one storage interface in the core

The core defines a small storage interface (put, get, list, changes since) and owns all sync logic. Google Drive and OneDrive are implemented in Rust over HTTP, so every platform gets them. iCloud is implemented in Swift through a UniFFI callback interface because CloudKit is only usable from Apple platforms. Sign-in (OAuth) runs natively on each platform, which then passes tokens to the core. Only one provider is active at a time; mirroring across providers would multiply sync edge cases for little benefit.

## Considered Options

- **iCloud Drive instead of CloudKit**: the OS decides which files to download, which breaks "download only what is missing" (ADR-0007).

## Consequences

- CloudKit has no "directory with a special name" (`docs/features.md`). The app's private CloudKit container fills that role.
- iCloud will not be available on Linux, Android or Windows.
