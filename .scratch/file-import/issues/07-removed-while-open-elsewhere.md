# 07: Removed while open in another window

**What to build:** When a Document is Removed while another window (macOS or iPadOS) is reading it, that window returns to the Gallery and shows an alert "'X' was removed from your Library". See `.scratch/file-import/spec.md`.

**Blocked by:** 06

**Status:** in-review

- [x] All windows share one client Library model and notice the Removal
- [x] A window reading the Removed Document returns to its Gallery
- [x] That window shows the alert "'X' was removed from your Library"
- [ ] Manually checked with two windows on Mac and iPad
