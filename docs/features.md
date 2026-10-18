# Features

The application should provide the following features. Sections are in implementation order: each builds only on earlier ones.

## 1. Reading

- Continuous scrolling
- Zooming
- UI supports Portrait and Landscape Mode

## 2. File Import & Removal (in-app)

Files are imported by clicking a "+" Icon in the UI or "File > Import" in the global menu. The file is copied unchanged into a local folder on the device that holds the whole Library (local-first). A file can only be imported once.

Documents are removed by long pressing (mobile) or right clicking (desktop) and choosing "Remove" from the context menu, after a confirmation. Removing deletes the File and everything recorded about it, on all devices once Cloud Backing exists. The same File can be imported again afterwards.

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
- Page Style: Light Pages (default), Dark Pages or Match Theme, as three circles
- Dark Pages reverse brightness but keep hue, in adjustable Page Colors; the File never changes
- Settings (⌘, on macOS, Gallery gear on iOS) and a Reader cog popover; macOS View menu and ⇧⌘D
- Covers follow Page Style
- All per device, not synced

Comes before markup so overlays are designed for Light and Dark Pages from the start.

## 7. Markup

Markup is not saved inside the file, but as external metadata that is rendered on top of the pdf file. This saves bandwidth and keeps syncing lightweight. This is especially important for mobile clients. Additionally, this helps to keep the pdf size original

1. Highlight text in different colors
2. Add popup note to highlight
3. Place note freely on the page

## 8. Cloud Backing

Only one cloud provider can be connected at a time. After successfully connecting a provider, the application searches for a directory with a special name in the cloud storage. This directory contains files, that are already synced. They are downloaded immediately along with their reading progress and markup. An updating progress bar shows the syncing progress. After the initial syncing, only markup and reading progress are synced.

Importing a file syncs it to the cloud immediately.

Providers, in order:

1. iCloud (only for iOS, iPadOS, MacOS): no OAuth, and Apple is the only client today
2. Google Drive
3. OneDrive: reuses the HTTP + OAuth groundwork from Google Drive

## 9. File Import (external)

Files can also be imported from outside via the "Share" function in mobile clients or the context menu + "Open With" menu entry on desktop clients. Reuses the in-app import pipeline; needs extra app extension targets.
