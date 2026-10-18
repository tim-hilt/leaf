# 05: Document Search on iOS/iPadOS

**What to build:** The reader finds text in a Document with the native iOS find bar, updating as they type, with the system's case and whole-word options. See `.scratch/navigation/spec.md`.

**Blocked by:** None (can start immediately)

**Status:** ready-for-agent

- [ ] Spike first: confirm the iOS find interaction can be driven by our own matches (own find session over a searchable object) and receives the user's options; if not, pick the closest native setup that still does, without custom search UI
- [ ] The Document Search module takes a query, case sensitivity and a word-match method (Contains, Starts With, Full Word) and returns matches in reading order with page index and PDFKit selection
- [ ] It searches with PDFKit's asynchronous find, delivers matches as found, and a new query cancels the old one
- [ ] Starts With and Full Word are filtered on word boundaries in the page text
- [ ] An empty query or a page without text gives no matches
- [ ] The test PDF helper can draw text on pages
- [ ] A trailing `magnifyingglass` toolbar button opens the find bar; hidden in Immersive Mode; ⌘F works with an iPad keyboard
- [ ] The find bar shows the current match highlighted, the others marked, "3 of 27" and next/previous
- [ ] Swift tests cover: order across pages, case-insensitive and case-sensitive, Contains/Starts With/Full Word including punctuation and page start and end, empty query, pages without text, cancelling
