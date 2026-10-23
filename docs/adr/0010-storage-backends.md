# Cloud Providers sit behind one storage interface in the core

The core defines a small storage interface (put, get, list, delete) and owns all sync logic. Every Cloud Provider is implemented in Rust in the core, so every platform gets them: WebDAV, iCloud Drive, Google Drive and OneDrive (ADR-0017). Sign-in (OAuth) runs natively on each platform, which then passes tokens to the core. The core refreshes access tokens itself and hands rotated refresh tokens back to the client to store. Only one Cloud Provider is Connected at a time; mirroring across providers would multiply sync edge cases for little benefit.

## Considered Options

- **CloudKit through a Swift callback interface**: needs a paid Apple Developer membership (ADR-0017).
- **iCloud Drive as a Swift storage**: only Apple clients want it, but UniFFI can't stream, so every File would cross the FFI in memory, and Swift would duplicate the directory storage.
- **Token refresh in each client**: every platform would reimplement it.

## Consequences

- iCloud Drive has no app container without the paid membership. Instead, the user grants the iCloud Drive root once per Device (iOS and macOS alike), and LeafPDF always uses `iCloud Drive/LeafPDF` in it; granting any other folder is refused. The core reads it as a directory. The OS decides when its files download: a file not downloaded yet is a `.name.icloud` placeholder, which the directory storage treats as absent while asking the client (`request_download`) to have it fetched, so a later poll finds it.
