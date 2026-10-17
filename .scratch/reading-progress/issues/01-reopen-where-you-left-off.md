# 01: Reopen where you left off

**What to build:** Opening a Document returns to where I left off (its Reading Progress), at fit-to-width; a never-opened Document starts at page 1. The Reader saves Reading Progress and Last Read in the Document's Automerge document, so they survive relaunches. See `.scratch/reading-progress/spec.md`.

**Blocked by:** None (can start immediately)

**Status:** in-review

- [x] Prefactor: the File is found as the Document folder's only non-hidden entry
- [x] Core: each Document's state is a hidden Automerge file in its Library folder, with schema version 1 and one `progress` map (page index, x, y, Last Read in ms) written as a whole on every save
- [x] Core: saving takes the Document ID, the Place and the Last Read, and stores the compacted document atomically (staging, then rename)
- [x] Core: saving for an unknown or Removed Document does nothing and creates no folder
- [x] Core: the Library listing carries each Document's Reading Progress; never opened, missing or corrupt state lists as none
- [x] Core: Remove deletes the state along with the File
- [x] FFI: Reading Progress record as an optional field on Document, plus the save method; no logic
- [x] Library model: Documents carry Reading Progress and Last Read; saving updates the Document in memory and survives reopening the Library
- [x] Reader: opens at the saved Place at fit-to-width and saves right away (updating Last Read); zoom is never saved
- [x] Reader: saves the top-of-viewport Place once scrolling has stopped for about 1 s, when it disappears, and when the scene goes to the background; saving never blocks scrolling
- [x] Tests first: Rust tests inside the source file, Library model tests with the real `LeafCore`, and a `ReaderPDFViewTests` case for landing on a saved Place
- [ ] Manually verified on iPhone, iPad and Mac, including after a force-quit
