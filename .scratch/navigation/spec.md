# Navigation

Status: ready-for-agent

Feature §5 of `docs/features.md`. Terms per `GLOSSARY.md`. Builds on `.scratch/reading/spec.md` (Place, Immersive Mode) and `.scratch/reading-progress/spec.md`.

## Problem Statement

In a long Document I can only scroll. I can't see its Chapters and Sections, I can't jump to one, and I can't find a word or phrase. When I follow a link to a figure or another Chapter, I have to scroll my way back to where I was reading.

## Solution

The Reader gets two toolbar buttons. **Table of Contents** opens the Document's Chapters and Sections with their printed page numbers. The one I'm reading is in bold, and tapping an entry Jumps there. **Document Search** opens the native find bar. It searches as I type, has the system's case and whole-word options, and shows a list of all matches with their surrounding text and page numbers. After any Jump (a Chapter or Section, a search, or a link in the Document), a floating "Back to p. 42" capsule takes me back to exactly where I was.

## User Stories

### Table of Contents

1. As a reader, I want a Table of Contents button in the Reader toolbar, so that I can see how the Document is organised.
2. As a reader, I want the button hidden when the Document has no Table of Contents, so that I'm never shown an empty list.
3. As a reader, I want the button hidden in Immersive Mode, so that only the pages are shown.
4. As a Mac or iPad reader, I want the Table of Contents in a popover, so that it doesn't take space from the pages.
5. As an iPhone reader, I want the Table of Contents in a sheet, so that it fits the small screen.
6. As a Mac reader, I want Go > Table of Contents (⌥⌘T), so that I can open it from the keyboard.
7. As a reader, I want each row to show the title of the Chapter or Section and its printed page number at the trailing edge, like a printed table of contents, so that it feels familiar.
8. As a reader, I want printed page numbers (e.g. "xii", "45") rather than positions in the File, so that the numbers match what's printed on the pages.
9. As a reader, I want the page's position in the File shown when the page has no printed number, so that every row has a number.
10. As a reader, I want Sections nested under their Chapter or Section at any depth, so that I can see the structure.
11. As a reader, I want Sections folded by default with the native disclosure control, so that long tables of contents stay readable.
12. As a reader, I want the Chapters and Sections containing the one I'm reading unfolded, so that I can see where I am without searching.
13. As a reader, I want the Chapter or Section I'm reading in bold, so that I know where I am.
14. As a reader, I want "the one I'm reading" to be the deepest Chapter or Section that starts at or before the top of my screen, so that it matches the text I see.
15. As a reader, I want the list scrolled to the one I'm reading when it opens, so that I don't have to look for it.
16. As a reader, I want tapping a Chapter or Section to Jump there and close the list, so that I can read right away.

### Document Search

17. As a reader, I want a Document Search button in the Reader toolbar, so that I can find text in the Document.
18. As a reader, I want ⌘F to open Document Search on Mac and on iPad with a keyboard, so that it works like other apps.
19. As a reader, I want the button hidden in Immersive Mode, so that only the pages are shown.
20. As a reader, I want the native find bar of my platform, so that searching looks and behaves like the rest of the system.
21. As a reader, I want results to update as I type, so that I find things without pressing Return.
22. As a reader, I want the system's case-sensitivity option, so that I can find "Apple" but not "apple".
23. As a reader, I want the system's whole-word option, so that "cat" doesn't find "category".
24. As a reader, I want those options to behave and be remembered the way the system find bar does by default, so that there's nothing new to learn.
25. As a reader, I want the current match highlighted on the page and the others marked, so that I can see them in context.
26. As a reader, I want "3 of 27" and next/previous (⌘G / ⇧⌘G on Mac), so that I can step through matches.
27. As a reader, I want a scanned Document without text to just show no results, so that nothing breaks.

### Results list

28. As a Mac or iPad reader, I want a sidebar on the leading side listing all matches while there are any, so that I can see them all at once.
29. As a Mac or iPad reader, I want the sidebar to go away when I close the find bar or there are no matches, so that the pages get their space back.
30. As an iPhone reader, I want a list button in the find bar that opens the matches in a full-height sheet, so that the list doesn't cover the page while I type.
31. As a reader, I want each row to show the text around the match with the match in bold, so that I can tell which one I want.
32. As a reader, I want each row to show the printed page number at the trailing edge, so that I know where it is.
33. As a reader, I want rows grouped under the Chapter or Section they're in when the Document has a Table of Contents, so that I can see which part of the Document they're from.
34. As a reader, I want the current match selected in the list, so that the list and the find bar agree.
35. As a reader, I want choosing a row to go to that match and make it current, so that I can jump straight to it.
36. As a reader, I want the list to fill in while the search runs, so that large Documents don't keep me waiting.
37. As a reader, I want the list to scroll smoothly with thousands of matches, so that common words don't slow it down.

