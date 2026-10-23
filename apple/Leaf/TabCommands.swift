import SwiftUI

extension FocusedValues {
    /// The Tabs of the main window while it is focused; nil while another window (Settings) is.
    @Entry var tabs: Tabs?
}

/// Close Tab (⌘W), next and previous Tab (⌃Tab, ⌃⇧Tab) and Tab 1–9 (⌘1–9),
/// enabled only while the Reader shows. On macOS they sit in the Window menu.
/// ⌘W replaces Close, so it never closes the main window; other windows
/// (Settings) still close with it.
struct TabCommands: Commands {
    @FocusedValue(\.tabs) private var tabs

    var body: some Commands {
        CommandGroup(replacing: .saveItem) {
            #if os(macOS)
                if tabs == nil {
                    Button("Close") { NSApp.keyWindow?.performClose(nil) }
                        .keyboardShortcut("w", modifiers: .command)
                } else {
                    closeTab
                }
            #else
                closeTab
            #endif
        }
        #if os(macOS)
            CommandGroup(after: .windowArrangement) { switching }
        #else
            CommandGroup(after: .toolbar) { switching }
        #endif
    }

    /// The Tabs while the Reader shows; nil in the Gallery, where Tab commands do nothing.
    private var readerTabs: Tabs? { tabs.flatMap { $0.isShowingReader ? $0 : nil } }

    private var closeTab: some View {
        Button("Close Tab") { readerTabs?.closeActive() }
            .keyboardShortcut("w", modifiers: .command)
            .disabled(readerTabs == nil)
    }

    private var hasSeveralTabs: Bool { (readerTabs?.openIDs.count ?? 0) > 1 }

    @ViewBuilder private var switching: some View {
        Button("Show Next Tab") { readerTabs?.selectNext() }
            .keyboardShortcut(.tab, modifiers: .control)
            .disabled(!hasSeveralTabs)
        Button("Show Previous Tab") { readerTabs?.selectPrevious() }
            .keyboardShortcut(.tab, modifiers: [.control, .shift])
            .disabled(!hasSeveralTabs)
        Menu("Go to Tab") {
            ForEach(1...9, id: \.self) { number in
                Button("Tab \(number)") { readerTabs?.select(number: number) }
                    .keyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: .command)
                    .disabled(readerTabs.map { !$0.openIDs.indices.contains(number - 1) } ?? true)
            }
        }
    }
}
