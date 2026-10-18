import SwiftUI

/// Whether LeafPDF looks light or dark. System follows the device.
enum Theme: String, CaseIterable {
    case system, light, dark

    /// The color scheme to force on the interface; nil follows the system.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// This device's preferences, remembered in user defaults (never synced) and
/// shared by all windows.
@MainActor @Observable
final class AppSettings {
    /// Changing it restyles the whole interface at once and is saved.
    var theme: Theme {
        didSet { defaults.set(theme.rawValue, forKey: Self.themeName) }
    }

    /// Changing it redraws open Readers at once and is saved.
    var pageStyle: PageStyle {
        didSet { defaults.set(pageStyle.rawValue, forKey: Self.pageStyleName) }
    }

    /// How pages are drawn under the current Page Style.
    var pageAppearance: PageAppearance {
        switch pageStyle {
        case .light: .light
        case .dark: .dark(.default)
        }
    }

    @ObservationIgnored private let defaults: UserDefaults
    private static let themeName = "settings.theme"
    private static let pageStyleName = "settings.pageStyle"

    init(defaults: UserDefaults) {
        self.defaults = defaults
        theme = defaults.string(forKey: Self.themeName).flatMap(Theme.init) ?? .system
        pageStyle = defaults.string(forKey: Self.pageStyleName).flatMap(PageStyle.init) ?? .light
    }
}
