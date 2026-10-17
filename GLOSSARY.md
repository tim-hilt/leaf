# LeafPDF

A native PDF reader that syncs reading state across a user's devices.

## Language

**Document**:
A PDF the user has brought into LeafPDF to read.
_Avoid_: PDF, book

**File**:
The stored bytes of a Document, as kept on disk and in cloud storage.
_Avoid_: Document (when meaning the bytes)

**Title**:
The name shown for a Document: the title stored in the PDF, or the file name if the PDF has none.
_Avoid_: Name, filename

**Gallery**:
The view listing all imported Documents.
_Avoid_: Library, file gallery, home

**Reader**:
The view in which a single Document is read.
_Avoid_: Reading mode, viewer

**Immersive Mode**:
A state of the Reader in which everything except the Document's pages is hidden.
_Avoid_: Reading mode, focus mode, full screen
