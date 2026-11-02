# Document Search matches in the core, over the text of either Format

Amends ADR-0003. Whether a query matches, and the excerpt around a match, is decided by the core (`search.rs`), over the UTF-16 text of a PDF page or an EPUB spine item (ADR-0022). Case folding and word boundaries are thus the same in both Formats and on every platform. PDFKit still supplies a PDF's text, and its selections show the matches. The core searches an EPUB's items itself, so only the matches cross to the client, never the items' text.

## Considered Options

- **PDFKit's find, filtered in Swift**: PDFKit matches substrings only, so the word rules and excerpts were written in Swift, and the EPUB search repeated them.
- **Matching in each client, over the same text**: the rules would drift apart.
