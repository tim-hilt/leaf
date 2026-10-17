# Clients render PDFs natively; the core never parses PDFs

Rendering, text extraction, search and table of contents use the platform engine (PDFKit on Apple). This is native, fast and adds no binary size. Bundling PDFium in the core would give identical text handling everywhere, but costs several MB per platform and gives a non-native reading experience.

## Consequences

The core cannot rely on any engine's text indices. Markup must be anchored in engine-neutral terms: page index plus page-space geometry, with the quoted text as a fallback.
