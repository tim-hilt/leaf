# Features

The application should provide the following features. Sections are in implementation order: each builds only on earlier ones.

## 1. Reading

- Continuous scrolling
- Zooming
- UI supports Portrait and Landscape Mode

## 2. File Import & Removal (in-app)

Files are imported by clicking a "+" Icon in the UI or "File > Import" in the global menu. The file is copied unchanged into a local folder on the device that holds the whole Library (local-first). A file can only be imported once.

Documents are removed by long pressing (mobile) or right clicking (desktop) and choosing "Remove" from the context menu, after a confirmation. Removing deletes the File and everything recorded about it, on all devices with Cloud Backing. The same File can be imported again afterwards.

Removes the temporary sample Document added by Reading.

## 3. Gallery

The Gallery shows the Cover and Title of every Document in a vertically scrollable grid. The first cell is a "+", another way to Import. Clicking a Document opens it in the Reader.

- Sort by Date Imported or Title
- Library Search by Title, file name or Author
- Arrow keys move a highlight through the grid

## 4. Reading Progress

- Reopening a Document returns to its Reading Progress
- The Gallery shows each Document's Reading Progress as a bar and a percentage on its Cover
- Sort by Recently Read (Last Read)
- Reading Progress and Last Read sync across devices; on conflict the newest Last Read wins

First piece of synced state; establishes the local Automerge model (ADR-0008) before markup and cloud depend on it.

## 5. Navigation

- Table of Contents: Chapters and Sections with printed page numbers, current one in bold; choosing one Jumps there
- Document Search: native find bar, updates as you type, with the system's "Full word" and case options, plus a results list
- Back: after a Jump (Chapter, Section, search or link), a "Back to p. 42" capsule returns to where you were

## 6. Theme

- Theme: System, Light or Dark, for the interface
- Page Style: Light Pages (default), Dark Pages or Match Theme, as three circles (titled "Dark Page Style" in the popover); Page Colors show only with Dark Pages
- Dark Pages reverse brightness but keep hue, in adjustable Page Colors; the File never changes
- Settings (⌘, on macOS, Gallery gear on iOS) and a Reader cog popover; macOS View menu and ⇧⌘D
- Covers always show their original colors
- All per device, not synced

Comes before markup so overlays are designed for Light and Dark Pages from the start.

## 7. Markup

Markup is never written into the File: it lives in the Document's synced state and is drawn over the pages, so syncing stays light and the File keeps its size.

- Highlight: select text, then "Highlight" in the selection menu or ⌃⌘H (macOS). New Highlights get the Default Highlight Color. A Highlight may span pages; overlapping Highlights stay separate.
- Clicking a Highlight opens a popover (sheet on iPhone): Highlight Colors, its Note, "Remove Highlight". Dragging still selects text.
- Notes are plain text; web links open in the browser. An "Edit" button switches the Note to editing, where links are plain text. A Highlight with a Note shows a Note icon at its end, on the top-right corner of its last line. Emptying a Note removes it.
- Page Notes: right-click or long-press an empty spot, "Add Note". They can't be moved; their popover has "Remove Note".
- Note icons keep their size at any zoom and their colors on Dark Pages; Highlights are reversed with the page.
- Settings: Highlight Colors. Yellow, green, blue, pink, purple and red are fixed; Custom Colors, any number, are added with "+" and removed via their context menu. Pick the Default Highlight Color (yellow). Both sync (ADR-0014); removing a Custom Color leaves its Highlights as they are, their popover shows the color as an extra circle.
- Annotations already in the File show as they are, read-only. Covers show no Markup.
- Not included: other markup styles, undo, a Markup list, export, hiding Markup.

## 8. Cloud Backing (WebDAV)

Cloud Backing is off until the user Connects a Cloud Provider in Settings; only one is Connected at a time. The first Cloud Provider is WebDAV, for self-hosting (e.g. `rclone serve webdav` on a Raspberry Pi behind a Cloudflare Tunnel, see `docs/self-hosting.md`): Server URL (https only), username and password. LeafPDF keeps everything in a `LeafPDF` folder inside that URL.

