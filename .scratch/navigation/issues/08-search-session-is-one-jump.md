# 08: A Document Search session is one Jump

**What to build:** One Back returns the reader to where they were before they started searching, however many matches they visited. See `.scratch/navigation/spec.md`.

**Blocked by:** 03, 05, 06

**Status:** in-review

- [x] The first move away from where the search started records the Back place; later moves in the same session, from the find bar or the results list, don't replace it
- [x] The session ends when the find bar closes; the capsule then offers Back to where the search started
- [x] Works with both find bars
- [x] `ReaderPDFViewTests` cover: several moves in one search session record a single Back place, which is where the search started
