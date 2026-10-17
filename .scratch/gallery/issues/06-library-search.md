# 06: Library Search

**What to build:** A native search field in the Gallery finds Documents by part of their Title, file name or Author, ignoring case and accents, updating as you type. The "+" cell stays visible. A search with no matches shows "No Results for 'x'" after it. See `.scratch/gallery/spec.md`.

**Blocked by:** 02

**Status:** done

- [x] The Library model gives the visible Documents for a Library Search text, kept per window. They match it with `localizedStandardContains` on Title, original file name and Author
- [x] Results keep the current order
- [x] A `.searchable` field. ⌘F focuses it on Mac and iPad
- [x] The "+" cell stays first while searching
- [x] No matches: the "+" cell followed by "No Results for 'x'"
- [x] Tests (test-first, Library model): matches on Title, file name and Author; case and accents are ignored ("resume" finds "Résumé"); order is kept
