# The Library is an Automerge document; synced state is keyed per Import

Cloud Backing needs what ADR-0012 deferred: Removes must reach every Device and win over concurrent edits, and Date Imported and the original file name must travel with the File. So the Library becomes an Automerge document listing every Import (its File's hash, file name and Date Imported) and every Remove. A Document's synced state is keyed by its Import, not by the hash: other Devices' old chunks of a Removed Document stay in the cloud (ADR-0009), and Re-Importing the File must start fresh. Clients still identify a Document by its hash (ADR-0007).

## Considered Options

- **State keyed by hash, ignoring changes older than the Remove**: needs trustworthy clocks across Devices.

## Consequences

- The same File Imported on two Devices while apart is two Imports of one Document: it is listed once, with the earliest Date Imported and the state of both merged.
- A Remove covers every Import of that File the Device knows of, so it wins over concurrent edits.
