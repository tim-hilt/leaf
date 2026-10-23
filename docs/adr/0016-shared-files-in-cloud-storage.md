# Files are shared in cloud storage and any Device may delete them

ADR-0009 lets each Device write and delete only its own sync files. Files are the exception: each is stored once, under its hash, by whichever Device uploads it first. Removing a Document deletes its File from the cloud, so Removed Files don't use up the user's storage. Each Device deletes its own chunks of a Removed Import when it learns of the Remove.

## Considered Options

- **Never delete Files**: no exception to ADR-0009, but Removed Files stay in the cloud forever.

## Consequences

- A Device holding a File the Library still lists uploads it again if it is missing from the cloud. This heals a Re-Import that raced a Remove.
- Chunks of a Device that never Syncs again stay behind.
- Deletes free the storage at once on WebDAV and Google Drive (permanent delete). OneDrive (recycle bin, as `permanentDelete` needs `Files.ReadWrite`, ADR-0011) and iCloud Drive (Recently Deleted) free it after 30 days at the latest.
