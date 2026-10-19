# Highlight Colors sync in a per-user Preferences document

Custom Colors and the Default Highlight Color belong to the user, not to one Document, so they don't fit ADR-0008's Library and per-Document documents. They go into a third Automerge document, Preferences, synced like the others (ADR-0009) and local until Cloud Backing exists. Concurrent additions of Custom Colors both survive; a removal wins over concurrent use. Every other setting (Theme, Page Style, Page Colors) stays per device.

## Considered Options

- **Per-device, like the other settings**: no new document, but Custom Colors would have to be added again on every device.
- **In the Library document**: one document fewer, but mixes the set of Documents with user preferences.

## Consequences

- A Highlight stores its color value, not a reference into Preferences, so it looks right even if its Custom Color is removed or hasn't synced yet.
- A removed Custom Color that was the Default Highlight Color falls back to yellow.
