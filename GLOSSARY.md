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

**Table of Contents**:
The Chapters and Sections stored in a Document, in reading order.
_Avoid_: TOC, outline, bookmarks

**Chapter**:
A top-level entry in the Table of Contents, pointing to a place in the Document.
_Avoid_: Bookmark, outline item

**Section**:
An entry in the Table of Contents nested under a Chapter or another Section, at any depth.
_Avoid_: Subchapter, subsection

**Reader**:
The view in which a single Document is read.
_Avoid_: Reading mode, viewer

**Jump**:
Moving to another place in a Document by choosing a Chapter, Section, Document Search match or link, rather than by scrolling.
_Avoid_: Navigate, go to

**Back**:
Returning to where the reader was before the latest Jump.
_Avoid_: Undo, history, Go to Gallery

**Go to Gallery**:
Leaving the Reader for the Gallery.
_Avoid_: Back, close

**Immersive Mode**:
A state of the Reader in which everything except the Document's pages is hidden.
_Avoid_: Reading mode, focus mode, full screen

**Reading Progress**:
Where in a Document the user last left off. It moves back if the user goes back.
_Avoid_: Bookmark, position, furthest page

**Last Read**:
When the Reader last showed a Document.
_Avoid_: Last opened, recently opened

**Theme**:
Whether LeafPDF looks light or dark: System, Light or Dark.
_Avoid_: Appearance, dark mode, color scheme

**Page Style**:
How a Document's pages are shown: Light Pages, Dark Pages, or Match Theme, which follows the Theme.
_Avoid_: Page theme, page color, page mode

**Light Pages**:
Showing a Document's pages in their original colors.
_Avoid_: Normal, original mode

**Dark Pages**:
Showing a Document's pages with their brightness reversed, in Page Colors.
_Avoid_: Invert, night mode

**Page Colors**:
The paper and ink colors the user picks for Dark Pages.
_Avoid_: Palette, page theme
