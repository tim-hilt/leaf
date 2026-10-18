# Dark Pages are drawn by post-processing each page in a PDFPage subclass

A `PDFDocument` subclass makes PDFKit create `PDFPage` subclasses (`classForPage`). In Dark Pages, a page renders itself into a bitmap, and Core Image inverts it, rotates the hue by 180° (so colors come back and grays stay gray), and maps black to the Page color and white to the Text color with one color matrix. Light Pages draw the page unchanged. PDFKit draws the selection and search highlights on top of the page, outside the page's `draw`, so they keep their colors. Covers reuse the same Core Image step on the saved Cover image (`CGImage.shown(as:)`). Changing the style redraws a `PDFView` with `layoutDocumentView()`; scroll position is kept.

Measured on a generated 300-page Document (text, vector lines, a gradient image on half the pages), mean of 40 pages on an Apple M1 Mac, drawing to a bitmap:

| | Light Pages | Core Image | Blend modes |
| --- | --- | --- | --- |
| Fit-to-width, 2×, whole page | 3.7 ms | 10.7 ms | 47 ms |
| 5× zoom, 1024 px tile | 3.9 ms | 7.1 ms | 29 ms |

## Considered Options

- **Blend modes in Core Graphics** (difference with white, then the original on top in `.color` mode, multiply, add): keeps exact luminance reversal and needs no bitmap, but is 7–12× slower than Light Pages in software and draws the page twice. Rejected for scroll smoothness.
- **Layer filters on the PDFView** (`compositingFilter`, `contentFilters`): cheapest, but macOS-only and also reverses the selection and highlights.
- **Pre-rendered page images**: memory-heavy and re-rendered on every zoom.

## Consequences

- Invert plus hue rotation reverses brightness approximately, not exactly: strongly colored areas come out lighter and less saturated than their original. Images are reversed too.
- Drawing off-screen costs one bitmap per tile; Core Image runs on the GPU.
- `PDFPage` subclasses must hold no Swift state: PDFKit creates them without Swift initializers. The appearance lives in the document behind a lock, as PDFKit draws on background threads.
- Not measured: the iOS Simulator and devices. Redrawing relies on `layoutDocumentView()` there as well.
