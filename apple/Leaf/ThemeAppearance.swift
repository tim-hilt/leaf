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
                for window in scene.windows {
                    window.overrideUserInterfaceStyle = style
                    // Open popovers miss style changes (FB20928471), so they are told.
                    var presented = window.rootViewController?.presentedViewController
                    while let controller = presented {
                        controller.traitOverrides.userInterfaceStyle =
                            style == .unspecified ? scene.traitCollection.userInterfaceStyle : style
                        presented = controller.presentedViewController
                    }
                }
            }
        #endif
    }
}

extension View {
    /// Applies `theme` now and whenever it changes; on iOS also whenever the system's
    /// appearance changes, and to menus and popovers, which get windows of their own.
    func applying(_ theme: Theme) -> some View { modifier(ThemeApplier(theme: theme)) }
}

private struct ThemeApplier: ViewModifier {
    let theme: Theme
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .onChange(of: theme, initial: true) { theme.apply() }
            #if os(iOS)
                .onChange(of: colorScheme) { theme.apply() }
                .onReceive(NotificationCenter.default.publisher(for: UIWindow.didBecomeVisibleNotification)) { _ in
                    theme.apply()
                }
            #endif
    }
}
