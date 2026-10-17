# Each device writes only its own sync files

Google Drive and OneDrive offer no transactions, so two devices rewriting one file lose data. Each device therefore writes immutable Automerge change chunks under its own device ID, and reads and merges the chunks of all devices. Each device periodically compacts its own chunks into one snapshot. No device ever modifies or deletes another device's files. CloudKit stores the same chunks as records, so all providers share this one sync design.
