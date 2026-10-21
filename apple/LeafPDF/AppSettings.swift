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

    /// The paper and ink of Dark Pages. Changing them redraws open Readers at once and is saved.
    var pageColors: PageColors {
        didSet { defaults.set(pageColors.components, forKey: Self.pageColorsName) }
    }

    /// The text size of all EPUBs (`TextSize`). Changing it reflows open Readers at once and is saved.
    var epubTextSize: CGFloat {
        didSet { defaults.set(Double(epubTextSize), forKey: Self.epubTextSizeName) }
    }

    func resetPageColors() { pageColors = .default }

    /// Whether pages are dark under the current Page Style. Match Theme follows
    /// the Theme; with System that is the device's `systemScheme`.
    func arePagesDark(systemScheme: ColorScheme) -> Bool {
        switch pageStyle {
        case .light: false
        case .dark: true
        case .match: (theme.colorScheme ?? systemScheme) == .dark
        }
    }

    /// The Page Style ⇧⌘D switches to: Dark Pages if pages look light, else Light Pages.
    func oppositePageStyle(systemScheme: ColorScheme) -> PageStyle {
        arePagesDark(systemScheme: systemScheme) ? .light : .dark
    }

    func switchToOppositePageStyle(systemScheme: ColorScheme) {
        pageStyle = oppositePageStyle(systemScheme: systemScheme)
    }

    /// How pages are drawn under the current Page Style.
    func pageAppearance(systemScheme: ColorScheme) -> PageAppearance {
        arePagesDark(systemScheme: systemScheme) ? .dark(pageColors) : .light
    }

    @ObservationIgnored private let defaults: UserDefaults
    private static let themeName = "settings.theme"
    private static let pageStyleName = "settings.pageStyle"
    private static let pageColorsName = "settings.pageColors"
    private static let epubTextSizeName = "settings.epubTextSize"

    init(defaults: UserDefaults) {
        self.defaults = defaults
        theme = defaults.string(forKey: Self.themeName).flatMap(Theme.init) ?? .system
        pageStyle = defaults.string(forKey: Self.pageStyleName).flatMap(PageStyle.init) ?? .light
        pageColors = (defaults.array(forKey: Self.pageColorsName) as? [Double]).flatMap(PageColors.init) ?? .default
        epubTextSize =
            defaults.object(forKey: Self.epubTextSizeName) is Double
            ? TextSize.clamped(defaults.double(forKey: Self.epubTextSizeName)) : TextSize.normal
    }
}
