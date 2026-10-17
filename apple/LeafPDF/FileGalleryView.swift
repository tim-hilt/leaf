import SwiftUI
import UniformTypeIdentifiers

/// The Library as a vertically scrolling grid of Documents, newest Import
/// first, led by a "+" cell that Imports. A click or tap opens a Document in
/// the Reader. The toolbar "+" and File > Import… (also from the Reader) Import
/// a PDF and open it, replacing any open Document. A cell's context menu
/// (long-press, right-click) or VoiceOver action offers "Remove", after
/// confirmation. A window reading a Document that gets Removed (here or in
/// another window) returns to the grid and says so.
struct FileGalleryView: View {
    @Environment(LibraryModel.self) private var library
    @State private var path: [LibraryDocument] = []
    @State private var isImporting = false
    @State private var rejection: ImportAlert?
    @State private var duplicate: LibraryDocument?
    @State private var removal: LibraryDocument?
    @State private var removedWhileOpen: LibraryDocument?

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 16, alignment: .top)], spacing: 16) {
                    Button { isImporting = true } label: { ImportCell() }
                        .accessibilityLabel("Import…")
                    ForEach(library.documents) { document in
                        Button { path.append(document) } label: { DocumentCell(document: document) }
                            .contextMenu {
                                Button("Remove", systemImage: "trash", role: .destructive) { removal = document }
                            }
                            .accessibilityLabel(document.title)
                            .accessibilityAction(named: "Remove") { removal = document }
                    }
                }
                .buttonStyle(.plain)
                .padding(16)
            }
            .navigationTitle("LeafPDF")
            .navigationDestination(for: LibraryDocument.self) { ReaderView(document: $0) }
            .toolbar {
                Button("Import…", systemImage: "plus") { isImporting = true }
            }
        }
        .onChange(of: library.documents) { _, documents in
            guard let gone = path.first(where: { !documents.contains($0) }) else { return }
            path = []
            removedWhileOpen = gone
        }
        .disabled(library.runningImport != nil)
        .focusedSceneValue(\.isImporting, library.runningImport == nil ? $isImporting : nil)
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
            rejection?.title ?? "", isPresented: Binding(get: { rejection != nil }, set: { _ in rejection = nil }),
            presenting: rejection
        ) { _ in
        } message: { alert in
            Text(alert.message)
        }
        .confirmationDialog(
            "Remove “\(removal?.title ?? "")”?", isPresented: Binding(get: { removal != nil }, set: { _ in removal = nil }),
            titleVisibility: .visible, presenting: removal
        ) { document in
            Button("Remove", role: .destructive) { library.remove(document) }
        } message: { _ in
            Text("The file, its markup and your reading progress are deleted on all your devices.")
        }
        .alert(
            "Document removed", isPresented: Binding(get: { removedWhileOpen != nil }, set: { _ in removedWhileOpen = nil }),
            presenting: removedWhileOpen
        ) { _ in
        } message: { gone in
            Text("“\(gone.title)” was removed from your Library.")
        }
        .alert(
            "Already in your Library", isPresented: Binding(get: { duplicate != nil }, set: { _ in duplicate = nil }),
            presenting: duplicate
        ) { existing in
            Button("Open") { path = [existing] }
            Button("Cancel", role: .cancel) {}
        } message: { existing in
            Text("“\(existing.title)” is already in your Library, so nothing was copied.")
        }
    }

    private func importFile(_ url: URL) async {
        switch await library.import(url) {
        case .opened(let document): path = [document]
        case .duplicate(let document): duplicate = document
        case .rejected(let reason): rejection = ImportAlert(rejected: url, reason: reason)
        case .failed(let message): rejection = ImportAlert(failed: url, message: message)
        }
    }
}

/// The alert for an Import that didn't happen.
private struct ImportAlert {
    let title: String
    let message: String

    init(rejected url: URL, reason: ImportRejection) {
        let name = url.lastPathComponent
        switch reason {
        case .notPDF:
            title = "Not a PDF"
            message = "“\(name)” isn't a PDF."
        case .unreadable:
            title = "Couldn't read PDF"
            message = "“\(name)” can't be opened. The file may be damaged."
        case .locked:
            title = "Password-protected"
            message = "Password-protected PDFs aren't supported yet."
        }
    }

    init(failed url: URL, message: String) {
        title = "Couldn't import “\(url.lastPathComponent)”"
        self.message = message
    }
}
