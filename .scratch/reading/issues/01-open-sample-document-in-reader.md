# 01: Open the sample Document in the Reader

**What to build:** The placeholder Gallery shows the temporary sample Document as its only entry. Tapping it pushes the Reader in the same window, showing the Document's pages in one continuously scrolling vertical column using PDFKit's native viewer. The navigation bar shows the Document's Title, and the standard back chevron returns to the Gallery. See `.scratch/reading/spec.md`.

**Blocked by:** None (can start immediately)

**Status:** done

- [x] Public-domain sample PDF (< 1 MB, multiple pages, outline, at least one differently sized page) is bundled
- [x] Sample-related code is marked `// TEMPORARY: remove with File Import (features §2)`
- [x] Gallery placeholder lists the sample Document; tapping it pushes the Reader
- [x] Reader shows pages in one vertical column with continuous scrolling on iOS, iPadOS and macOS
- [x] Title = PDF metadata title, falling back to the file name (unit-tested, test-first)
- [x] Standard back chevron, iOS edge swipe and macOS ⌘[ return to the Gallery
- [x] No other Reader UI (no page counter, thumbnails or toolbar)

## Comments

- Review: `Sample.pdf` had no outline; added one (title page + chapters I–IV).
