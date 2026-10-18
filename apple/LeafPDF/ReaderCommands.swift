#if os(macOS)
    import SwiftUI

    extension FocusedValues {
        /// The Reader of the focused window, if one is showing.
        @Entry var reader: ReaderHandle?
        /// Opens the focused Reader's Table of Contents; nil when it has none.
        @Entry var showTableOfContents: Binding<Bool>?
    }

    /// View menu zoom commands and the Go menu, acting on the focused window's Reader.
    struct ReaderCommands: Commands {
        @FocusedValue(\.reader) private var reader
        @FocusedValue(\.showTableOfContents) private var showTableOfContents

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
            CommandMenu("Go") {
                Button("Table of Contents") { showTableOfContents?.wrappedValue = true }
                    .keyboardShortcut("t", modifiers: [.option, .command])
                    .disabled(showTableOfContents == nil)
            }
        }
    }
#endif
