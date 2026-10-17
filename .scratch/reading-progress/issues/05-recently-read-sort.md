# 05: Recently Read sort

**What to build:** The Gallery's sort menu offers "Recently Read": the Document I read last comes first, and never-opened Documents follow at the end. See `.scratch/reading-progress/spec.md`.

**Blocked by:** 01

**Status:** in-review

- [x] "Recently Read" sits in the toolbar sort menu next to Date Imported and Title; Date Imported stays the default
- [x] Newest Last Read first; reversing flips only opened Documents; never-opened Documents always follow in Date Imported order (newest first)
- [x] The choice is saved per device in user defaults and shared by all windows
- [x] Opening a Document moves it to the top with the native animation, in every window
- [x] Library Search keeps the Recently Read order
- [x] Tests first: Library model tests for both directions, never-opened Documents last, and Library Search order
