# 04: Links are Jumps

**What to build:** Following a link inside the Document is a Jump, so the reader can go Back after glancing at a figure or Chapter. See `.scratch/navigation/spec.md`.

**Blocked by:** 03

**Status:** ready-for-agent

- [ ] Links to places inside the Document go through Jump and show the Back capsule
- [ ] On iOS, a single tap on a link doesn't switch Immersive Mode
- [ ] Links to web pages keep PDFKit's default behaviour (open in the default browser, no confirmation) and are not Jumps
- [ ] `ReaderPDFViewTests` cover: following an in-Document link records a Back place and Back returns to it