### Jump and Back

38. As a reader, I want choosing a Chapter, a Section, a search match or a link inside the Document to count as a Jump, so that I can always get back.
39. As a reader, I want a whole Document Search session to count as one Jump, so that one Back returns me to where I was before I started searching.
40. As a reader, I want a floating "Back to p. 42" capsule near the bottom of the Reader after a Jump, so that I can return to where I was reading.
41. As a reader, I want the capsule to use the printed page number, so that it matches the page.
42. As a reader, I want the capsule to stay while I look around, until I tap it or make another Jump, so that it's there when I'm done.
43. As a reader, I want a new Jump to replace the place Back returns to, so that Back always means "where I was before my latest Jump".
44. As a reader, I want Back to return to exactly where I was, at my current zoom, so that nothing surprises me.
45. As a reader, I want the capsule gone after Back, so that the Reader is clean again.
46. As a reader, I want a choice that doesn't move the view (e.g. a match already on screen) to not count as a Jump, so that the capsule only shows when there's somewhere to go back to.
47. As a reader, I want the capsule shown in Immersive Mode, since it's the only way back there.
48. As a reader, I want tapping a link to follow it without switching Immersive Mode, so that a link tap does only one thing.
49. As a Mac reader, I want Go > Back, so that I can go back from the menu bar.
50. As a reader, I want Jumps and Back to update my Reading Progress and Last Read like scrolling does, so that reopening finds me where I really am.
51. As a reader, I want the place Back returns to forgotten when I go to the Gallery, so that each reading session starts fresh.
52. As a reader, I want links to web pages to open in my default browser without a confirmation and without counting as a Jump, so that only moves within the Document can be undone.
53. As a reader, I want Go to Gallery to stay on the toolbar chevron and ⌘[, so that leaving the Reader works as before.
54. As a VoiceOver user, I want the capsule read as "Back to page 42", so that I know what it does.

## Implementation Decisions

- **Terms**: Table of Contents, Chapter, Section, Jump, Back and Go to Gallery are in `GLOSSARY.md`. "Back" never means Go to Gallery.
- **No core changes** (ADR-0003): the Table of Contents and Document Search come from PDFKit. Nothing is stored or synced.
- **Table of Contents (new client module)**:
  - Built from a `PDFDocument`'s outline. It gives each Chapter and Section a title, a printed page number (page label, falling back to the 1-based position in the File) and a target Place, nested to any depth.
  - It's empty when the outline is missing or has no children. The Reader then hides the button.
  - Given a Place, it returns the current Chapter or Section (the deepest whose target is at or before the Place, in reading order) and the Chapters and Sections that contain it, which the list unfolds.
  - Entries without a target are shown but can't be chosen.
- **Document Search (new client module)**:
  - Input: a query, case sensitivity and a word-match method (Contains, Starts With, Full Word), matching the system find bars' options.
  - Output: matches in reading order. Each has its page index, its PDFKit selection, its printed page number, a short excerpt of the surrounding text with the match's range marked, and the containing Chapter or Section from the Table of Contents.
  - Searching uses PDFKit's asynchronous find with the right compare options and delivers matches as they're found. Starting a new query cancels the old one.
  - PDFKit can't match whole words or prefixes, so the module filters on word boundaries in the page's text.
  - An empty query or a page without text gives no matches.
- **Find bar adapters (thin)**:
  - On iOS/iPadOS, the Reader's find interaction is driven by Document Search. PDFView's built-in session doesn't expose its matches, so the expected approach is our own find session over a searchable object backed by Document Search. That way the bar, the page highlights and the results list share one set of matches.
  - On macOS, an `NSTextFinder` find bar is connected to the PDFView through a client backed by Document Search, with incremental search turned on. It gets Edit > Find, ⌘F and ⌘G for free.
  - Spike first: confirm that both bars let us supply our own matches and read the user's options. If one doesn't, fall back to an `NSTextFinder`/`UIFindInteraction` setup that still gives the same matches and options. Don't build a custom search UI.
- **Results list**: on regular width, a leading sidebar shown while the find bar is open and has matches. On compact width, a list button added to the find bar's options opens a full-height sheet. It's a lazy native `List` with sections per Chapter or Section and the match in bold. The current match is selected, and choosing a row makes it current.
- **Reader – Jump and Back**:
  - The Reader view gains "Jump to Place" and "Back". A Jump saves the current top-of-viewport Place as the Back place and then goes to the target, unless the target is already at the top of the viewport (then nothing changes). A new Jump replaces the Back place.
  - Back goes to the saved Place without changing zoom and clears it.
  - The Reader keeps this place itself rather than using PDFKit's history, because on iOS it moves PDFKit's scroll view directly (see Reading).
  - A Document Search session records the Back place on its first move away from where the search started. Later moves inside the same session don't replace it. The session ends when the find bar closes.
  - Taps on links inside the Document go through Jump. Links to web pages keep PDFKit's default behaviour.
  - On iOS, a single tap on a link doesn't switch Immersive Mode.
  - Jumps and Back trigger the existing Reading Progress save, as scrolling does.
  - The Back place lives only as long as the Reader. Go to Gallery drops it.
- **Reader UI**:
  - There are two trailing toolbar items, Table of Contents (`list.bullet`) and Document Search (`magnifyingglass`), both hidden in Immersive Mode. Table of Contents is also hidden when it's empty.
  - The Back capsule floats near the bottom on a native material. Its accessibility label is "Back to page 42", and it stays visible in Immersive Mode.
  - macOS gets a **Go** menu with "Back to p. 42" (no shortcut, disabled when there's no Back place) and "Table of Contents" (⌥⌘T). These act on the focused Reader, like the existing zoom commands.
  - Go to Gallery keeps the toolbar chevron and ⌘[.

## Testing Decisions

- Test only external behaviour, against real PDFs, with no mocks. There are three seams.
- **Test PDF helper** gains options to draw text on pages, add an outline (nested entries with targets) and set page labels.
- **Table of Contents** (Swift Testing, new suite):
  - nested Chapters and Sections with their titles and target Places;
  - printed page numbers, with the position-in-File fallback;
  - empty when there's no outline;
  - the current entry at a Place: the deepest one at or before it, nothing before the first entry, and a Place inside a nested Section;
  - the Chapters and Sections that contain the current entry;
  - entries without a target.
- **Document Search** (Swift Testing, new suite):
  - matches in reading order across pages;
  - case-insensitive and case-sensitive matching;
  - Contains, Starts With and Full Word, including punctuation and the start and end of a page;
  - the excerpt and the match's range in it;
  - printed page numbers;
  - the containing Chapter or Section;
  - an empty query and pages without text give no matches;
  - a new query cancels the old one.
- **Reader** (extends `ReaderPDFViewTests`):
  - a Jump goes to the target and Back returns to the exact Place;
  - Back keeps the current zoom;
  - a second Jump replaces the Back place;
  - a Jump to the current Place records nothing;
  - a search session's moves record a single Back place;
  - there's no Back place after Back.
- Existing Rust, FFI and Swift tests stay green.
- **Manual checks on iPhone, iPad and Mac**:
  - both find bars with their options, as you type, and with ⌘F/⌘G;
  - the sidebar and the iPhone sheet with a large result set;
  - the Table of Contents popover or sheet, with the bold current entry and its parents unfolded;
  - links in and out of Immersive Mode;
  - the capsule and Go > Back;
  - VoiceOver;
  - a scanned PDF;
  - a 1,000-page book stays responsive while searching.

## Out of Scope

- Forward, and more than one level of Back.
- Keeping or syncing the Back place, search options or search history.
- OCR for scanned Documents.
- A Table of Contents for Documents without one.
- A permanent sidebar for the Table of Contents, page thumbnails and printed page numbers inside the Reader.
- Search and replace, or searching across Documents (Library Search covers Titles only).

## Further Notes

- These were updated during the grilling: `GLOSSARY.md` (Table of Contents, Chapter, Section, Jump, Back, Go to Gallery) and `docs/features.md` §5.
- Target: searching a 1,000-page Document never blocks scrolling or typing. The first matches appear within a fraction of a second.
