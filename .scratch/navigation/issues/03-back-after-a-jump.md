# 03: Back after a Jump

**What to build:** After a Jump, a "Back to p. 42" capsule returns the reader to exactly where they were. Table of Contents rows become Jumps. See `.scratch/navigation/spec.md`.

**Blocked by:** 01

**Status:** ready-for-agent

- [ ] The Reader view offers Jump to Place and Back
- [ ] A Jump stores the top-of-viewport Place as the Back place, then goes to the target; a new Jump replaces it
- [ ] A Jump whose target is already at the top of the viewport changes nothing
- [ ] Back goes to the stored Place without changing zoom and clears it
- [ ] The Back place lives only as long as the Reader; Go to Gallery drops it
- [ ] Jumps and Back trigger the existing Reading Progress save, like scrolling
- [ ] A floating capsule "Back to p. 42" (printed page number) on a native material shows while there is a Back place, also in Immersive Mode; its accessibility label is "Back to page 42"
- [ ] macOS: Go > Back to p. 42, no shortcut, disabled without a Back place; Go to Gallery stays on the chevron and ⌘[
- [ ] Choosing a Table of Contents row is a Jump
- [ ] `ReaderPDFViewTests` cover: Jump goes to the target and Back returns to the exact Place, Back keeps the current zoom, a second Jump replaces the Back place, a Jump to the current Place records nothing, no Back place after Back
