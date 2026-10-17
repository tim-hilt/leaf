import LeafCore
import SwiftUI

/// Grid of all imported files (see docs/features.md, "File Gallery").
/// Placeholder until import exists; shows the core version to prove the
/// app is linked against the Rust core.
struct FileGalleryView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "No Files",
                systemImage: "doc.richtext",
                description: Text("LeafPDF core \(coreVersion())")
            )
            .navigationTitle("LeafPDF")
        }
    }
}
