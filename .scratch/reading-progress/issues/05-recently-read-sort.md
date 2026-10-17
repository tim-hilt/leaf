# 05: Recently Read sort

**What to build:** The Gallery's sort menu offers "Recently Read": the Document I read last comes first, and never-opened Documents follow at the end. See `.scratch/reading-progress/spec.md`.

**Blocked by:** 01

**Status:** ready-for-agent

- [ ] "Recently Read" sits in the toolbar sort menu next to Date Imported and Title; Date Imported stays the default
- [ ] Newest Last Read first; reversing flips only opened Documents; never-opened Documents always follow in Date Imported order (newest first)
- [ ] The choice is saved per device in user defaults and shared by all windows
- [ ] Opening a Document moves it to the top with the native animation, in every window
- [ ] Library Search keeps the Recently Read order
- [ ] Tests first: Library model tests for both directions, never-opened Documents last, and Library Search order
