# The core parses EPUBs; clients only draw them

Amends ADR-0003. Apple has no EPUB engine like PDFKit, and an EPUB is plain zip, XML and XHTML, so the core reads everything that isn't drawing: the spine, Title, Author, Cover image and Table of Contents. Clients draw the spine's XHTML in the platform web view (`WKWebView` on Apple), which adds no binary size. Reflowable EPUBs only; fixed-layout and DRM-protected ones are rejected at Import.

## Considered Options

- **Readium toolkit**: complete, but several MB per platform and a non-native feel.
- **Converting to PDF on Import**: reuses the PDF path, but loses reflow and changes the File.
- **Parsing in each client**: every platform repeats the same zip and XML handling.
