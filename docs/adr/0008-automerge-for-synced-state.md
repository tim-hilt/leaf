# Synced state is stored as Automerge documents

The library (the list of imported files) is one Automerge document. Each file's markup and reading progress form another document, keyed by the file's content hash. CRDTs let devices stay offline indefinitely and still converge without conflicts. Concurrent edits to different fields of one highlight, or to one note's text, both survive. Reading progress and its Last Read time are written together as one last-writer-wins value. Automerge picks the winner of concurrent writes by actor ID, not by time, so the core resolves such conflicts itself: the newest Last Read wins.

## Considered Options

- **Hand-rolled last-writer-wins records**: less code up front, but concurrent edits to one annotation lose data.
- **Loro**: comparable Rust CRDT, younger and less proven.

## Consequences

- Version the document schema from day one; the binary format makes migrations harder.
- History grows, so devices compact it periodically (see ADR-0009).
