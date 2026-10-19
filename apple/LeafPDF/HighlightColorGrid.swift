import SwiftUI

/// A wrapping row of Highlight Color circles, the one equal to `selected` checked.
struct HighlightColorGrid: View {
    let colors: [HighlightColor]
    let selected: RGB
    let onSelect: (HighlightColor) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 36), spacing: 12)], spacing: 12) {
            ForEach(colors) { entry in
                let isSelected = entry.color == selected
                Button { onSelect(entry) } label: {
                    Circle()
                        .fill(Color(entry.color))
                        .frame(width: 32, height: 32)
                        .overlay { if isSelected { Image(systemName: "checkmark").foregroundStyle(.black.opacity(0.7)) } }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(entry.name)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
    }
}
