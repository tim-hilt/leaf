# Request only app-scoped cloud permissions

Google Drive uses `drive.file` (only files the app created); OneDrive uses `Files.ReadWrite.AppFolder`. The full `drive` scope is restricted and requires a costly third-party security assessment. As a result, LeafPDF can only see the sync directory it created itself, never the user's other files.

## Consequences

`drive.file` access is granted per Google Cloud project, so the OAuth clients of all platforms must live in the same project. Otherwise one platform's client can't see the sync directory another platform's client created.
