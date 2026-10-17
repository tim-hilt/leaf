# 02: Gallery grid with the "+" cell

**What to build:** The Gallery becomes a vertically scrolling grid. Each Document is a page-shaped cell with a grey placeholder and its Title underneath. The first cell is a "+" that Imports. An empty Library shows the grid with only the "+" cell. See `.scratch/gallery/spec.md`.

**Blocked by:** 01

**Status:** in-review

- [x] A lazy vertical grid with adaptive columns (minimum about 140 pt): 2 columns on an iPhone in portrait, more when wider
- [x] Each cell is A4 portrait (1 : 1.414) with a grey placeholder, and the Title under it on up to 2 lines (always reserved), cut off at the end
- [x] The first cell is the same grey with a white "+" in the centre and "Import…" underneath, and it Imports
- [x] An empty Library shows only the "+" cell. The `ContentUnavailableView` and the list are gone
- [x] One click or tap opens the Document in the Reader on every platform. Going back keeps the scroll position
- [x] The context-menu Remove with confirmation, the toolbar "+", ⌘O, and returning to the Gallery when a Document is Removed in another window all still work
- [x] VoiceOver: each cell is a button labelled with its Title, with Remove as an action. The "+" cell is labelled "Import…"
- [ ] Manual check on iPhone, iPad and Mac: layout, rotation and resizing, the empty Library, VoiceOver
