# Reading Progress

Status: ready-for-agent

Feature §4 of `docs/features.md`. Terms per `GLOSSARY.md`. Builds on `.scratch/reading/spec.md` (Place) and `.scratch/gallery/spec.md`.

## Problem Statement

Every time I open a Document, it starts at page 1, so I have to find my place again. In the Gallery, I can't see how far I've got in a Document or which Documents I read most recently. Once Cloud Backing exists, I want my place to follow me to my other devices.

## Solution

LeafPDF remembers my Reading Progress (where I left off) and when I Last Read each Document. Reopening a Document returns to where I left off. Each Cover in the Gallery shows a thin bar and a percentage of how far through the Document I am. A new "Recently Read" sort lists the Documents I read last at the top. Reading Progress and Last Read are kept in each Document's Automerge document (ADR-0008), ready for Cloud Backing to sync. When two devices disagree, the newest Last Read wins.

## User Stories

### Reopening

1. As a reader, I want a Document to reopen where I left off, so that I can keep reading without searching for my place.
2. As a reader, I want "where I left off" to be the content at the top of the viewport, so that I see the same text I saw last.
3. As a reader, I want a reopened Document to start at fit-to-width, even if I had zoomed in, so that it fits whichever device and window size I'm on.
4. As a reader, I want a Document I've never opened to start at page 1, so that new Documents behave as before.
5. As a reader, I want my Reading Progress to move back when I scroll back, so that reopening returns to where I actually was, not to the furthest page.
6. As a reader, I want my place saved shortly after I stop scrolling, so that a crash or force-quit loses at most a moment of reading.
7. As a reader, I want my place saved when I leave the Reader and when the app goes to the background or quits, so that it's never lost when I switch away.
8. As a reader, I want saving to be invisible and never to interrupt scrolling, so that reading stays smooth.
9. As a reader with the same Document open in two windows, I want the window I used last to decide where I left off, so that the result is predictable.
10. As a reader, I want saving for a Document that was just Removed in another window to do nothing, so that it doesn't come back.

### Gallery indicator

11. As a reader, I want each Document I've opened to show a thin progress bar along the bottom edge of its Cover, so that I see at a glance how far I've got.
12. As a reader, I want the percentage shown as a number in a small capsule in the Cover's bottom-right corner, above the bar, so that I know exactly how far I am.
13. As a reader, I want the capsule on a native material background, so that the number stays readable on both light and dark Covers.
14. As a reader, I want the percentage to be whole percent, rounded down, from the page I'm on, so that "100 %" only shows on the last page.
15. As a reader, I want a Document I've opened but not scrolled to show "0 %", and a Document I've never opened to show nothing, so that I can tell the two apart.
16. As a reader, I want the indicator shown on the grey placeholder too, so that I see my progress before the Cover is ready.
17. As a reader, I want no "Finished" badge or other states, so that the Gallery stays clean.
18. As a reader, I want a Cover that's wider than the cell's page shape to be centred vertically in the cell, so that it looks balanced. The indicator stays at the cell's bottom edge, even if that leaves it floating below a wide Cover.
19. As a reader, I want the indicator correct for Documents I Imported before this feature existed, so that older Documents aren't left out.
20. As a reader coming back from the Reader, I want the indicator already updated, so that it matches where I just left off.
21. As a Mac or iPad reader with the Gallery in another window, I want its indicator and order to update while I read, so that every window agrees.
22. As a VoiceOver user, I want each cell read as its Title followed by "42 % read" when I've opened it, so that I get the same information.

### Recently Read sort

23. As a reader, I want to sort the Gallery by "Recently Read", so that the Documents I'm reading are at the top.
24. As a reader, I want the Document I read last to come first, so that I can continue it in one tap.
25. As a reader, I want opening a Document to count as reading it, even without scrolling, so that it moves to the top right away.
26. As a reader, I want Documents I've never opened listed after all others, in Date Imported order (newest first), so that unread Documents are still easy to find.
27. As a reader, I want to reverse Recently Read to see the Documents I haven't read in longest first, with never-opened Documents still last, so that I can rediscover them.
28. As a reader, I want "Recently Read" in the existing toolbar sort menu next to Date Imported and Title, so that sorting feels the same as before.
29. As a reader, I want the sort choice remembered as before (per device, shared by all windows), so that I set it once.
30. As a reader, I want Date Imported to stay the default sort, so that nothing changes until I choose otherwise.
31. As a reader, I want a Document to move to its new place with the native animation when its Last Read changes, so that the change is easy to follow.
32. As a reader, I want Library Search results in Recently Read order when that sort is chosen, so that searching never changes the order.

### Sync-ready state

33. As a reader with several devices, I want Reading Progress and Last Read stored so that Cloud Backing can sync them, so that I can continue on another device and Recently Read reflects all of them.
34. As a reader who read offline on two devices, I want the device I read on last to win, so that I continue from my most recent place.
35. As a reader, I want Reading Progress removed together with the Document, on every device, so that nothing about a Removed Document is left over.
36. As a reader with 1,000 Documents, I want the Gallery to launch as fast as before, so that Reading Progress costs me nothing.
37. As a reader of a long book, I want the saved state to stay small however often I read, so that storage and later syncing stay light.

## Implementation Decisions

