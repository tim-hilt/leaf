# 03: State stays small and fast at scale

**What to build:** Proves Reading Progress costs nothing at scale: a Document's state stays small however often it's saved, and the Library still lists 1,000 Documents quickly. See `.scratch/reading-progress/spec.md`.

**Blocked by:** 01

**Status:** ready-for-agent

- [ ] Rust test: one Document's state stays under 64 KB after 1,000 saves
- [ ] Rust test: listing 1,000 Documents with Reading Progress takes under 100 ms; ignored by default and run in a release build
- [ ] If a budget fails, stop and report the measured numbers instead of adding a cache or background pass
