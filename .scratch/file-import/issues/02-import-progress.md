# 02: Import progress

**What to build:** While an Import runs, the whole UI is disabled at once. If the Import takes longer than about 0.5 s, a modal shows a determinate progress bar and the Title. The app never shows a beachball. There is no Cancel. See `.scratch/file-import/spec.md`.

**Blocked by:** 01

**Status:** in-review

- [x] Core Import reports bytes copied out of the total through a progress callback; progress reaches the total (Rust test)
- [x] Progress reaches Swift through a UniFFI callback interface
- [x] The core runs off the main thread; the UI stays responsive
- [x] The UI is disabled from the start of an Import until it finishes
- [x] The modal appears only after about 0.5 s; quick Imports show no modal
- [ ] Manually checked on iPhone, iPad and Mac with a large File