- **Terms**: Reading Progress is the Place where the user last left off (page index + page-space point, see the Reader's Place). Last Read is when the Reader last showed the Document. Both are in `GLOSSARY.md`.
- **Core (Rust), per-Document Automerge document** (ADR-0008):
  - The core gains the `automerge` crate. The Automerge Library document stays deferred (ADR-0012).
  - Each Document's state is a hidden file in its Library folder (ADR-0012, amended). Remove's single rename takes it along. Listing finds the File as the folder's only non-hidden entry; today's "first entry" lookup changes accordingly.
  - Schema: the root holds a schema version (1) and a `progress` map with page index, x, y and Last Read (milliseconds since the Unix epoch). The whole map is written as one value on every save, so Place and Last Read never mix between devices.
  - Conflicts: when concurrent writes leave several `progress` values, reading picks the one with the newest Last Read, not Automerge's actor-based default (ADR-0008, amended). On equal times, it falls back to Automerge's default.
  - Saving loads the document (or creates it), writes the `progress` map, and stores the compacted document atomically: write to staging, then rename. History is accepted; compaction keeps it small.
  - Saving for a Document that isn't in the Library does nothing: no error, and no folder is created.
  - Interface: the Library listing returns each Document with its Reading Progress (none if never opened). A new save operation takes the Document ID, the Place and the Last Read. The caller supplies Last Read, so tests can set the time.
  - A missing or unreadable state file counts as "never opened". The Gallery must never fail because of one.
- **FFI**: exposes Reading Progress as a UniFFI record (page index, x, y, Last Read as milliseconds) as an optional field on Document, plus the save method on the Library object. It adds no logic.
- **Client Library model** (extended):
  - A Library Document carries its Reading Progress, its Last Read and its page count (once known).
  - The page count is saved with the Title and Author in the existing details store. It's read on Import (the PDF is already open). The existing background pass also reads details that are missing a page count.
  - It offers the percentage read, or none: floor(100 × (page index + 1) / page count). There's none if the Document was never opened or its page count isn't known yet.
  - It offers saving Reading Progress for a Document. Saving calls the core, which never blocks scrolling, and updates that Document in memory, so every window updates and re-sorts with animation.
  - The sort gains a Recently Read key: newest Last Read first, and reversing flips only the opened Documents. Never-opened Documents always follow, in the core's Date Imported order. The key is saved in user defaults like the others.
- **Reader**:
  - When a Document opens, the Reader goes to its saved Place at fit-to-width, using the existing go-to-Place, and saves right away, which updates Last Read. A never-opened Document starts at the top of page 1.
  - It saves the top-of-viewport Place once scrolling has stopped for about 1 s, when it disappears, and when the scene goes to the background (which also covers quitting on macOS).
  - Zoom is never saved.
- **Gallery cell**:
  - A wide Cover is centred vertically in the cell's page area. This replaces "sits on the bottom edge" from the Gallery spec.
  - The indicator overlays the page area's bottom edge: a thin bar across the full width, plus a capsule with "42 %" in the bottom-right corner above it, on `.ultraThinMaterial`. It also shows on the placeholder. Documents never opened get no overlay. The "+" cell gets none.
  - The accessibility label becomes "Title, 42 % read" for opened Documents.
- **Sort menu**: adds "Recently Read" next to Date Imported and Title. The reverse toggle works as before.

## Testing Decisions

- Test only external behaviour, through the three existing seams below, against real files. No mocks.
- **Core Library** (Rust, tests inside the source file, real temporary folders, like the existing Library tests). It covers:
  - saving and listing Reading Progress, which survives reopening the Library;
  - a never-opened Document lists with none;
  - the File is still found when the hidden state file exists;
  - Remove deletes the state;
  - saving for an unknown or Removed Document does nothing;
  - a corrupt state file lists as never opened;
  - two Automerge actors write concurrently and then merge, and the newest Last Read wins in both directions;
  - the schema version is stored;
  - the state of one Document stays under 64 KB after 1,000 saves;
  - listing 1,000 Documents with Reading Progress takes under 100 ms. This test is ignored by default and runs in a release build, because debug timings mean nothing.
- **Client Library model** (Swift Testing with the real `LeafCore` and the temporary-PDF helper, like `LibraryModelTests`). It covers:
  - the page count is saved on Import and filled in by the background pass when missing;
  - the percentage: rounded down, 100 % only on the last page, none if never opened;
  - saving Reading Progress updates the Document;
  - Recently Read in both directions, with never-opened Documents last in Date Imported order;
  - Library Search keeps the Recently Read order;
  - Reading Progress survives reopening the Library.
- **Reader** (`ReaderPDFViewTests`): going to a saved Place at fit-to-width puts that Place at the top of the viewport.
- Existing Rust, FFI and Swift tests stay green.
- **Manual checks on iPhone, iPad and Mac**:
  - reopening lands where you left off, including after a force-quit;
  - the overlay on light, dark and wide Covers and on the placeholder;
  - wide Covers centred vertically;
  - the Recently Read sort and its animation, with a second window open (Mac/iPad);
  - VoiceOver;
  - Gallery launch with a few hundred Documents.

## Out of Scope

- Syncing itself (Cloud Backing, §8). This feature only stores state in the shape sync will use.
- The Automerge Library document (ADR-0012).
- Showing a page number or percentage inside the Reader.
- Furthest-read tracking, marking a Document as finished or unread, and resetting Reading Progress.
- Saving zoom.
- Fine-tuning where the indicator sits on wide Covers.
- Handling clocks that are badly off between devices.
- Schema migrations beyond writing version 1.

## Further Notes

- These were updated during the grilling: `GLOSSARY.md` (Reading Progress, Last Read), `docs/features.md` §4, ADR-0008 (conflicts resolved by newest Last Read) and ADR-0012 (hidden state file in the Document's folder).
- Target: still snappy with 1,000 Documents. If the load or size budget fails, revisit with a non-synced index or a background pass before adding anything else.
