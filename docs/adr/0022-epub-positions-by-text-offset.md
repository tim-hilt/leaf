# EPUB positions are a spine item plus a character offset in the core's text

ADR-0003 anchors Markup and Reading Progress by page and page-space geometry, which reflowable EPUBs lack. Since the core parses EPUBs (ADR-0021), it also defines their text: a position is the index of a spine item plus a character offset into that item's text as the core extracts it. Highlights keep their quoted text as a fallback. Clients map these to and from their web view's selections; the core derives the percentage read from character counts.

## Considered Options

- **EPUB CFI**: the standard, but a path into the DOM that is complex to produce and compare, and breaks across engines that normalize the DOM differently.
