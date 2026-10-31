import LeafCore
import SwiftUI

/// What a Highlight's popover offers: its Note (`NoteEditor`), its color among the
/// Highlight Colors in a row of five that scrolls, the current one checked (an
/// extra circle if it is no longer one), and removing it without confirmation.
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
            NoteEditor(note: note, onNote: onNote)
            HighlightColorGrid(
                colors: colors.including(color), selected: color, scrollingRow: 5, onSelect: { onColor($0.tint) })
            Button("Remove Highlight", systemImage: "trash", role: .destructive, action: onRemove)
        }
        .padding()
        // A popover is as big as its content's ideal size; at no width, the grid
        // is a single column and a Note a single line.
        .frame(minWidth: 260, idealWidth: 280)
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
        .frame(minWidth: 260, idealWidth: 280)
        .presentationDetents([.medium, .large])
    }
}
