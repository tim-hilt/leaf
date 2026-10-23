# Leaf

Native, cross platform PDF Reader with cloud syncing

# Layout

- `core/`: `leaf-core`, platform-independent logic (pure Rust)
- `ffi/`: `leaf-ffi`, UniFFI bindings of the core
- `apple/`: iOS, iPadOS and macOS client; edit `project.yml`, never the `.xcodeproj`
- `docs/adr/`: architecture decisions
- `Makefile`: build and test entry points; run tests through it (`make apple-test-ios ONLY=<Suite>` for iOS-only code)

# Coding Guidelines

- Focus on being snappy and Lightweight. Don't add bloat!
- Use native UI functionality wherever possible
- Use test driven development (red, green, refactor) by default
- Keep documentation very lean and precise. No walls of text in this project!

## Rust

- Write tests inside the source code files


## Agent skills

### Issue tracker

Issues and specs are `loop` sessions and tasks (`loop --help`). See `docs/agents/issue-tracker.md`.

### Domain docs

Single-context. See `docs/agents/domain.md`.
