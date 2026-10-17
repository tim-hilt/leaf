import SwiftUI

@main
struct LeafPDFApp: App {
    @State private var library: LibraryModel = {
        do { return try .inApplicationSupport() } catch { fatalError("Can't open the Library: \(error)") }
    }()

    var body: some Scene {
        WindowGroup {
            FileGalleryView()
                .environment(library)
        }
        .commands {
            ImportCommands()
            #if os(macOS)
                ReaderCommands()
            #endif
        }
    }
}
