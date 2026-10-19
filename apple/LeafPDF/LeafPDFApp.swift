import SwiftUI

@main
struct LeafPDFApp: App {
    @State private var library: LibraryModel = {
        do { return try .inApplicationSupport() } catch { fatalError("Can't open the Library: \(error)") }
    }()

    @State private var settings = AppSettings(defaults: .standard)
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            FileGalleryView()
                .environment(library)
                .environment(settings)
                .preferredColorScheme(settings.theme.colorScheme)
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active: library.foreground()
                    case .background: library.background()
                    default: break
                    }
                }
        }
        .commands {
            ImportCommands()
            #if os(macOS)
                ReaderCommands(settings: settings)
            #endif
        }
        #if os(macOS)
            Settings {
                SettingsView()
                    .environment(library)
                    .environment(settings)
                    .preferredColorScheme(settings.theme.colorScheme)
                    .frame(width: 420)
            }
        #endif
    }
}
