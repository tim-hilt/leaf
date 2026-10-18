import Foundation
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
        #expect(settings.pageAppearance == .light)
        settings.pageStyle = .dark
        #expect(settings.pageAppearance == .dark(.default))
    }
}
