# Request only app-scoped cloud permissions

Google Drive uses `drive.file` (only files the app created); OneDrive uses `Files.ReadWrite.AppFolder`. The full `drive` scope is restricted and requires a costly third-party security assessment. As a result, LeafPDF can only see the sync directory it created itself, never the user's other files.

## Consequences

- `drive.file` access is granted per Google Cloud project, so the OAuth clients of all platforms must live in the same project. Otherwise one platform's client can't see the sync directory another platform's client created.
- `drive.file` is non-sensitive, so the project is published "In production" without an assessment. In "Testing", refresh tokens expire after 7 days.
- A `LeafPDF` folder the user creates by hand is invisible to LeafPDF.
- `Files.ReadWrite.AppFolder` is only consentable for personal Microsoft accounts: OneDrive work and school accounts are not supported. The folder is `Apps/LeafPDF`.
