# 06: Remove a Document

**What to build:** Long-pressing (iOS) or right-clicking (macOS) a Document in the Gallery offers "Remove". After a destructive confirmation naming the Title (and saying markup and reading progress go too, on all devices), the Document and its File are gone. The same File can be Imported again afterwards. See `.scratch/file-import/spec.md`.

**Blocked by:** 01

**Status:** ready-for-agent

- [ ] Core `remove(id)` renames the Document's folder out of the Library, then deletes it (Rust tests)
- [ ] Opening the Library removes leftover removal folders
- [ ] A Removed Document can be Imported again (Rust test)
- [ ] Client Library model `remove(document)`; the Document disappears from `documents` (Swift test)
- [ ] `.contextMenu` "Remove" on Gallery rows: long-press on iOS, right-click on macOS
- [ ] Destructive confirmation dialog naming the Title
