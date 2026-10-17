# 04: Immersive Mode

**What to build:** You can read without distraction: in Immersive Mode everything except the Document's pages is hidden. The Reader opens with its UI showing, and scrolling never hides it. See `.scratch/reading/spec.md`.

**Blocked by:** 01

**Status:** done

- [x] iOS/iPadOS: single tap on the page toggles Immersive Mode
- [x] iOS/iPadOS Immersive Mode hides the navigation bar and status bar; home indicator fades automatically
- [x] macOS: native full screen (⌃⌘F / green button) is Immersive Mode; toolbar hidden and shown when the pointer reaches the top edge
- [x] macOS clicks never toggle Immersive Mode
- [x] Scrolling never hides or shows the UI

## Comments

- Review: macOS keeps the toolbar visible in full screen by default; the Reader now sets `.windowToolbarFullScreenVisibility(.onHover)`.
