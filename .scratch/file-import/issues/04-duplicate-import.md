# 04: Duplicate Import

**What to build:** Importing a File whose content is already in the Library copies nothing and shows an alert saying it's already in the Library, with an "Open" button that opens the existing Document. See `.scratch/file-import/spec.md`.

**Blocked by:** 01

**Status:** in-review

- [x] Core Import returns `AlreadyImported(id)` for a hash already in the Library, also under a different file name, and leaves the Library unchanged (Rust tests)
- [x] Client Library model returns a `duplicate(Document)` outcome (Swift test)
- [x] An alert names the File and offers "Open", which opens the existing Document in the Reader
