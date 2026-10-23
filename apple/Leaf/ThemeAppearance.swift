import SwiftUI

extension Theme {
    /// Restyles every window, and the sheets and popovers they present, at once.
    /// Unlike `.preferredColorScheme`, sheets don't get stuck on an old Theme.
    @MainActor func apply() {
        #if os(macOS)
            NSApp.appearance =
                switch self {
                case .system: nil
                case .light: NSAppearance(named: .aqua)
                case .dark: NSAppearance(named: .darkAqua)
                }
        #else
            let style: UIUserInterfaceStyle =
                switch self {
                case .system: .unspecified
                case .light: .light
                case .dark: .dark
                }
            for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
                for window in scene.windows { window.overrideUserInterfaceStyle = style }
            }
        #endif
    }
}
