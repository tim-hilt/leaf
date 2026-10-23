# LeafPDF

A native PDF and EPUB reader that syncs reading state across a user's devices.

## Language

**Document**:
A PDF or EPUB the user has brought into LeafPDF to read.
_Avoid_: PDF, EPUB, book

**Format**:
Which kind of File a Document is: PDF or EPUB.
_Avoid_: Filetype, kind

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
The image shown for a Document in the Gallery: a PDF's first page, or an EPUB's cover image.
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
The view in which the Documents open in Tabs are read, one at a time.
_Avoid_: Reading mode, viewer

**Tab**:
A Document kept open in the Reader, so the user can switch between several. Closing a Tab leaves the Document in the Library.
_Avoid_: Window, open document

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
Showing a Document in its original colors.
_Avoid_: Normal, original mode

**Dark Pages**:
Showing a Document dark, in Page Colors.
_Avoid_: Invert, night mode

**Page Colors**:
The paper and ink colors the user picks for Dark Pages.
_Avoid_: Palette, page theme

**Markup**:
Everything the user adds on top of a Document: Highlights and Notes. Never part of the File.
_Avoid_: Annotation, comments

**Highlight**:
A passage of a Document's text marked in a Highlight Color. It may run across pages and may have a Note.
_Avoid_: Marker, annotation

**Note**:
Text the user writes, belonging either to a Highlight or to a spot in the Document.
_Avoid_: Popup note, comment, sticky note

**Highlight Colors**:
The colors a Highlight can have: six built-in ones, yellow first, plus the user's Custom Colors.
_Avoid_: Palette, Page Colors

**Custom Color**:
A Highlight Color the user added. Unlike the built-in ones, it can be removed.
_Avoid_: User color

**Default Highlight Color**:
The Highlight Color every new Highlight gets. Yellow unless the user picks another.
_Avoid_: Last used color, current color

**Device**:
One installation of LeafPDF.
_Avoid_: Client, installation

**Cloud Backing**:
Keeping the Library in the user's cloud storage so all their Devices share it.
_Avoid_: Cloud sync, backup

**Cloud Provider**:
The service that holds the Library for Cloud Backing: WebDAV, iCloud Drive, Google Drive or OneDrive.
_Avoid_: Backend, storage, service

**Connect**:
Starting Cloud Backing with a Cloud Provider. Its opposite is **Disconnect**, which stops it and keeps everything on the Device.
_Avoid_: Sign in, link, log out

**Reconnect**:
Giving a Connected Cloud Provider access again after it lost it, e.g. a revoked sign-in or a changed password.
_Avoid_: Sign in again, re-authenticate

**Sync**:
Exchanging changes to the Library, Reading Progress, Markup and Highlight Colors with the Cloud Provider.
_Avoid_: Backup, upload
