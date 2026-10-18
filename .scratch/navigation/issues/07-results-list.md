# 07: Results list

**What to build:** All matches are listed with their context, so the reader can pick the one they want. See `.scratch/navigation/spec.md`.

**Blocked by:** 01, 05, 06

**Status:** ready-for-agent

- [ ] Each match carries an excerpt of the surrounding text with the match's range marked, its printed page number and the containing Chapter or Section from the Table of Contents
- [ ] Regular width: a leading sidebar shows while the find bar is open and has matches, and goes away otherwise
- [ ] Compact width: a list button in the find bar's options opens a full-height sheet
- [ ] A lazy native `List` with sections per Chapter or Section (no sections without a Table of Contents); rows show the excerpt with the match in bold and the printed page number at the trailing edge
- [ ] The list fills in as matches arrive; the current match is selected; choosing a row makes it current and shows it
- [ ] Swift tests cover: excerpt and match range, printed page numbers, containing Chapter or Section
