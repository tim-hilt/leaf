# 04: Smooth scrolling at 1,000 Documents

**What to build:** Scrolling through a large Library stays smooth. Saved Covers appear right away, even mid-scroll. New Covers are rendered only for visible cells, once scrolling has stopped. See `.scratch/gallery/spec.md`.

**Blocked by:** 03

**Status:** in-review

- [x] Saved Covers load as soon as a cell appears, even while scrolling
- [x] New renders are queued for visible cells only, and start once scrolling has been still for about 150 ms
- [x] Requests for cells that scrolled away are dropped
- [ ] Manual check on iPhone, iPad and Mac with a few hundred real PDFs: fast launch, smooth scrolling, renders only after scrolling stops
