#if os(macOS)
    import SwiftUI

    extension FocusedValues {
        /// The Reader of the focused window, if one is showing.
        @Entry var reader: ReaderHandle?
    }

    /// View menu zoom commands, acting on the focused window's Reader.
    struct ReaderCommands: Commands {
        @FocusedValue(\.reader) private var reader

        var body: some Commands {
            CommandGroup(after: .toolbar) {
                Button("Zoom In") { reader?.view?.zoomIn() }
                    .keyboardShortcut("+", modifiers: .command)
                    .disabled(reader == nil)
                Button("Zoom Out") { reader?.view?.zoomOut() }
                    .keyboardShortcut("-", modifiers: .command)
                    .disabled(reader == nil)
                Button("Fit to Width") { reader?.view?.zoomToFitWidth() }
                    .keyboardShortcut("0", modifiers: .command)
                    .disabled(reader == nil)
            }
        }
    }
#endif
