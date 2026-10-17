# File Import & Removal

Status: ready-for-agent

Feature §2 of `docs/features.md`. Terms per `GLOSSARY.md`. Storage layout per ADR-0012.

## Problem Statement

The Gallery only shows a bundled sample Document. I can't bring my own PDFs into LeafPDF, and I can't get rid of Documents I no longer want.

## Solution

I Import one PDF at a time with a "+" in the Gallery or File > Import… (⌘O). LeafPDF copies it, unchanged, into its local Library folder and opens it in the Reader. The same File can't be Imported twice. I Remove a Document from its context menu after confirming. The sample Document is gone.

## User Stories

1. As a reader, I want a "+" button in the Gallery toolbar, so that I can Import a PDF.
2. As a Mac or iPad reader, I want File > Import… with ⌘O, so that I can Import from the keyboard.
3. As a reader, I want Import… to work while I'm in the Reader, so that I don't have to go back to the Gallery first.
4. As a reader, I want the file picker to offer only PDFs, so that I can't pick something LeafPDF can't read.
5. As a reader, I want to Import exactly one File at a time, so that every Import has one clear outcome.
6. As a reader, I want the imported File stored unchanged, so that my PDF stays exactly as it was.
7. As a reader, I want the File copied into LeafPDF's own Library folder, so that the Document stays readable even if I delete or move the original.
8. As a reader, I want the Document to open in the Reader right after Import, so that I can start reading at once.
9. As a reader in the Reader, I want a new Import to replace the open Document, so that I end up looking at what I just Imported.
10. As a reader, I want a progress bar with the Title while a large File is Imported, so that I know LeafPDF is working and not frozen.
11. As a reader, I want the rest of the UI disabled during an Import, so that nothing else happens halfway through.
12. As a reader, I want no progress modal for quick Imports, so that small Files don't flash a progress bar.
13. As a reader, I want the app to stay responsive (no beachball) during an Import, so that it never looks broken.
14. As a reader, I want an alert when I Import a File that's already in my Library, so that I know nothing was copied.
15. As a reader, I want an "Open" button on that alert, so that I can jump to the Document that's already there.
16. As a reader, I want the same PDF to be recognised as a duplicate even under a different file name, so that my Library has no copies.
17. As a reader, I want a File that isn't a readable PDF to be rejected with an alert, so that broken Documents never reach my Library.
18. As a reader, I want password-protected PDFs rejected with a clear alert, so that I know they aren't supported yet.
19. As a reader, I want PDFs that only restrict permissions to Import normally, so that I can still read them.
20. As a reader, I want a "Couldn't import 'X'" alert with the system's reason when copying fails, so that I understand what went wrong.
21. As a reader, I want a failed Import to leave nothing behind, so that my Library never holds half-copied Files.
22. As a reader, I want an Import cut short by a crash to leave no trace, so that the Gallery never shows a broken Document.
23. As a reader, I want a Document without a stored title to show its original file name, so that I recognise it.
24. As a reader, I want the Gallery to list my Documents with the newest Import first, so that what I just added is at the top.
25. As a new user, I want an empty Gallery to say "No Documents" with an "Import…" button, so that I know how to start.
26. As an iPhone or iPad reader, I want to long-press a Document and choose "Remove", so that I can take it out of my Library.
27. As a Mac reader, I want to right-click a Document and choose "Remove", so that I can take it out of my Library.
28. As a reader, I want to confirm before a Document is Removed, so that I don't lose it by accident.
29. As a reader, I want the confirmation to say that markup and reading progress go too, on all my devices, so that I know what Removing means.
30. As a reader, I want Removing to delete the File and everything recorded about it, so that nothing is left over.
31. As a reader, I want a Remove cut short by a crash to finish cleanly, so that a Document is either fully there or fully gone.
32. As a reader, I want to Import a Document again after Removing it, so that I can change my mind.
33. As a Mac or iPad reader with several windows, I want a window that's reading a Removed Document to return to the Gallery, so that it never shows a Document that no longer exists.
34. As that reader, I want an alert "'X' was removed from your Library", so that I understand why the window changed.
35. As a reader, I want the sample Document gone, so that the Gallery shows only my own Documents.

## Implementation Decisions

