#if os(macOS)
    import SwiftUI

    extension FocusedValues {
        /// The Reader of the focused window, if one is showing.
        @Entry var reader: ReaderHandle?
        /// Printed page number of the focused Reader's Back place; nil when it has none.
        @Entry var backPageNumber: String?
        /// Opens the focused Reader's Table of Contents; nil when it has none.
        @Entry var showTableOfContents: Binding<Bool>?
    }

    /// View menu zoom commands, Edit > Find and the Go menu, acting on the focused window's Reader.
    struct ReaderCommands: Commands {
        @FocusedValue(\.reader) private var reader
        @FocusedValue(\.showTableOfContents) private var showTableOfContents
        @FocusedValue(\.backPageNumber) private var backPageNumber

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
            CommandGroup(after: .textEditing) {
                Menu("Find") {
                    Button("Find…") { reader?.view?.presentFind() }
                        .keyboardShortcut("f", modifiers: .command)
                    Button("Find Next") { reader?.view?.find.next() }
                        .keyboardShortcut("g", modifiers: .command)
                    Button("Find Previous") { reader?.view?.find.previous() }
                        .keyboardShortcut("g", modifiers: [.shift, .command])
                }
                .disabled(reader == nil)
            }
            CommandMenu("Go") {
                Button(backPageNumber.map { "Back to p. \($0)" } ?? "Back") { reader?.view?.goBack() }
                    .disabled(backPageNumber == nil)
                Button("Table of Contents") { showTableOfContents?.wrappedValue = true }
                    .keyboardShortcut("t", modifiers: [.option, .command])
                    .disabled(showTableOfContents == nil)
            }
        }
    }
#endif
