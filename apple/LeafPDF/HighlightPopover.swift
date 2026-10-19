import SwiftUI

/// What a Highlight's popover offers: its color among the Highlight Colors, the
/// current one checked (an extra circle if it is no longer one), its Note
/// (`NoteEditor`), and removing it without confirmation.
struct HighlightPopover: View {
    let colors: [HighlightColor]
    let color: RGB
    let note: String?
    let onColor: (RGB) -> Void
    /// Called with the edited Note; empty means the Note is removed.
    let onNote: (String) -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            HighlightColorGrid(colors: colors.including(color), selected: color, onSelect: { onColor($0.color) })
            NoteEditor(note: note, onNote: onNote)
            Button("Remove Highlight", systemImage: "trash", role: .destructive, action: onRemove)
        }
        .padding()
        .frame(minWidth: 260)
        .presentationDetents([.medium, .large])
    }
}

/// What a page Note's popover offers: its Note (`NoteEditor`), and removing it
/// without confirmation. A new page Note opens in editing.
struct PageNotePopover: View {
    let text: String
    let startsEditing: Bool
    /// Called with the edited Note; empty means the page Note is removed.
    let onText: (String) -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            NoteEditor(note: text.isEmpty ? nil : text, startsEditing: startsEditing, onNote: onText)
            Button("Remove Note", systemImage: "trash", role: .destructive, action: onRemove)
        }
        .padding()
        .frame(minWidth: 260)
        .presentationDetents([.medium, .large])
    }
}
