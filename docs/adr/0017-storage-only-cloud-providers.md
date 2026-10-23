# Cloud Providers are storage only; LeafPDF runs no server

Every Cloud Provider is plain remote file storage behind the storage interface of ADR-0010: WebDAV first (self-hosted on a Raspberry Pi with any WebDAV server), then iCloud Drive, Google Drive and OneDrive. All sync logic stays in the core, and the immutable chunks of ADR-0009 need no transactions. Devices find changes by polling: every 10 seconds while in the foreground, and on launch and foreground.

## Considered Options

- **Own sync server**: live updates through long-polling, but server code to maintain and deploy, and a second sync design next to Google Drive and OneDrive.
- **CloudKit**: needs a paid Apple Developer membership, which LeafPDF won't have. Its pushes need one too.

## Consequences

- Changes from another Device take up to 10 seconds to show; nothing Syncs in the background.
- Self-hosting works with any WebDAV host (rclone, nginx, Nextcloud, Synology).
