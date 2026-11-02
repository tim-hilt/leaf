# Document Search matches in the core, over the text of either Format

Amends ADR-0003. Whether a query matches, and the excerpt around a match, is decided by the core (`search.rs`), over the UTF-16 text of a PDF page or an EPUB spine item (ADR-0022). Case folding and word boundaries are thus the same in both Formats and on every platform. PDFKit still supplies a PDF's text, and its selections show the matches. The core searches an EPUB's items itself, so only the matches cross to the client, never the items' text.

The whole session is the core's too (`document_text.rs`): a Document's text is held as chunks — a PDF's pages, an EPUB's spine items — end to end, and the core searches it chunk by chunk in reading order, numbers the matches, finds the match at a position in the text and places each match in the Table of Contents. It hands the matches over a chunk at a time, so they stream to the client in reading order, and a client that stops asking cancels the search. A PDF's page text is read through the client (`PdfPages`), which also places a match on its page — the core cannot know where a PDFKit selection sits — and the core keeps what it read, so PDFKit extracts each page at most once while the Document is open, however often it is searched.

## Considered Options

- **PDFKit's find, filtered in Swift**: PDFKit matches substrings only, so the word rules and excerpts were written in Swift, and the EPUB search repeated them.
- **Matching in each client, over the same text**: the rules would drift apart.
