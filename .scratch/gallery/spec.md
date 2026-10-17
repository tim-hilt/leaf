# Gallery

Status: ready-for-agent

Feature §3 of `docs/features.md`. Terms per `GLOSSARY.md`. Builds on `.scratch/file-import/spec.md`.

## Problem Statement

The Gallery is a plain list of Titles. I can't recognise Documents at a glance, I can't sort them, and once my Library grows I can't find a Document quickly. It also opens every PDF at launch, which won't stay fast with a large Library.

## Solution

The Gallery shows every Document as its Cover with its Title underneath, in a vertically scrollable grid. The first cell is a "+" that Imports. One click or tap opens a Document in the Reader. I can sort by Date Imported or Title, find Documents with Library Search (Title, file name, Author), and move through the grid with arrow keys. It stays snappy with 1,000 Documents.

## User Stories

### Grid

1. As a reader, I want each Document shown as its Cover with its Title underneath, so that I recognise it at a glance.
2. As a reader, I want the Gallery to scroll vertically, so that I can browse a large Library.
3. As an iPhone reader, I want 2 columns in portrait and more in landscape, so that Covers stay large enough to recognise.
4. As an iPad or Mac reader, I want more columns as the window gets wider, so that I use the space I have.
5. As a reader, I want every cell to have the same page shape, so that the grid looks tidy.
6. As a reader, I want a Cover that's wider than the cell's shape to be scaled to fit and to sit on the cell's bottom edge, so that Titles line up in each row.
7. As a reader, I want the space above such a Cover to be transparent, so that nothing fake is drawn around my Document.
8. As a reader, I want Titles shown on up to 2 lines, cut off at the end with "…", so that long Titles don't break the grid.
9. As a reader, I want 2 lines reserved even for short Titles, so that Covers line up across each row.
10. As a reader, I want one click or tap on a Document to open it in the Reader, on every platform, so that opening is quick.
11. As a reader, I want to go back to the Gallery where I left it, so that I don't lose my scroll position.

### "+" cell

12. As a reader, I want the first cell to be a "+", so that I can Import right from the grid.
13. As a reader, I want the "+" cell to be a grey cell of the same shape with a white "+" in the centre and "Import…" underneath, so that it fits into the grid.
14. As a reader, I want the toolbar "+" and File > Import… (⌘O) to keep working, so that I can Import when the "+" cell has scrolled away or while I'm in the Reader.
15. As a new user, I want an empty Library to show the grid with only the "+" cell, so that I see the same Gallery as later and know how to start.

### Covers

16. As a reader, I want a grey placeholder with the Title already visible until a Cover is ready, and then the Cover fading in, so that the grid never looks broken.
17. As a reader, I want Covers rendered only for the cells I look at, so that a large Library doesn't slow down my device.
18. As a reader, I want new Covers rendered only after I stop scrolling, so that fast scrolling stays smooth.
19. As a reader, I want Covers I've seen before to show at once, even while scrolling, so that the Gallery feels instant.
20. As a reader, I want a Document I just Imported to have its Cover ready right away, so that it never shows a placeholder.
21. As a reader, I want Covers kept across launches, so that they aren't rendered again every time.
22. As a reader, I want Covers that the system removed to free space to be rendered again when needed, so that I never lose a Cover for good.
23. As a reader, I want Covers to stay sharp when I rotate the device or resize the window, without being rendered again.
24. As a reader, I want a Removed Document's Cover deleted too, so that nothing is left over.
25. As a reader, I want Covers never synced to the cloud, so that syncing stays light.

### Titles at scale

26. As a reader with 1,000 Documents, I want the Gallery to launch quickly, so that I can start reading at once.
27. As a reader, I want a Document's Title saved when I Import it, so that it's available without opening the PDF.
28. As a reader updating from a version without saved Titles, I want the missing Titles read once in the background, so that sorting and searching become complete without blocking me.
29. As a reader, I want a Document whose Title isn't read yet to show and sort by its file name, so that it's never missing from the Gallery.
30. As a reader, I want a Document to move to its new place with the native animation when its Title arrives, so that the change is easy to follow.

### Sorting

