# Tabs in one window, not native window tabs

LeafPDF is one window per Device, on iPhone, iPad and Mac. The Reader keeps several Documents open as Tabs in a custom strip under the toolbar. A `Tabs` model owns the window's state: the open Documents, the active one, and whether the Reader or the Gallery shows. The Mac app uses a single `Window` scene; iPadOS supports one scene. Tabs are saved per Device in user defaults and never synced.

## Considered Options

- **Native NSWindow tabbing on macOS**: free strip and shortcuts, but Mac only. iPhone and iPad would need another model, and Documents could be open in two windows at once.
- **Several windows**: no equivalent on iPhone, and switching between windows is slow.

## Consequences

- The same model and the same strip on all three platforms, at the cost of one custom UI piece (the strip) and our own ⌘W, ⌃Tab and ⌘1–9 commands. This is the one place where "native UI wherever possible" gives way.
- Only the active Tab loads its PDF, so many Tabs stay light.
- Opening a Document twice is impossible by construction.
