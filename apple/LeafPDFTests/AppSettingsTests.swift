import Foundation
import SwiftUI
import Testing

@testable import LeafPDF

@MainActor @Suite struct AppSettingsTests {
    /// This device's user defaults: one suite per test.
    let defaults = UserDefaults(suiteName: UUID().uuidString)!

    @Test func themeDefaultsToSystem() {
        #expect(AppSettings(defaults: defaults).theme == .system)
    }

    @Test(arguments: [Theme.light, .dark, .system])
    func chosenThemeSurvivesARestart(theme: Theme) {
        AppSettings(defaults: defaults).theme = theme
        #expect(AppSettings(defaults: defaults).theme == theme)
    }

    @Test func unknownSavedThemeFallsBackToSystem() {
        defaults.set("sepia", forKey: "settings.theme")
        #expect(AppSettings(defaults: defaults).theme == .system)
    }
}

extension AppSettingsTests {
    @Test func pageStyleDefaultsToLightPages() {
        #expect(AppSettings(defaults: defaults).pageStyle == .light)
    }

    @Test(arguments: [PageStyle.dark, .light])
    func chosenPageStyleSurvivesARestart(style: PageStyle) {
        AppSettings(defaults: defaults).pageStyle = style
        #expect(AppSettings(defaults: defaults).pageStyle == style)
    }

    @Test func unknownSavedPageStyleFallsBackToLightPages() {
        defaults.set("sepia", forKey: "settings.pageStyle")
        #expect(AppSettings(defaults: defaults).pageStyle == .light)
    }

    @Test func pagesAreDrawnPerPageStyle() {
        let settings = AppSettings(defaults: defaults)
        #expect(settings.pageAppearance(systemScheme: .light) == .light)
        settings.pageStyle = .dark
        #expect(settings.pageAppearance(systemScheme: .light) == .dark(.default))
        settings.pageStyle = .match
        settings.theme = .dark
        #expect(settings.pageAppearance(systemScheme: .light) == .dark(.default))
    }

    @Test(arguments: [
        (Theme.dark, ColorScheme.light, true), (.dark, .dark, true),
        (.light, .light, false), (.light, .dark, false),
        (.system, .light, false), (.system, .dark, true),
    ])
    func matchThemeFollowsTheTheme(theme: Theme, system: ColorScheme, dark: Bool) {
        let settings = AppSettings(defaults: defaults)
        settings.pageStyle = .match
        settings.theme = theme
        #expect(settings.arePagesDark(systemScheme: system) == dark)
    }

    @Test(arguments: Theme.allCases, [ColorScheme.light, .dark])
    func lightAndDarkPagesIgnoreTheTheme(theme: Theme, system: ColorScheme) {
        let settings = AppSettings(defaults: defaults)
        settings.theme = theme
        settings.pageStyle = .light
        #expect(!settings.arePagesDark(systemScheme: system))
        settings.pageStyle = .dark
        #expect(settings.arePagesDark(systemScheme: system))
    }

    @Test func matchThemeSurvivesARestart() {
        AppSettings(defaults: defaults).pageStyle = .match
        #expect(AppSettings(defaults: defaults).pageStyle == .match)
    }
}

extension AppSettingsTests {
    @Test(arguments: [
        (PageStyle.light, Theme.system, ColorScheme.light, PageStyle.dark),
        (.dark, .system, .light, .light),
        (.match, .light, .light, .dark),
        (.match, .system, .dark, .light),
        (.match, .dark, .light, .light),
    ])
    func shortcutSwitchesToTheOppositeOfWhatIsShowing(
        style: PageStyle, theme: Theme, system: ColorScheme, target: PageStyle
    ) {
        let settings = AppSettings(defaults: defaults)
        settings.pageStyle = style
        settings.theme = theme
        #expect(settings.oppositePageStyle(systemScheme: system) == target)
        settings.switchToOppositePageStyle(systemScheme: system)
        #expect(settings.pageStyle == target)
    }
}

extension AppSettingsTests {
    @Test func pageColorsDefaultToDarkGreyAndLightGrey() {
        #expect(AppSettings(defaults: defaults).pageColors == .default)
    }

    @Test func chosenPageColorsSurviveARestart() {
        AppSettings(defaults: defaults).pageColors = .sepia
        #expect(AppSettings(defaults: defaults).pageColors == .sepia)
    }

    @Test func resetRestoresTheDefaultPageColors() {
        let settings = AppSettings(defaults: defaults)
        settings.pageColors = .sepia
        settings.resetPageColors()
        #expect(settings.pageColors == .default)
        #expect(AppSettings(defaults: defaults).pageColors == .default)
    }

    @Test func unreadableSavedPageColorsFallBackToTheDefaults() {
        defaults.set([0.1, 0.2], forKey: "settings.pageColors")
        #expect(AppSettings(defaults: defaults).pageColors == .default)
    }

    @Test func darkPagesAreDrawnInTheChosenPageColors() {
        let settings = AppSettings(defaults: defaults)
        settings.pageStyle = .dark
        settings.pageColors = .sepia
        #expect(settings.pageAppearance(systemScheme: .light) == .dark(.sepia))
    }
}

extension PageColors {
    fileprivate static let sepia = PageColors(
        paper: RGB(0x2B / 255, 0x21 / 255, 0x16 / 255), ink: RGB(0xE0 / 255, 0xC8 / 255, 0xA0 / 255))
}
