import LeafCore
import SwiftUI

/// A wrapping row of Highlight Color circles, the one equal to `selected` checked,
/// then `trailing`. With `onRemove`, a Custom Color's context menu offers "Remove";
/// while `isEditing`, Custom Colors show a minus badge and tapping one removes it.
struct HighlightColorGrid<Trailing: View>: View {
    let colors: [HighlightColor]
    let selected: RGB
    let onSelect: (HighlightColor) -> Void
    var onRemove: ((HighlightColor) -> Void)?
    var isEditing = false
    @ViewBuilder var trailing: Trailing

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 36), spacing: 12)], spacing: 12) {
            ForEach(colors, id: \.id) { entry in
                let isSelected = entry.tint == selected
                let removing = isEditing && entry.isCustom && onRemove != nil
                Button {
                    if removing { onRemove?(entry) } else { onSelect(entry) }
                } label: {
                    Circle()
                        .fill(Color(entry.tint))
                        .frame(width: 32, height: 32)
                        .overlay {
                            if isSelected { Image(systemName: "checkmark").foregroundStyle(.black.opacity(0.7)) }
                        }
                        .overlay(alignment: .topLeading) {
                            if removing {
                                Image(systemName: "minus.circle.fill")
                                    .symbolRenderingMode(.multicolor)
                                    .foregroundStyle(.white, .red)
                                    .offset(x: -4, y: -4)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(removing ? "Remove \(entry.name)" : entry.name)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .contextMenu {
                    if entry.isCustom, let onRemove {
                        Button("Remove", systemImage: "trash", role: .destructive) { onRemove(entry) }
                    }
                }
            }
            trailing
        }
    }
}

extension HighlightColorGrid where Trailing == EmptyView {
    init(colors: [HighlightColor], selected: RGB, onSelect: @escaping (HighlightColor) -> Void) {
        self.init(colors: colors, selected: selected, onSelect: onSelect, trailing: { EmptyView() })
    }
}

/// A "+" circle that opens the system color picker. The color is added once it
/// has stayed put for a moment, as the picker reports every change while dragging.
struct AddCustomColorButton: View {
    let onAdd: (RGB) -> Void
    @State private var picked: Color?

    var body: some View {
        Circle()
            .strokeBorder(.secondary, style: StrokeStyle(lineWidth: 1.5, dash: [4]))
            .frame(width: 32, height: 32)
            .overlay { Image(systemName: "plus").foregroundStyle(.secondary) }
            .overlay {
                ColorPicker(
                    "Add Custom Color", selection: Binding(get: { picked ?? .gray }, set: { picked = $0 }),
                    supportsOpacity: false
                )
                .labelsHidden()
                .frame(width: 32, height: 32)
                .opacity(0.02)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Add Custom Color")
            .task(id: picked) {
                guard let color = picked else { return }
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                picked = nil
                onAdd(RGB(color))
            }
    }
}
