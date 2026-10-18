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

    @ObservationIgnored private let defaults: UserDefaults
    private static let themeName = "settings.theme"

    init(defaults: UserDefaults) {
        self.defaults = defaults
        theme = defaults.string(forKey: Self.themeName).flatMap(Theme.init) ?? .system
    }
}