- **Core `Library` module** (new, first real core logic). This is the only part of the system that touches the Library folder.
  - `open(root)`: opens the Library at a folder chosen by the client and cleans up leftover staging and removal folders.
  - `import(source path, progress callback)`:
    - streams the source once, computing SHA-256 while copying into a staging folder inside the root;
    - reports bytes copied out of the total;
    - renames into place at `<root>/<sha256>/<original file name>` (ADR-0007, ADR-0012);
    - returns `Imported(id)` or `AlreadyImported(id)` and copies nothing for a duplicate;
    - on any error, removes the staging folder and returns the error.
  - `documents()`: the Library, newest Import first, ordered by the creation time of each Document's folder. Each entry has its ID and its stored File's path.
  - `remove(id)`: renames the Document's folder out of the Library, then deletes it.
  - The core doesn't care about file formats and never parses PDFs (ADR-0003). New dependency: `sha2` only.
- **FFI** exposes `Library` as a UniFFI object. Progress is a UniFFI callback interface implemented in Swift. Errors map to one FFI error carrying the system message.
- **Library folder**: hidden in Application Support. Not visible in Files or Finder.
- **Client Library model** (Swift, observable, one per app, shared by all windows):
  - wraps the core `Library` and exposes `documents`;
  - provides `import(url) async -> outcome` and `remove(document)`.
  - `import`:
    1. gets access to the security-scoped URL;
    2. checks the File with PDFKit: it must open, and it must not be locked (owner-password-only PDFs pass);
    3. then calls the core off the main thread.
  - Outcomes: `opened(Document)`, `duplicate(Document)`, `rejected(.notPDF | .unreadable | .locked)`, `failed(message)`.
- **No Automerge yet.** The folder is the Library until sync needs a Library document (ADR-0008, ADR-0012).
- **UI**:
  - Gallery toolbar "+".
  - A File menu "Import…" with ⌘O, replacing "New", via `.commands` (macOS and iPadOS).
  - `fileImporter` restricted to PDF, with single selection.
- **During Import**: the whole UI is disabled at once. After about 0.5 s, a modal shows a determinate progress bar and the Title. There is no Cancel.
- **After Import**:
  - `opened` pushes the Reader, replacing a Document that is already open.
  - `duplicate` shows an alert with "Open".
  - `rejected` and `failed` show alerts ("Password-protected PDFs aren't supported yet", "Couldn't import 'X'" plus the system message).
- **Remove**:
  - A `.contextMenu` "Remove" on Gallery rows (long-press on iOS, right-click on macOS), then a destructive confirmation dialog naming the Title.
  - Any window showing that Document returns to the Gallery and shows "'X' was removed from your Library".
- **Gallery** stays a placeholder list (the grid comes with §3). An empty Library shows `ContentUnavailableView` with an "Import…" button.
- **Sample removal**: delete the sample Document, its bundled PDF and every `// TEMPORARY: remove with File Import (features §2)` marker.

## Testing Decisions

- Test only external behaviour through the two seams below, against real files. No mocks.
- **Core `Library`**: Rust tests inside the source file, run against temporary folders. They cover:
  - the stored File is byte-identical and keeps its original name;
  - duplicates are detected, also under a different name, and nothing is copied;
  - progress reaches the total;
  - a failing Import (e.g. missing source) leaves the root unchanged;
  - newest-first order;
  - Remove deletes the Document, and re-Importing it works;
  - leftover staging and removal folders are cleaned up on open.
- **Client Library model**: Swift Testing with the real `LeafCore`. It covers:
  - outcomes for a normal, a locked and a garbage-bytes File, plus a duplicate;
  - the Title falls back to the original file name after Import;
  - a Removed Document disappears from `documents`.
  - Prior art: the temporary-PDF helper in the Document Title tests.
- The existing FFI smoke test stays.
- **Manual checks on iPhone, iPad and Mac**:
  - the progress modal delay and the disabled UI;
  - the alert wording and buttons;
  - long-press and right-click Remove;
  - Removing while another window reads the Document;
  - ⌘O from the Reader.

## Out of Scope

- Importing several Files at once, and cancelling an Import.
- Unlocking password-protected PDFs.
- Formats other than PDF (.epub, .mobi).
- A Library folder visible to users.
- The Gallery grid with first-page thumbnails (§3).
- Removing on other devices and the Library document (§8).
- Import from outside the app (§9).

## Further Notes

- Removal reaching all devices, and re-Import after Remove, are §8 concerns. A removal marker must not block re-importing the same hash.
- `make apple-core` is needed after the core changes (ADR-0006).
