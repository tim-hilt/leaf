# Reading Progress is a plain value, not part of the Automerge state

Reading Progress is saved whenever the Reader rests, so as an Automerge value (ADR-0008) its history grew with every save and slowed every read of the state. Only the latest Reading Progress matters, so it leaves the Automerge state. Each Device keeps it in a plain file next to the File and syncs it as one blob of its own per Import, `progress.<import>.<device>-<last read>`, replacing its older one. The newest Last Read wins, which the listing alone tells, so nothing is fetched until another Device has read further.

## Considered Options

- **Compacting the Automerge history**: devices merge by history, so it can't be dropped unilaterally.
- **A percentage instead of a Place**: as small, but reopening lands near, not at, where the user left off.

## Consequences

- Reading Progress in older states is still read until the Document has a Reading Progress of its own.
- Older app versions no longer see Reading Progress from newer ones.
