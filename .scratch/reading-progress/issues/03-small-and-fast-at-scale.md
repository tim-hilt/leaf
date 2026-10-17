# 03: State stays small and fast at scale

**What to build:** Proves Reading Progress costs nothing at scale: a Document's state stays small however often it's saved, and the Library still lists 1,000 Documents quickly. See `.scratch/reading-progress/spec.md`.

**Blocked by:** 01

**Status:** done

- [x] Rust test: one Document's state stays under 64 KB after 1,000 saves
- [x] Rust test: listing 1,000 Documents with Reading Progress takes under 100 ms; ignored by default and run in a release build
- [x] If a budget fails, stop and report the measured numbers instead of adding a cache or background pass

## Budget

The serial listing measured 121–127 ms (release, 1,000 Documents with Reading Progress). The review spread `Library::documents` over the cores (no cache or background pass): now ~75 ms on a fresh Library and ~26 ms warm, as fast as listing without Reading Progress was before.
