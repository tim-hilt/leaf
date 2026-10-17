# 01: Saved Titles and Authors

**What to build:** The Gallery shows every Document's Title without opening any PDF at launch. Import saves the Title and Author, a low-priority background pass fills in missing ones (showing the file name until then), and Remove deletes them. The Reader opens the PDF only when it shows the Document. The existing list keeps working. See `.scratch/gallery/spec.md`.

**Blocked by:** None (can start immediately)

**Status:** ready-for-agent

- [ ] A Document no longer holds an open PDF. It exposes its ID, stored File location, original file name, and saved Title and Author if known
- [ ] The Title shown is the saved Title, or the file name without extension until it's read
- [ ] Import saves the Title and Author before reporting the outcome
- [ ] Titles and Authors live in one store in Application Support, outside the Library folder, keyed by Document ID and never synced
- [ ] At launch, a low-priority background pass reads missing Titles and Authors and publishes each as it arrives
- [ ] Remove deletes the saved Title and Author
- [ ] The Reader opens the PDF when it shows a Document. Duplicate "Open", Removal while open, and ⌘O from the Reader still work
- [ ] The temporary-PDF test helper gains an Author parameter
- [ ] Tests (test-first, Library model with the real `LeafCore`): the Title, file name and Author after Import; Titles and Authors survive reopening the Library; with the saved Titles missing, file names first and Titles after the background pass; Remove deletes the saved entry; opening the Library opens no PDFs
