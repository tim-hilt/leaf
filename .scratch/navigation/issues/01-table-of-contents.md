# 01: Jump to a Chapter or Section from the Table of Contents

**What to build:** The Reader shows the Document's Table of Contents and lets the reader go to any Chapter or Section. There's no Back yet; a chosen row simply goes there. See `.scratch/navigation/spec.md`.

**Blocked by:** None (can start immediately)

**Status:** in-review

- [x] The Table of Contents module, built from a `PDFDocument`, gives Chapters and nested Sections (any depth) with title, printed page number (page label, falling back to the 1-based position in the File) and target Place
- [x] It is empty when the outline is missing or has no children; entries without a target are listed but can't be chosen
- [x] The test PDF helper can add an outline (nested entries with targets) and page labels
- [x] A trailing `list.bullet` toolbar button opens the Table of Contents: popover on Mac and iPad, sheet on iPhone
- [x] The button is hidden when the Table of Contents is empty and in Immersive Mode
- [x] macOS gets a Go menu with "Table of Contents" (⌥⌘T), acting on the focused Reader
- [x] Rows show the title and the printed page number at the trailing edge; Sections are nested and folded with the native disclosure control
- [x] Choosing a row goes to its Place and closes the list
- [x] Swift tests cover: nested entries with titles and Places, printed page numbers and the fallback, empty without outline, entries without a target
