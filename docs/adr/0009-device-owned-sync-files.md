# Each device writes only its own sync files

Google Drive and OneDrive offer no transactions, so two devices rewriting one file lose data. Each device therefore writes immutable Automerge change chunks under its own device ID, and reads and merges the chunks of all devices. Each device periodically compacts its own chunks into one snapshot. No device ever modifies or deletes another device's files. All Cloud Providers share this one sync design (ADR-0017). Files are the one shared exception (ADR-0016).
