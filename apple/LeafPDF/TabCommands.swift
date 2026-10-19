import SwiftUI

extension FocusedValues {
    /// The focused window's Tabs while its Reader shows; nil in the Gallery, where Tab commands do nothing.
    @Entry var readerTabs: Tabs?
}

/// Close Tab (⌘W, replacing Close so the only window never closes by accident),
/// next and previous Tab (⌃Tab, ⌃⇧Tab) and Tab 1–9 (⌘1–9), on the focused
/// window. On macOS they sit in the Window menu.
struct TabCommands: Commands {
    @FocusedValue(\.readerTabs) private var tabs

    var body: some Commands {
        CommandGroup(replacing: .saveItem) {
            Button("Close Tab") { tabs?.closeActive() }
                .keyboardShortcut("w", modifiers: .command)
                .disabled(tabs == nil)
        }
        #if os(macOS)
            CommandGroup(after: .windowArrangement) { switching }
        #else
            CommandGroup(after: .toolbar) { switching }
        #endif
    }

    private var hasSeveralTabs: Bool { (tabs?.openIDs.count ?? 0) > 1 }

    @ViewBuilder private var switching: some View {
        Button("Show Next Tab") { tabs?.selectNext() }
            .keyboardShortcut(.tab, modifiers: .control)
            .disabled(!hasSeveralTabs)
        Button("Show Previous Tab") { tabs?.selectPrevious() }
            .keyboardShortcut(.tab, modifiers: [.control, .shift])
            .disabled(!hasSeveralTabs)
        Menu("Go to Tab") {
            ForEach(1...9, id: \.self) { number in
                Button("Tab \(number)") { tabs?.select(number: number) }
                    .keyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: .command)
                    .disabled(tabs.map { !$0.openIDs.indices.contains(number - 1) } ?? true)
            }
        }
    }
}
