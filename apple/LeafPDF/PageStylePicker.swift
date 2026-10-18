import SwiftUI

/// The Page Styles as outlined circles: white for Light Pages, the Page color
/// for Dark Pages. An accent ring marks the chosen one.
struct PageStylePicker: View {
    @Binding var selection: PageStyle

    var body: some View {
        HStack(spacing: 20) {
            ForEach(PageStyle.allCases) { style in
                Button { selection = style } label: {
                    Circle()
                        .fill(fill(style))
                        .overlay(Circle().strokeBorder(.secondary.opacity(0.6), lineWidth: 1))
                        .frame(width: 36, height: 36)
                        .padding(4)
                        .overlay {
                            if style == selection { Circle().strokeBorder(Color.accentColor, lineWidth: 3) }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(style.title)
                .accessibilityAddTraits(style == selection ? .isSelected : [])
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func fill(_ style: PageStyle) -> Color {
        switch style {
        case .light: return Color.white
        case .dark:
            let paper = PageColors.default.paper
            return Color(.sRGB, red: paper.r, green: paper.g, blue: paper.b)
        }
    }
}
