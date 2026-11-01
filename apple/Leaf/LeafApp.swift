import LeafCore
import SwiftUI

@main
struct LeafApp: App {
    @State private var library: LibraryModel
    @State private var cloud: CloudBackingModel
    @State private var settings = AppSettings(defaults: .standard)
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let device: (library: LibraryModel, cloud: CloudBackingModel)
        do { device = try Self.openDevice() } catch { fatalError("Can't open the Library: \(error)") }
        _library = State(initialValue: device.library)
        _cloud = State(initialValue: device.cloud)
        #if os(macOS)
            // One window (ADR 0018); no native window tabs, nor their View menu items.
            NSWindow.allowsAutomaticWindowTabbing = false
        #endif
    }

    var body: some Scene {
        // One window per Device: Files from other apps go to it.
        #if os(macOS)
            Window("Leaf", id: "main") { content }
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
                    .environment(cloud)
                    .environment(settings)
                    .frame(width: 420)
            }
        #endif
    }

    @CommandsBuilder private var commands: some Commands {
        ImportCommands()
        #if os(macOS)
            ReaderCommands(settings: settings)
        #endif
    }

    private var content: some View {
        FileGalleryView()
            .environment(library)
            .environment(cloud)
            .environment(settings)
            .onChange(of: settings.theme, initial: true) { settings.theme.apply() }
            .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active: cloud.foreground()
                case .background: cloud.background()
                default: break
                }
            }
            #if os(macOS)
                // A Mac app's windows rarely reach the background: Sync rests while another app is active.
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
                    cloud.background()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    cloud.foreground()
                }
            #endif
    }

    /// The Library in a hidden folder in Application Support, with Covers in
    /// the system Caches folder, and the Cloud Backing of the same core Library.
    /// On iOS, the system hands over Files from other apps as copies in `Documents/Inbox`.
    private static func openDevice() throws -> (library: LibraryModel, cloud: CloudBackingModel) {
        let files = FileManager.default
        let support = try files.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let caches = try files.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        // Where details were kept before the core kept them; the background pass reads them again.
        try? files.removeItem(at: support.appending(path: "Details.json"))
        let core = try LeafCore.Library.open(
            root: support.appending(path: "Library", directoryHint: .isDirectory).path)
        let library = LibraryModel(
            core: core, coversFolder: caches.appending(path: "Covers", directoryHint: .isDirectory),
            defaults: .standard, inbox: systemInbox)
        let cloud = CloudBackingModel(
            core: core, library: library,
            credentials: CloudCredentials(defaults: .standard, service: "com.timhilt.leaf.cloud"))
        cloud.followNetwork()
        return (library, cloud)
    }

    private static var systemInbox: URL? {
        #if os(iOS)
            URL.documentsDirectory.appending(path: "Inbox", directoryHint: .isDirectory)
        #else
            nil
        #endif
    }
}
