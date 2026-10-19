# Cloud Providers sit behind one storage interface in the core

The core defines a small storage interface (put, get, list, delete) and owns all sync logic. Every Cloud Provider is implemented in Rust in the core, so every platform gets them: WebDAV, Folder, Google Drive and OneDrive (ADR-0017). Sign-in (OAuth) runs natively on each platform, which then passes tokens to the core. Only one Cloud Provider is Connected at a time; mirroring across providers would multiply sync edge cases for little benefit.

## Considered Options

- **CloudKit through a Swift callback interface**: needs a paid Apple Developer membership (ADR-0017).

## Consequences

- iCloud is reachable only as a Folder the user picks in iCloud Drive. The OS decides when its files download, so the Folder provider must request downloads itself.
