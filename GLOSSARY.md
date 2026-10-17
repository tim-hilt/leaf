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

**Author**:
The author stored in the PDF, if any.
_Avoid_: Creator

**Library**:
The set of Documents the user has imported.
_Avoid_: Collection, Gallery (when meaning the set)

**Import**:
Copying a File into LeafPDF, which adds a Document to the Library.
_Avoid_: Add, upload, open

**Remove**:
Taking a Document out of the Library, along with its File and everything recorded about it.
_Avoid_: Delete

**Gallery**:
The view showing the Library.
_Avoid_: File gallery, home

**Cover**:
The image of a Document's first page, shown for it in the Gallery.
_Avoid_: Thumbnail, preview, first page

**Library Search**:
Finding Documents in the Gallery by Title, file name or Author.
_Avoid_: Search (unqualified), filter

**Document Search**:
Finding text inside a single Document.
_Avoid_: Search (unqualified), find

**Reader**:
The view in which a single Document is read.
_Avoid_: Reading mode, viewer

**Immersive Mode**:
A state of the Reader in which everything except the Document's pages is hidden.
_Avoid_: Reading mode, focus mode, full screen

**Reading Progress**:
Where in a Document the user last left off. It moves back if the user goes back.
_Avoid_: Bookmark, position, furthest page

**Last Read**:
When the Reader last showed a Document.
_Avoid_: Last opened, recently opened
