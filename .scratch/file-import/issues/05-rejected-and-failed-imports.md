# 05: Rejected and failed Imports

**What to build:** Files that PDFKit can't open and password-protected PDFs are rejected with an alert before anything is copied. PDFs that only restrict permissions Import normally. If copying fails (e.g. disk full, source gone), an alert says "Couldn't import 'X'" with the system's reason, and nothing is left behind. See `.scratch/file-import/spec.md`.

**Blocked by:** 01

**Status:** ready-for-agent

- [ ] Client Library model returns `rejected(.notPDF | .unreadable | .locked)` before calling the core (Swift tests with garbage bytes and a locked PDF)
- [ ] Owner-password-only PDFs are accepted
- [ ] A failing core Import removes its staging folder and leaves the Library unchanged (Rust test, e.g. missing source)
- [ ] Core errors reach Swift as one FFI error carrying the system message; the model returns `failed(message)`
- [ ] Alerts: "Password-protected PDFs aren't supported yet" for locked PDFs, a clear message for unreadable Files, "Couldn't import 'X'" plus the system message for failures
