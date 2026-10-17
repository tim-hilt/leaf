# 04: Reading Progress on Covers

**What to build:** Each opened Document in the Gallery shows how far I've got: a thin bar along the bottom of its page area and a "42 %" capsule above it in the bottom-right corner. Wide Covers sit centred vertically. See `.scratch/reading-progress/spec.md`.

**Blocked by:** 01

**Status:** ready-for-agent

- [ ] Page count is saved with Title and Author on Import; the background pass also reads details that lack a page count
- [ ] Percentage is floor(100 × (page index + 1) / page count): 100 % only on the last page, "0 %" when opened but not scrolled, none when never opened or page count unknown
- [ ] Overlay: full-width thin bar at the page area's bottom edge plus a capsule on `.ultraThinMaterial`; also shown on the placeholder; none on the "+" cell
- [ ] A Cover wider than the cell's page shape is centred vertically; the overlay stays at the cell's bottom edge
- [ ] VoiceOver reads opened Documents as "Title, 42 % read"
- [ ] Indicator updates when returning from the Reader and live in other windows
- [ ] Tests first: Library model tests for page count (Import and background pass) and the percentage
- [ ] Manually verified on light, dark and wide Covers and on the placeholder, on iPhone, iPad and Mac
