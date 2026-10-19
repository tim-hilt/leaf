import SwiftUI

@main
struct LeafPDFApp: App {
    @State private var library: LibraryModel
    @State private var tabs: Tabs
    @State private var settings = AppSettings(defaults: .standard)
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let library: LibraryModel
        do { library = try .inApplicationSupport() } catch { fatalError("Can't open the Library: \(error)") }
        _library = State(initialValue: library)
        _tabs = State(initialValue: Tabs(defaults: .standard, library: library.documents))
    }

    var body: some Scene {
        // One window per Device: all Tabs live in it, and Files from other apps go to it.
        #if os(macOS)
            Window("LeafPDF", id: "main") { content }
                .handlesExternalEvents(matching: ["*"])
                .commands { commands }
        #else
            WindowGroup { content }
                .handlesExternalEvents(matching: ["*"])
                .commands { commands }
        #endif
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

    @CommandsBuilder private var commands: some Commands {
        ImportCommands()
        TabCommands()
        #if os(macOS)
            ReaderCommands(settings: settings)
        #endif
    }

    private var content: some View {
        FileGalleryView()
            .environment(library)
            .environment(tabs)
            .environment(settings)
            .preferredColorScheme(settings.theme.colorScheme)
            .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active: library.foreground()
                case .background: library.background()
                default: break
                }
            }
    }
}
