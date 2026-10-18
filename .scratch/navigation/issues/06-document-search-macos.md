# 06: Document Search on macOS

**What to build:** Mac readers get the native `NSTextFinder` find bar, backed by Document Search. See `.scratch/navigation/spec.md`.

**Blocked by:** 05

**Status:** ready-for-agent

- [ ] Spike first: confirm an `NSTextFinder` client backed by Document Search works over the PDFView, including the user's case and word-match options; if not, pick the closest native setup without custom search UI
- [ ] Incremental search updates results as the reader types
- [ ] Edit > Find, ⌘F, ⌘G and ⇧⌘G work; the `magnifyingglass` toolbar button opens the bar and is hidden in full-screen Immersive Mode
- [ ] The current match is highlighted on the page and the count is shown
- [ ] Any new Document Search behaviour needed by the client is covered by Swift tests in the Document Search suite
