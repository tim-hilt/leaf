import SwiftUI

/// A Note in a popover: shown with clickable web links, or edited, where links
/// are plain text. "Edit" switches to editing; without a Note, "Add Note" does.
/// The edit is saved when "Done" is pressed or the view goes; emptying the Note
/// saves it as empty, which the owner takes as removing it.
struct NoteEditor: View {
    let note: String?
    /// Called with the edited text when editing ends, if it changed or is empty.
    let onNote: (String) -> Void

    @State private var isEditing: Bool
    @State private var draft: String
    @FocusState private var isFocused: Bool

    /// With `startsEditing`, the editor is open from the start, for typing right away.
    init(note: String?, startsEditing: Bool = false, onNote: @escaping (String) -> Void) {
        self.note = note
        self.onNote = onNote
        _isEditing = State(initialValue: startsEditing)
        _draft = State(initialValue: note ?? "")
    }

    var body: some View {
        content.onDisappear(perform: commit)
    }

    @ViewBuilder private var content: some View {
        if isEditing {
            VStack(alignment: .trailing) {
                TextEditor(text: $draft)
                    .focused($isFocused)
                    .frame(minHeight: 80, maxHeight: 200)
                    .overlay { RoundedRectangle(cornerRadius: 6).stroke(.quaternary) }
                    .onAppear { isFocused = true }
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

    /// Ends editing and saves the Note if it changed. An empty one is saved too:
    /// a new page Note has nothing to change but is to go.
    private func commit() {
        guard isEditing else { return }
        isEditing = false
        if draft != (note ?? "") || draft.isEmpty { onNote(draft) }
    }
}
