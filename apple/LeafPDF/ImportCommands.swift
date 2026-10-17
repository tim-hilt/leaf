import SwiftUI

extension FocusedValues {
    /// Whether the focused window shows its Import picker; nil while that
    /// window can't Import (an Import is already running).
    @Entry var isImporting: Binding<Bool>?
}

/// File > Import… (⌘O), after "New Window", which stays so that a second
/// window can be opened. Acts on the focused window, whether it shows the
/// Gallery or the Reader.
struct ImportCommands: Commands {
    @FocusedBinding(\.isImporting) private var isImporting

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Import…") { isImporting = true }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(isImporting == nil)
        }
    }
}
