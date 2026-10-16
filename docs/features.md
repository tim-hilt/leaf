# Features

The application should provide the following features

## Miscellaneous / Basic

- UI supports Portrait and Landscape Mode
- Zooming
- Continuous scrolling
- Table of Contents (TOC) are shown, user can jump to chapters from TOC menu
- Realtime full text search
- save reading progress

## File Import

Files are registered in the application. This can happen from within the application by clicking a "+" Icon in the UI, clicking "File > Import" in the global menu. It can also happen from outside via the "Share" function in mobile clients or the context menu + "Open With" menu entry on desktop clients.

Importing a file syncs it to the cloud immediately and copies the file to the shared storage location. A file can only be imported once.

## File Gallery

The file gallery renders the first page and title of all imported files in a vertically scrollable grid. The first entry is an empty cell with a "+" icon - another way to import files. Clicking on any imported file opens it up in reading mode.

## Markup

Markup is not saved inside the file, but as external metadata that is rendered on top of the pdf file. This saves bandwidth and keeps syncing lightweight. This is especially important for mobile clients. Additionally, this helps to keep the pdf size original

The following markup features should be supported.

- Highlight text in different colors
- Add popup note to highlight
- Place note freely on the page

## Cloud backing

- Providers
    - Google Drive
    - OneDrive
    - iCloud (only for iOS, iPadOS, MacOS)

Only one cloud provider can be connected at a time. After successfully connecting a provider, the application searches for a directory with a special name in the cloud storage. This directory contains files, that are already synced. They are downloaded immediately along with their reading progress and markup. An updating progress bar shows the syncing progress. After the initial syncing, only markup and reading progress are synced.

## Theme

The clients should offer settings for using a light theme, dark theme or complying with the system theme. When the dark theme is active, The pdf colors are reversed: The background is dark while the foreground is light.

