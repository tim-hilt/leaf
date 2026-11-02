# The core owns Import; clients read PDFs through a reader

Amends ADR-0003. The core decides whether a File is Imported. Before it copies a PDF, it asks the client's `PdfReader` (PDFKit on Apple) for the PDF's details, and refuses the PDF if the reader can't open it or it is locked. The core keeps the details. It also lists the PDFs that lack details (e.g. those Synced from another Device, as details are never synced) and reads them through the same reader. A client only schedules those reads in the background and lists the Library after each batch.

## Considered Options

- **Clients check a File and hand over its details**: each client repeats the Import rules: which Files qualify, and which Documents lack details.
- **Parsing PDFs in the core**: rejected by ADR-0003.

## Consequences

- A new client implements `PdfReader` and its scheduling; the rules come from the core.
