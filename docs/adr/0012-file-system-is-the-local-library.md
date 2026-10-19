# The file system is the local Library

Each imported File is stored unchanged at `<library>/<sha256>/<original file name>`, in a hidden folder in Application Support. Listing that folder gives the Library; keeping the original name keeps the Title fallback working without extra metadata. The core owns this folder and doesn't care about file formats, so supporting other formats later won't change the layout. The Automerge Library document (ADR-0008) was deferred until Cloud Backing needed it (ADR-0015).

The Library document (ADR-0015) lists what was Imported and Removed, with Date Imported. A Document's synced state (ADR-0008) is one hidden file per Import in the same folder, so Remove takes it along in its one rename. The File is the folder's only non-hidden entry.

## Considered Options

- **Automerge Library document from the start**: one model from day one, but a CRDT dependency and schema before any state is synced.
- **Flat `<sha256>.pdf` files**: loses the original name, so the Title fallback would show the hash.

## Consequences

- Files must never be edited outside the app. The folder stays hidden for now; making it visible (e.g. to publish the markup format) is a later decision.
