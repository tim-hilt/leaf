# Coding Standards

Judgement calls for review; tooling (`make lint`) enforces the rest.

- **Event-driven**: background work wakes on an event (channel, condvar, callback), never by polling on a timer.
- **Deterministic tests**: a test waits on the condition it needs, never on a fixed `sleep`.
