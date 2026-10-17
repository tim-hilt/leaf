import SwiftUI

@main
struct LeafPDFApp: App {
    var body: some Scene {
        WindowGroup {
            FileGalleryView()
        }
        #if os(macOS)
            .commands { ReaderCommands() }
        #endif
    }
}
