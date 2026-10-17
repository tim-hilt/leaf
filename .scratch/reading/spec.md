# Reading

Status: ready-for-agent

Feature §1 of `docs/features.md`. Terms per `GLOSSARY.md`.

## Scope

Swift/PDFKit only (ADR-0003). No core or FFI changes.

## Requirements

### Reader

- Wraps PDFKit's native `PDFView` (`UIViewRepresentable` / `NSViewRepresentable`).
- Pages in one vertical column with continuous scrolling, on every platform and in every orientation. No paging, no two-up.
- Navigation bar shows the Document's Title (PDF metadata title, falling back to the file name).
- Standard back chevron returns to the Gallery, along with the native edge swipe (iOS) and ⌘[ (macOS).
- No other UI: no page counter, thumbnails or toolbar.

### Zoom

- Opens at fit-to-width. Minimum zoom is fit-to-width, maximum is 5×.
- Pinch zooms on all platforms. Double-tap zooms on iOS. ⌘+ / ⌘− / ⌘0 zoom on macOS (⌘0 returns to fit-to-width).
- Pinch keeps the content under the fingers fixed. Keyboard zoom keeps the content at the top of the viewport fixed.

### Keeping your place

- Rotating the device or resizing the window keeps the content at the top of the viewport in place.
- At fit-to-width: re-fit to the new width. Zoomed in: keep the zoom relative to fit-to-width.
- Store the place as page index + page-space point, so Reading Progress (§4) can reuse it.

### Immersive Mode

- The Reader opens with its UI showing. Scrolling never hides it.
- iOS/iPadOS: a single tap on the page toggles Immersive Mode. It hides the navigation bar and status bar, and the home indicator fades automatically.
- macOS: Immersive Mode is the native full screen (⌃⌘F / green button). The toolbar is hidden and appears when the pointer moves to the top edge. Clicks never toggle it.

### Temporary sample Document

- A public-domain PDF under 1 MB with several pages, an outline and at least one page of a different size.
- Bundled in `apple/LeafPDF/Temporary/`. The code that uses it is marked `// TEMPORARY: remove with File Import (features §2)`.
- The placeholder Gallery shows it as the only entry. Tapping it pushes the Reader in the same window.

## Out of scope

- Saving your place between visits (Reading Progress, §4). Reopening starts at page 1, fit-to-width.
- Opening Documents in separate macOS windows.
- Error handling for unreadable PDFs (comes with File Import, §2).

## Testing

- TDD for the logic: zoom limits, rules for keeping your place, the Title fallback.
- Manual check on iPhone, iPad and Mac, in both orientations and at several window sizes.
