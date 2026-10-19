import SwiftUI

/// What a Highlight's popover offers: its color among the Highlight Colors, the
/// current one checked (an extra circle if it is no longer one), its Note, and
/// removing it without confirmation.
///
/// The Note is shown with clickable web links; "Edit" switches to editing, where
/// links are plain text. Without a Note, "Add Note" starts editing. The Note is
/// saved when editing is done or the popover goes; emptying it removes it.
struct HighlightPopover: View {
    let colors: [HighlightColor]
    let color: RGB
    let note: String?
    let onColor: (RGB) -> Void
    /// Called with the edited Note; empty means the Note is removed.
    let onNote: (String) -> Void
    let onRemove: () -> Void

    @State private var isEditing = false
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 16) {
            HighlightColorGrid(colors: colors.including(color), selected: color, onSelect: { onColor($0.color) })
            noteSection
            Button("Remove Highlight", systemImage: "trash", role: .destructive, action: onRemove)
        }
        .padding()
        .frame(minWidth: 260)
        .presentationDetents([.medium, .large])
        .onDisappear(perform: commit)
    }

    @ViewBuilder private var noteSection: some View {
        if isEditing {
            VStack(alignment: .trailing) {
                TextEditor(text: $draft)
                    .frame(minHeight: 80, maxHeight: 200)
                    .overlay { RoundedRectangle(cornerRadius: 6).stroke(.quaternary) }
                Button("Done", action: commit)
            }
        } else if let note {
            VStack(alignment: .leading) {
                Text(NoteLinks.attributed(note))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                Button("Edit") { startEditing(note) }
            }
        } else {
            Button("Add Note", systemImage: "note.text.badge.plus") { startEditing("") }
        }
    }

    private func startEditing(_ note: String) {
        draft = note
        isEditing = true
    }

    /// Ends editing and saves the Note if it changed.
    private func commit() {
        guard isEditing else { return }
        isEditing = false
        if draft != (note ?? "") { onNote(draft) }
    }
}
