# 02: Newest Last Read wins on conflict

**What to build:** When two devices wrote Reading Progress concurrently and their states are merged, the Place with the newest Last Read wins, not Automerge's actor-based default (ADR-0008). This prepares Cloud Backing; there is no sync UI yet. See `.scratch/reading-progress/spec.md`.

**Blocked by:** 01

**Status:** done

- [x] Reading picks, among concurrent `progress` values, the one with the newest Last Read; on equal times it falls back to Automerge's default
- [x] Rust tests merge two Automerge actors that wrote concurrently and check the newest Last Read wins in both merge directions
- [x] Place and Last Read never mix between devices
