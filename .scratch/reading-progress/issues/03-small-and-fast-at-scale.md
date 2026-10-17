# 03: State stays small and fast at scale

**What to build:** Proves Reading Progress costs nothing at scale: a Document's state stays small however often it's saved, and the Library still lists 1,000 Documents quickly. See `.scratch/reading-progress/spec.md`.

**Blocked by:** 01

**Status:** ready-for-agent

- [x] Rust test: one Document's state stays under 64 KB after 1,000 saves
- [ ] Rust test: listing 1,000 Documents with Reading Progress takes under 100 ms; ignored by default and run in a release build
- [ ] If a budget fails, stop and report the measured numbers instead of adding a cache or background pass

## Budget failed (stopped, no cache or background pass added)

`listing_1000_documents_with_reading_progress_takes_under_100_ms` (release build, 1,000 Documents with Reading Progress) measured 121, 125, 127 and 127 ms over four runs. Budget: 100 ms. Decide next step (e.g. non-synced index or background pass, per the spec's Further Notes) before the second bullet can be ticked.
