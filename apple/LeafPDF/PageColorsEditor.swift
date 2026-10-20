import SwiftUI

/// Pickers for the Page color (paper) and Text color (ink) of Dark Pages, and a
/// Reset button, in the Reader popover.
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
