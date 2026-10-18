import SwiftUI

@main
struct LeafPDFApp: App {
    @State private var library: LibraryModel = {
        do { return try .inApplicationSupport() } catch { fatalError("Can't open the Library: \(error)") }
    }()

    @State private var settings = AppSettings(defaults: .standard)

    var body: some Scene {
        WindowGroup {
            FileGalleryView()
                .environment(library)
                .environment(settings)
                .preferredColorScheme(settings.theme.colorScheme)
        }
        .commands {
            ImportCommands()
            #if os(macOS)
                ReaderCommands()
            #endif
        }
        #if os(macOS)
            Settings {
                SettingsView()
                    .environment(settings)
                    .preferredColorScheme(settings.theme.colorScheme)
                    .frame(width: 420)
            }
        #endif
    }
}
