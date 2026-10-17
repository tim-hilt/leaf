# 06: Library Search

**What to build:** A native search field in the Gallery finds Documents by part of their Title, file name or Author, ignoring case and accents, updating as you type. The "+" cell stays visible. A search with no matches shows "No Results for 'x'" after it. See `.scratch/gallery/spec.md`.

**Blocked by:** 02

**Status:** ready-for-agent

- [ ] The Library model exposes the Library Search text. The visible Documents match it with `localizedStandardContains` on Title, original file name and Author
- [ ] Results keep the current order
- [ ] A `.searchable` field. ⌘F focuses it on Mac and iPad
- [ ] The "+" cell stays first while searching
- [ ] No matches: the "+" cell followed by "No Results for 'x'"
- [ ] Tests (test-first, Library model): matches on Title, file name and Author; case and accents are ignored ("resume" finds "Résumé"); order is kept