31. As a reader, I want the Gallery sorted by Date Imported, newest first, by default, so that what I just added is at the top.
32. As a reader, I want to sort by Title, A–Z, so that I can find Documents alphabetically.
33. As a reader, I want Title sorting to work like Finder ("2" before "10", ignoring case and accents), so that the order looks natural.
34. As a reader, I want to reverse either order, so that I can see the oldest Imports or Z–A.
35. As a reader, I want the sort choice in a toolbar menu like the Files app, so that it feels native.
36. As a reader, I want the sort choice remembered on this device across launches and shared by all windows, so that I set it once.
37. As a reader, I want the "+" cell to stay first whatever the order, so that Import is always in the same place.

### Library Search

38. As a reader, I want a native search field in the Gallery, so that I can find a Document quickly.
39. As a reader, I want Library Search to match parts of the Title, the original file name or the Author, so that I find a Document however I remember it.
40. As a reader, I want Library Search to ignore case and accents, so that "resume" finds "Résumé".
41. As a reader, I want results to update as I type, so that I see matches right away.
42. As a Mac or iPad reader, I want ⌘F to focus the search field, so that I can search from the keyboard.
43. As a reader, I want the "+" cell to stay visible while searching, so that I can Import a Document I didn't find.
44. As a reader, I want a search with no matches to show the "+" cell followed by "No Results for 'x'", so that I know nothing matched and can Import right away.
45. As a reader, I want results in the current sort order, so that searching doesn't change how things are ordered.

### Keyboard

46. As a Mac or iPad keyboard reader, I want arrow keys to move a highlight through the grid, including the "+" cell, so that I can browse without a pointer.
47. As a keyboard reader, I want nothing highlighted until I first press an arrow key, so that clicking and tapping work as before.
48. As a keyboard reader, I want Return to open the highlighted Document, or to Import when the "+" cell is highlighted, so that I can act from the keyboard.
49. As a keyboard reader, I want ⌘⌫ to ask to Remove the highlighted Document, so that I can Remove from the keyboard.
50. As a keyboard reader, I want ↓ in the search field to highlight the first matching Document, so that ⌘F, type, ↓, Return opens a Document.
51. As a keyboard reader, I want the Document I just read to be highlighted when I come back from the Reader, so that I can carry on from there.
52. As a keyboard reader, I want the highlight to stay where it is at the grid's edges and in the last, partial row, so that it never jumps somewhere unexpected.

### Removal and accessibility

53. As a reader, I want Remove in each cell's context menu (long-press, right-click), with the existing confirmation, so that Removal works as before.
54. As a VoiceOver user, I want each cell read as its Title and treated as a button that opens the Reader, so that I can navigate the Gallery.
55. As a VoiceOver user, I want Remove offered as an action on each cell, so that I can Remove without a context menu.
56. As a VoiceOver user, I want the "+" cell read as "Import…", so that I know what it does.

## Implementation Decisions

