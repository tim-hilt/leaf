import PDFKit
import SwiftUI

/// Lists all imported Documents (see docs/features.md, "File Gallery") and
/// opens the tapped one in the Reader. Placeholder until import exists.
struct FileGalleryView: View {
    var body: some View {
        NavigationStack {
            List {
                // TEMPORARY: remove with File Import (features §2)
                NavigationLink(SampleDocument.pdf.title, value: SampleDocument.pdf)
            }
            .navigationTitle("LeafPDF")
            .navigationDestination(for: PDFDocument.self) { ReaderView(document: $0) }
        }
    }
}