- Connecting merges the Device's Library with the one in the cloud; nothing is lost. Files download right away, most recently read first; a Document appears once its File is there.
- The Library, Reading Progress, Markup and Highlight Colors keep Syncing: a few seconds after a change, on launch and foreground, and every 10 seconds while in the foreground. Importing uploads the File.
- A Remove wins over concurrent edits and frees the cloud storage. Importing the File again starts fresh.
- An open Reader keeps its place; new Markup shows up live. A Document Removed elsewhere closes its Tab.
- While Files transfer, the Gallery shows "Syncing 12 of 120 Documents". Settings shows the status; a blocked Sync (wrong password, LeafPDF needs an update) adds a warning icon to the Gallery.
- Disconnect keeps everything and forgets the credentials. Switching Cloud Provider Disconnects first, after a confirmation.

## 9. File Import (external)

Files can also be Imported from outside: the share sheet on iOS and iPadOS, "Open With" and the Dock icon on macOS, and dropping onto the Gallery. LeafPDF only declares that it opens PDFs and EPUBs (on macOS as an Alternate handler, never the default). There are no extension targets; the in-app import pipeline is reused. A Share Extension would need an App Group for the Library folder, would have two processes writing the Library state, and would lack the progress modal, alerts and Reader.

- Each file opens in a new Tab next to the open ones. A single file already in the Library opens its Tab with Open With or Share; "+" and a drop show "Already in your Library" with "Open".
- Several files are Imported one after another and each opens in a Tab, the first one active. Duplicates open (or switch to) their Tab; rejections are listed in one alert. "+" accepts several files too.
- The one window takes the file and closes sheets. A file that arrives during an Import waits its turn.
- Drops get the system highlight and are accepted on the Gallery only, not in the Reader.
- PDFs and EPUBs (section 12); MOBI may follow.

## 10. More Cloud Providers

Same Cloud Backing as section 8, other storage, in order:

1. Folder: a folder picked in Files or Finder, e.g. in iCloud Drive (no paid Apple Developer membership needed)
2. Google Drive
3. OneDrive: reuses the HTTP + OAuth groundwork from Google Drive

## 11. Tabs

One window on iPhone, iPad and Mac (ADR-0018). The Reader keeps several Documents open as Tabs, in a strip under the toolbar. Tabs are per Device, not synced, and come back after relaunch with the active Tab and whether the Reader or the Gallery was showing.

- Opening a Document from the Gallery adds a Tab at the end, or switches to its Tab. Each Tab shows its Title, truncated, and an (x); the active one is emphasized.
- The strip shows from 2 Tabs, fits 2–3 on an iPhone in portrait and scrolls sideways beyond that. Immersive Mode hides it.
- Closing the active Tab shows the one to its right, else its left; closing the last goes to the Gallery. Closing leaves the Document in the Library.
- Go to Gallery (back chevron, edge swipe) keeps the Tabs; the Gallery's "Reader" button (`book`) returns to the active one while any are open.
- Only the active Tab is loaded and saves Reading Progress and Last Read. A Tab you come back to keeps its place, zoom and Back capsule (in memory only); a new or restored Tab opens at its Reading Progress at fit-to-width. The find bar and popovers close when switching.
- ⌘W closes the active Tab (nothing in the Gallery), ⌃Tab and ⌃⇧Tab switch to the next and previous Tab, ⌘1–⌘9 pick a Tab by position. On Mac they sit in the Window menu.
- A Removed Document closes its Tab silently.
- VoiceOver announces each Tab's Title and selection, with a Close action.
- Not included: reordering, "Close Other Tabs", a Tab overview, several windows.

## 12. EPUB

EPUBs behave like PDFs in every section above, except as listed. The core reads the EPUB (ADR-0021); the Reader draws it in the system web view.

- Reflowable EPUBs only. Fixed-layout, DRM-protected and invalid EPUBs are rejected at Import, in the same alert as other rejections.
- One continuous vertical scroll through all Chapters. Zooming changes the text size, which reflows; one text size per Device, not synced.
- The book's own fonts and layout are kept, with a fixed side margin. Page Style and Page Colors are shared with PDFs; Dark Pages show the text and background in Page Colors, images unchanged.
- Cover: the EPUB's cover image, else the first image of the first Chapter, else a plain Cover with Title and Author.
- No page numbers: the Table of Contents lists Chapters and Sections without them, and Back reads "Back to <Chapter>". Reading Progress is a percentage of the text.
- Document Search runs in the core's text of the Chapters; the results list has no page numbers.
- Page Notes attach to a spot in the text, their icon in the margin at that line.
- Markup and Reading Progress are anchored in the text (ADR-0022).
- Not included: fixed layout, the EPUB's printed page list, font or spacing settings.

