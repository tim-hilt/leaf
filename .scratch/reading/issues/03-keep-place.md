# 03: Keep your place on rotation, resize and keyboard zoom

**What to build:** Your place in the Document is stable. Rotating the device, resizing the window or zooming with the keyboard keeps the content at the top of the viewport in place. The place is stored as page index + a point on the page, so Reading Progress (§4) can reuse it. See `.scratch/reading/spec.md`.

**Blocked by:** 02

**Status:** ready-for-agent

- [ ] Place is stored as page index + page-space point
- [ ] Rotating or resizing keeps the content at the top of the viewport fixed
- [ ] At fit-to-width: re-fit to the new width; zoomed in: keep the zoom relative to fit-to-width
- [ ] macOS ⌘+ / ⌘− zoom anchored at the top of the viewport; ⌘0 returns to fit-to-width
- [ ] Rules for keeping your place are unit-tested, test-first
- [ ] Manually verified on iPhone and iPad in both orientations, and on Mac at several window sizes
