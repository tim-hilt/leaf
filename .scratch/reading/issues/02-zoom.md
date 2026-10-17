# 02: Zoom with fit-to-width default and limits

**What to build:** The Reader opens a Document at fit-to-width. You can zoom in to 5× but never out past fit-to-width. Pinch works on all platforms, and double-tap zooms on iOS. See `.scratch/reading/spec.md`.

**Blocked by:** 01

**Status:** ready-for-agent

- [ ] Document opens at fit-to-width
- [ ] Zoom limited to between fit-to-width and 5× (limits unit-tested, test-first)
- [ ] Pinch zoom keeps the content under the fingers fixed (iOS, iPadOS, macOS trackpad)
- [ ] Double-tap zooms on iOS/iPadOS
