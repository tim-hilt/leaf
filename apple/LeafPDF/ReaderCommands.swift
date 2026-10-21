#if os(macOS)
    import SwiftUI

    extension FocusedValues {
        /// The Reader of the focused window, if one is showing.
        @Entry var reader: ReaderHandle?
        /// The focused Reader's Back place; nil when it has none.
        @Entry var backTarget: BackTarget?
        /// Opens the focused Reader's Table of Contents; nil when it has none.
        @Entry var showTableOfContents: Binding<Bool>?
        /// Switches the focused Reader's pages to the opposite of what is showing (⇧⌘D).
        @Entry var switchPageStyle: (() -> Void)?
    }

    /// View menu zoom and Page Style commands, Edit > Highlight and Find and the Go menu, acting on the focused window's Reader.
    struct ReaderCommands: Commands {
        @FocusedValue(\.reader) private var reader
        @FocusedValue(\.showTableOfContents) private var showTableOfContents
        @FocusedValue(\.backTarget) private var backTarget
        @FocusedValue(\.switchPageStyle) private var switchPageStyle
        let settings: AppSettings

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
                Divider()
                ForEach(PageStyle.allCases) { style in
                    Toggle(
                        style.title,
                        isOn: Binding(get: { settings.pageStyle == style }, set: { _ in settings.pageStyle = style }))
                }
                Button("Switch Light and Dark Pages") { switchPageStyle?() }
                    .keyboardShortcut("d", modifiers: [.shift, .command])
                    .disabled(switchPageStyle == nil)
            }
            CommandGroup(after: .textEditing) {
                Button("Highlight") { reader?.view?.highlightSelection() }
                    .keyboardShortcut("h", modifiers: [.control, .command])
                    .disabled(reader == nil)
                Menu("Find") {
                    Button("Find…") { reader?.view?.presentFind() }
                        .keyboardShortcut("f", modifiers: .command)
                    Button("Find Next") { reader?.view?.findNext() }
                        .keyboardShortcut("g", modifiers: .command)
                    Button("Find Previous") { reader?.view?.findPrevious() }
                        .keyboardShortcut("g", modifiers: [.shift, .command])
                }
                .disabled(reader == nil)
            }
            CommandMenu("Go") {
                Button(backTarget.map { "Back to \($0.name)" } ?? "Back") { reader?.view?.goBack() }
                    .disabled(backTarget == nil)
                Button("Table of Contents") { showTableOfContents?.wrappedValue = true }
                    .keyboardShortcut("t", modifiers: [.option, .command])
                    .disabled(showTableOfContents == nil)
            }
        }
    }
#endif
