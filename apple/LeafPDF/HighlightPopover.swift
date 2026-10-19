import SwiftUI

/// What a Highlight's popover offers: its color among the built-in Highlight
/// Colors, the current one checked, and removing it without confirmation.
struct HighlightPopover: View {
    let colors: [HighlightColor]
    let color: RGB
    let onColor: (RGB) -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            HighlightColorGrid(colors: colors, selected: color, onSelect: { onColor($0.color) })
            Button("Remove Highlight", systemImage: "trash", role: .destructive, action: onRemove)
        }
        .padding()
        .frame(minWidth: 260)
        .presentationDetents([.height(180)])
    }
}
