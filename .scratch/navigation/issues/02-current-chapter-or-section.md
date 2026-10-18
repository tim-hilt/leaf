# 02: Current Chapter or Section in bold

**What to build:** When the Table of Contents opens, the reader sees where they are. See `.scratch/navigation/spec.md`.

**Blocked by:** 01

**Status:** in-review

- [x] The Table of Contents module returns, for a Place, the current Chapter or Section (the deepest whose target is at or before the Place, in reading order) and the Chapters and Sections containing it
- [x] The current entry is shown in bold, its containing entries are unfolded, and the list opens scrolled to it
- [x] "Current" is computed from the top-of-viewport Place
- [x] Swift tests cover: deepest entry at or before a Place, no current entry before the first one, a Place inside a nested Section, the containing entries
