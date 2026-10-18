import SwiftUI

/// Pickers for the Page color (paper) and Text color (ink) of Dark Pages, and a
/// Reset button. Edits the same Page Colors in Settings and in the Reader popover.
struct PageColorsEditor: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        VStack(alignment: .leading, spacing: 12) {
            ColorPicker("Page", selection: binding($settings.pageColors.paper), supportsOpacity: false)
            ColorPicker("Text", selection: binding($settings.pageColors.ink), supportsOpacity: false)
            Button("Reset") { settings.resetPageColors() }
                .disabled(settings.pageColors == .default)
        }
    }

    private func binding(_ rgb: Binding<RGB>) -> Binding<Color> {
        Binding(get: { Color(rgb.wrappedValue) }, set: { rgb.wrappedValue = RGB($0) })
    }
}

/// A sample page as Dark Pages: paper, text lines in ink and a red accent that keeps its hue.
struct PageColorsPreview: View {
    let colors: PageColors

    var body: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Color(colors.paper))
            .frame(height: 96)
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Sample page").font(.subheadline.bold())
                    ForEach([180.0, 150.0, 100.0], id: \.self) { width in
                        RoundedRectangle(cornerRadius: 2).frame(width: width, height: 4)
                    }
                }
                .foregroundStyle(Color(colors.ink))
                .padding(12)
            }
            .overlay(alignment: .bottomTrailing) {
                Circle().fill(Color(red: 0.75, green: 0.3, blue: 0.3)).frame(width: 14, height: 14).padding(12)
            }
            .accessibilityHidden(true)
    }
}

extension Color {
    init(_ rgb: RGB) { self.init(.sRGB, red: rgb.r, green: rgb.g, blue: rgb.b) }
}

extension RGB {
    init(_ color: Color) {
        let resolved = color.resolve(in: EnvironmentValues())
        func clamp(_ x: Float) -> Double { Double(min(max(x, 0), 1)) }
        self.init(clamp(resolved.red), clamp(resolved.green), clamp(resolved.blue))
    }
}
