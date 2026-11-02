# Document details are kept by the core, on each Device only

A Document's details (stored title, author, page count) are read from the File by the client's `PdfReader` (ADR-0026), or by the core for an EPUB (ADR-0021), and kept by the core in a hidden `.details` file in the Document's folder and derives the Title and percentage read from them. They are never synced: every Device reads them from the same File, and Remove takes them along with the folder.

## Considered Options

- **Kept by each client** (the former `Details.json`): every client repeats the store and the rules derived from it.
- **Synced in the Library document**: saves each new Device one read per File, but changes the synced format, and clients with different PDF engines could overwrite each other's reading.
