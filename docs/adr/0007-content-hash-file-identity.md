# Files are identified by their content hash

A file's ID is the SHA-256 of its bytes, computed on import. This enforces "a file can only be imported once", even when the same PDF is imported on two devices separately. A device downloads a file only if it has no local copy with that hash. Files are never modified (markup is stored separately, see `docs/features.md`), so the ID stays stable.

## Consequences

PDFs that differ by a single byte are different files with separate markup.
