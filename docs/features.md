# Features

The application should provide the following features. Sections are in implementation order: each builds only on earlier ones.

## 1. Reading

- Continuous scrolling
- Zooming
- UI supports Portrait and Landscape Mode

## 2. File Import (in-app)

Files are registered in the application by clicking a "+" Icon in the UI or "File > Import" in the global menu. The file is copied to the shared storage location. A file can only be imported once.

Removes the temporary sample Document added by Reading.

## 3. File Gallery

The file gallery renders the first page and title of all imported files in a vertically scrollable grid. The first entry is an empty cell with a "+" icon - another way to import files. Clicking on any imported file opens it up in reading mode.

## 4. Reading Progress

- Save reading progress

First piece of synced state; establishes the local Automerge model (ADR-0008) before markup and cloud depend on it.

## 5. Navigation

- Table of Contents (TOC) are shown, user can jump to chapters from TOC menu
- Realtime full text search

## 6. Theme

The clients should offer settings for using a light theme, dark theme or complying with the system theme. When the dark theme is active, The pdf colors are reversed: The background is dark while the foreground is light.

Comes before markup so overlays are designed for both themes from the start.

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
