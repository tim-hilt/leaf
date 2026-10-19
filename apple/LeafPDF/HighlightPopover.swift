import SwiftUI

/// What a Highlight's popover offers: its color among the built-in Highlight
/// Colors, the current one checked, and removing it without confirmation.
struct HighlightPopover: View {
    let color: RGB
    let onColor: (RGB) -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 36), spacing: 12)], spacing: 12) {
                ForEach(Highlight.builtInColors, id: \.name) { entry in
                    Button { onColor(entry.color) } label: {
                        Circle()
                            .fill(Color(entry.color))
                            .frame(width: 32, height: 32)
                            .overlay { if entry.color == color { Image(systemName: "checkmark").foregroundStyle(.black.opacity(0.7)) } }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(entry.name)
                    .accessibilityAddTraits(entry.color == color ? .isSelected : [])
                }
            }
            Button("Remove Highlight", systemImage: "trash", role: .destructive, action: onRemove)
        }
        .padding()
        .frame(minWidth: 260)
        .presentationDetents([.height(180)])
    }
}
