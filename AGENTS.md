# LeafPDF

Native, cross platform PDF Reader with cloud syncing

# Layout

- `core/`: `leafpdf-core`, platform-independent logic (pure Rust)
- `ffi/`: `leafpdf-ffi`, UniFFI bindings of the core
- `apple/`: iOS, iPadOS and macOS client; edit `project.yml`, never the `.xcodeproj`
- `docs/adr/`: architecture decisions

# Coding Guidelines

- Focus on being snappy and Lightweight. Don't add bloat!
- Use native UI functionality wherever possible
- Use test driven development (red, green, refactor) by default
- Keep documentation very lean and precise. No walls of text in this project!

## Rust

- Write tests inside the source code files


## Agent skills

### Issue tracker

Issues and specs are local markdown files under `.scratch/`. See `docs/agents/issue-tracker.md`.

### Triage labels

Default five-role vocabulary, recorded as `Status:` lines. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context. See `docs/agents/domain.md`.