- **No core changes.** Covers, Titles, Authors, sorting and Library Search are all client-side (PDFKit and Apple's string comparison). The core still never parses PDFs (ADR-0003). The Library folder layout is unchanged (ADR-0012).
- **Client Library model** (extended):
  - A Document no longer holds an open PDF. It exposes its ID, its stored File's location, its original file name, and its saved Title and Author if known.
  - The Title shown is the saved Title, or the file name without extension until the Title has been read. This keeps the glossary's rule: the PDF's title, or the file name if it has none.
  - The PDF is opened only when the Reader shows the Document.
  - The model exposes the sort choice and the visible Documents for a Library Search text. The search text belongs to each window, like the search field. The "+" cell isn't part of the model.
  - Library Search uses `localizedStandardContains` on the Title, the original file name and the Author. Title sorting uses `localizedStandardCompare`. Date Imported uses the core's newest-first order, reversed when asked.
  - The sort choice is stored per device (user defaults), shared by all windows and not synced.
  - Import (after the existing PDFKit check, with the PDF already open) saves the Title, Author and Cover before reporting the outcome.
  - Remove also deletes the Document's saved Title, Author and Cover.
- **Saved Titles and Authors**: one small store in Application Support, outside the Library folder, keyed by Document ID and never synced. At launch, a low-priority background pass reads missing entries one Document at a time and publishes each as it arrives.
- **Covers**:
  - Saved in the system Caches folder, keyed by Document ID. They never go stale, because Files never change (ADR-0007). Never synced.
  - The model offers an async way to get a Cover: it loads the saved Cover, or renders page 1 with PDFKit off the main thread, saves it and returns it.
  - One fixed size: about 300 pt wide at the device's screen scale. Smaller cells scale it down; nothing is rendered again on resize or rotation.
  - Rendering only. If a Cover can't be rendered, the placeholder stays. A File that won't open can't be Imported, so there's no special handling.
- **Gallery grid**:
  - A lazy vertical grid with adaptive columns (minimum about 140 pt).
  - Each cell is A4 portrait (1 : 1.414). The Cover is scaled to fit and sits on the cell's bottom edge; the space above it is transparent.
  - Below the Cover is the Title: 2 lines reserved, cut off at the end.
  - The placeholder and the "+" cell use the same grey. The "+" cell has a white "+" and "Import…" underneath.
  - The `ContentUnavailableView` for an empty Library goes away: an empty Library shows the grid with only the "+" cell.
  - Toolbar "+", File > Import… (⌘O), the context-menu Remove with confirmation, and returning to the Gallery when a Document is Removed in another window all stay as they are.
- **Cover loading in the grid**:
  - Saved Covers load as soon as a cell appears.
  - New renders are queued for visible cells only, and start once scrolling has been still for a short moment (about 150 ms).
  - Requests for cells that scrolled away are dropped.
  - Covers fade in.
- **Toolbar**:
  - a sort menu: Date Imported or Title, plus a reverse toggle;
  - a native `.searchable` field. ⌘F focuses it on Mac and iPad.
  - When nothing matches, show the "+" cell followed by "No Results for 'x'".
- **Grid highlight** (new, pure value type):
  - Takes the current highlight (or none), the column count, the cell count (including "+") and an arrow key, and returns the new highlight.
  - The first arrow press highlights the first cell. Moves past an edge stay put. ↓ into the last, partial row goes to its last cell.
  - The view adds the rest:
    - Return opens the highlighted Document or Imports;
    - ⌘⌫ starts Remove;
    - ↓ from the search field highlights the first matching Document;
    - the highlight is scrolled into view;
    - returning from the Reader highlights the Document that was open (if highlighting was in use).
  - Click or tap opens on every platform; there's no click-to-select.
- **Accessibility**: each cell is a button labelled with its Title, with Remove as an accessibility action. The "+" cell is labelled "Import…".

## Testing Decisions

- Test only external behaviour through the two seams below, against real files. No mocks.
- **Client Library model** (Swift Testing with the real `LeafCore`, like the existing Library model tests and their temporary-PDF helper). It covers:
  - after Import, the Document has its Title, file name and Author, and a Cover is available without rendering;
  - Titles and Authors survive reopening the Library;
  - with the saved Titles missing, Documents first show their file names and then get their Titles from the background pass;
  - a Cover is rendered again after its saved copy is deleted;
  - Remove deletes the saved Title, Author and Cover;
  - sorting: Date Imported in both directions; Title in both directions, Finder-like ("2" before "10");
  - Library Search matches Title, file name and Author, ignoring case and accents, and keeps the sort order;
  - opening the Library opens no PDFs (Documents carry no open PDF).
  - The temporary-PDF helper gains an Author parameter.
- **Grid highlight** (Swift Testing, pure, like the `ZoomRange` tests). It covers:
  - the first press;
  - moves in all four directions;
  - staying put at the edges;
  - the last, partial row;
  - a single cell (only "+");
  - the column count changing.
- Existing Rust, FFI and Library model tests stay green.
- **Manual checks on iPhone, iPad and Mac:**
  - smooth scrolling with a few hundred real PDFs;
  - renders only after scrolling stops, and saved Covers showing while scrolling;
  - the fade-in;
  - grid layout, wide Covers with a transparent gap, Title alignment;
  - rotation and window resizing;
  - the keyboard flow (arrows, Return, ⌘⌫, ⌘F, ↓);
  - VoiceOver;
  - the empty Library and a search with no matches.

## Out of Scope

- Highlighting or selecting several Documents (removing several at once, opening several in tabs).
- Pinch to change cell size.
- Reading Progress on Covers, and a "Recently Read" sort (§4).
- Dark-theme Covers (§6).
- Searching full text across Documents. Document Search is §5.
- Showing the Author in cells.
- Covers from any page other than the first.

## Further Notes

- `docs/features.md` §3 and `GLOSSARY.md` (Cover, Author, Library Search, Document Search) were updated during the grilling.
- Target: snappy with 1,000 Documents.
- Saved Titles live in Application Support rather than Caches because sorting and Library Search need every Title right away.
