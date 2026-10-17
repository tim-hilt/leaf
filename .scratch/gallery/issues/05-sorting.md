# 05: Sorting

**What to build:** A toolbar menu, like the one in the Files app, sorts the Gallery by Date Imported (default, newest first) or Title (A–Z, Finder-like), each reversible. The choice is remembered on this device and shared by all windows. See `.scratch/gallery/spec.md`.

**Blocked by:** 01

**Status:** done

- [x] The Library model exposes the sort choice and the resulting visible Documents
- [x] Date Imported uses the core's newest-first order, reversed on request
- [x] Title uses `localizedStandardCompare` ("2" before "10", ignoring case and accents), reversible
- [x] The choice is stored per device (user defaults), shared by all windows and not synced
- [x] The "+" cell stays first whatever the order
- [x] A Document whose Title arrives later moves to its place with the native animation
- [x] Tests (test-first, Library model): Date Imported in both directions; Title in both directions, Finder-like
