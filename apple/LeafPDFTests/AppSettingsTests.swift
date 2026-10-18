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
