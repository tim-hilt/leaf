# 07: Keyboard navigation

**What to build:** On Mac, and on iPad with a hardware keyboard, arrow keys move a highlight through the grid, including the "+" cell. Return opens the highlighted Document or Imports, and ⌘⌫ asks to Remove it. ↓ in the search field highlights the first match. Coming back from the Reader highlights the Document that was open. Click and tap still open directly. See `.scratch/gallery/spec.md`.

**Blocked by:** 02, 06

**Status:** in-review

- [x] A pure grid-highlight value type: takes the current highlight (or none), the column count, the cell count (including "+") and an arrow key, and returns the new highlight
- [x] Nothing is highlighted until the first arrow press, which highlights the first cell
- [x] At the grid's edges the highlight stays put. ↓ into the last, partial row goes to its last cell
- [x] Return opens the highlighted Document, or Imports when "+" is highlighted
- [x] ⌘⌫ starts Remove (with the existing confirmation) for the highlighted Document
- [x] ↓ in the search field highlights the first matching Document
- [x] The highlight is scrolled into view
- [x] Coming back from the Reader highlights the Document that was open, if highlighting was in use
- [x] Tests (test-first, Swift Testing like the `ZoomRange` tests): first press; all four directions; edges; last, partial row; a single cell; column count changes
- [ ] Manual check on Mac and iPad: ⌘F, type, ↓, Return opens a Document
