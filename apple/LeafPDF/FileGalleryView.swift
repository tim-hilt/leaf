import SwiftUI
import UniformTypeIdentifiers

/// Lists the Library, newest Import first (see docs/features.md, "File
/// Gallery"), and opens the tapped Document in the Reader. Tapping "+"
/// Imports a PDF and opens it. Placeholder list until the grid exists.
struct FileGalleryView: View {
    @Environment(LibraryModel.self) private var library
    @State private var path: [LibraryDocument] = []
    @State private var isImporting = false
    @State private var failure: String?

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if library.documents.isEmpty {
                    ContentUnavailableView {
                        Label("No Documents", systemImage: "doc")
                    } actions: {
                        Button("Import…") { isImporting = true }
                    }
                } else {
                    List(library.documents) { document in
                        NavigationLink(document.title, value: document)
                    }
                }
            }
            .navigationTitle("LeafPDF")
            .navigationDestination(for: LibraryDocument.self) { ReaderView(document: $0.pdf) }
            .toolbar {
                Button("Import…", systemImage: "plus") { isImporting = true }
            }
        }
        .disabled(library.runningImport != nil)
        .overlay {
            if let running = library.runningImport { ImportProgressModal(running: running) }
        }
        .fileImporter(
            isPresented: $isImporting, allowedContentTypes: [.pdf], allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                Task { await importFile(url) }
            }
        }
        .alert(
            "Couldn't import", isPresented: Binding(get: { failure != nil }, set: { _ in failure = nil })
        ) {
        } message: {
            Text(failure ?? "")
        }
    }

    private func importFile(_ url: URL) async {
        switch await library.import(url) {
        case .opened(let document): path = [document]
        case .failed(let message): failure = message
        }
    }
}
