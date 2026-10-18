# 06: Document Search on macOS

**What to build:** Mac readers get the native `NSTextFinder` find bar, backed by Document Search. See `.scratch/navigation/spec.md`.

**Blocked by:** 05

**Status:** done

- [x] Spike first: confirm an `NSTextFinder` client backed by Document Search works over the PDFView, including the user's case and word-match options; if not, pick the closest native setup without custom search UI
  - Spike result: `NSTextFinder` can't take our matches; it matches the client's text itself, on a background queue, with the user's options. So the client serves the Document's text page by page (`DocumentText`), with a search boundary at each page end, and maps the matches back to PDFKit selections. `DocumentSearch` isn't used on macOS.
- [x] Incremental search updates results as the reader types
- [x] Edit > Find, ⌘F, ⌘G and ⇧⌘G work; the `magnifyingglass` toolbar button opens the bar and is hidden in full-screen Immersive Mode
- [x] The current match is highlighted on the page and the count is shown
- [x] Any new Document Search behaviour needed by the client is covered by Swift tests in the Document Search suite
