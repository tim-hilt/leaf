# 03: Covers

**What to build:** Each cell shows the Document's Cover (page 1), fading in over the placeholder. Covers are rendered at Import, saved across launches, rendered again if the system clears them, and deleted on Remove. See `.scratch/gallery/spec.md`.

**Blocked by:** 02

**Status:** in-review

- [x] Covers are saved in the system Caches folder, keyed by Document ID, and never synced
- [x] Import renders and saves the Cover with the PDF it already opened, so a new Document never shows a placeholder
- [x] The Library model offers an async Cover: the saved one, or page 1 rendered off the main thread with PDFKit, then saved
- [x] One fixed size (about 300 pt wide at the screen scale). Nothing is rendered again on resize or rotation
- [x] The Cover is scaled to fit the cell and sits on its bottom edge. The space above it is transparent
- [x] The Cover fades in over the placeholder. If it can't be rendered, the placeholder stays
- [x] Remove deletes the saved Cover
- [x] Tests (test-first, Library model): a Cover is available after Import without rendering; a Cover is rendered again after its saved copy is deleted; Remove deletes the saved Cover
- [ ] Manual check: wide Covers (slides) show a transparent gap, and Titles line up
