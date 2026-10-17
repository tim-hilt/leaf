# 01: Import a PDF end-to-end

**What to build:** Tapping "+" in the Gallery opens a single-selection picker that only accepts PDFs. The chosen File is copied unchanged into the hidden Library folder and the new Document opens in the Reader. The Gallery lists the Library newest Import first; an empty Library shows "No Documents" with an "Import…" button. The temporary sample Document is gone. See `.scratch/file-import/spec.md`.

**Blocked by:** None (can start immediately)

**Status:** done

- [x] Core `Library`: open at a root folder, Import a source path, list Documents newest first (Rust tests in the source file, against temporary folders, test-first)
- [x] Import streams the source once, computing SHA-256 while copying into a staging folder, then renames into place at `<root>/<sha256>/<original file name>` (ADR-0012)
- [x] The stored File is byte-identical and keeps its original name
- [x] Opening the Library removes leftover staging folders
- [x] FFI exposes `Library` as a UniFFI object; `make apple-core` produces working bindings
- [x] Client Library model wraps the core, lives in a hidden Application Support folder, exposes `documents` and `import(url)` (Swift tests with the real `LeafCore`)
- [x] A Document without a stored title shows its original file name after Import (tested)
- [x] Gallery toolbar "+" Imports; on success the Reader opens the new Document
- [x] Empty Library shows `ContentUnavailableView` "No Documents" with an "Import…" button
- [x] The sample Document, its bundled PDF and every `// TEMPORARY: remove with File Import (features §2)` marker are removed
