import SwiftUI

/// The Page Styles as outlined circles: white for Light Pages, the Page color
/// for Dark Pages, half and half for Match Theme. An accent ring marks the chosen one.
struct PageStylePicker: View {
    @Binding var selection: PageStyle
    let paper: RGB

    var body: some View {
        HStack(spacing: 20) {
            ForEach(PageStyle.allCases) { style in
                Button {
                    selection = style
                } label: {
                    swatch(style)
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

    @ViewBuilder
    private func swatch(_ style: PageStyle) -> some View {
        switch style {
        case .light: Circle().fill(Color.white)
        case .dark: Circle().fill(Color(paper))
        case .match:
            Circle().fill(Color.white)
                .overlay { HalfDisc().fill(Color(paper)) }
        }
    }
}

/// The right half of a circle.
private struct HalfDisc: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addArc(
            center: CGPoint(x: rect.midX, y: rect.midY), radius: rect.width / 2,
            startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false)
        path.closeSubpath()
        return path
    }
}
