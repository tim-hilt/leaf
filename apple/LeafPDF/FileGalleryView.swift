import SwiftUI
import UniformTypeIdentifiers

/// The Library as a vertically scrolling grid of Documents in the order chosen
/// in the toolbar's sort menu, led by a "+" cell that Imports. The search field
/// (⌘F on Mac and iPad) narrows it to matching Documents; with none, "No
/// Results" follows the "+" cell. A click or tap opens a Document in the
/// Reader. The toolbar "+" and File > Import… (also from the Reader) Import a
/// PDF and open it, replacing any open Document. A cell's context menu
/// (long-press, right-click) or VoiceOver action offers "Remove", after
/// confirmation. A window reading a Document that gets Removed (here or in
/// another window) returns to the grid and says so.
///
/// With a keyboard (Mac, iPad), arrow keys move a highlight through the grid,
/// including the "+" cell; nothing is highlighted until the first press.
/// Return opens the highlighted cell, ⌘⌫ asks to Remove it, and ↓ in the
/// search field highlights the first match. Coming back from the Reader
/// highlights its Document, if a highlight was in use.
struct FileGalleryView: View {
    @Environment(LibraryModel.self) private var library
    @State private var path: [LibraryDocument] = []
    @State private var isImporting = false
    @State private var rejection: ImportAlert?
    @State private var duplicate: LibraryDocument?
    @State private var removal: LibraryDocument?
    @State private var removedWhileOpen: LibraryDocument?
    @State private var scroll = ScrollActivity()
    @State private var columnCount = 2
    /// The keyboard highlight; nil until the first arrow press.
    @State private var highlighted: GalleryItem?
    @FocusState private var isGridFocused: Bool
    @FocusState private var isSearchFocused: Bool

    /// Every cell in grid order.
    private var items: [GalleryItem] { [.importCell] + library.visibleDocuments.map { .document($0.id) } }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: Layout.spacing) {
                        LazyVGrid(
                            columns: Array(repeating: GridItem(.flexible(), spacing: Layout.spacing, alignment: .top), count: columnCount),
                            spacing: Layout.spacing
                        ) {
                            Button { open(.importCell) } label: { ImportCell() }
                                .galleryHighlight(highlighted == .importCell)
                                .id(GalleryItem.importCell)
                                .accessibilityLabel("Import…")
                            ForEach(library.visibleDocuments) { document in
                                Button { open(.document(document.id)) } label: { DocumentCell(document: document) }
                                    .galleryHighlight(highlighted == .document(document.id))
                                    .id(GalleryItem.document(document.id))
                                    .contextMenu {
                                        Button("Remove", systemImage: "trash", role: .destructive) { removal = document }
                                    }
                                    .accessibilityLabel(document.title)
                                    .accessibilityAction(named: "Remove") { removal = document }
                            }
                        }
                        .buttonStyle(.plain)
                        // Animates a Document to its new place when the order changes.
                        .animation(.default, value: library.visibleDocuments.map(\.id))
                        if library.visibleDocuments.isEmpty && !library.searchText.isEmpty {
                            Text("No Results for “\(library.searchText)”").foregroundStyle(.secondary)
                        }
                    }
                    .padding(Layout.spacing)
                }
                .onGeometryChange(for: Int.self) { Layout.columnCount(forWidth: $0.size.width) } action: { columnCount = $0 }
                .focusable()
                .focused($isGridFocused)
                .focusEffectDisabled()
                .onAppear { isGridFocused = true }
                .onChange(of: highlighted) { _, item in
                    if let item { proxy.scrollTo(item) }
                }
            }
            .onScrollPhaseChange { _, phase in scroll.scrollingChanged(isScrolling: phase != .idle) }
            .environment(scroll)
            .searchable(text: Bindable(library).searchText)
            .searchFocused($isSearchFocused)
            .navigationTitle("LeafPDF")
            .navigationDestination(for: LibraryDocument.self) { ReaderView(document: $0) }
            .toolbar {
                SortMenu(sort: Bindable(library).sort)
                Button("Import…", systemImage: "plus") { isImporting = true }
            }
        }
        .onKeyPress(phases: [.down, .repeat]) { press in
            guard let arrow = GridHighlight.Arrow(press.key) else { return .ignored }
            return handleArrow(arrow) ? .handled : .ignored
        }
        .onKeyPress(keys: [.return, .delete], phases: .down) { press in
            handleAction(press) ? .handled : .ignored
        }
        .onChange(of: path) { _, path in
            if let reading = path.last {
                if highlighted != nil { highlighted = .document(reading.id) }
            } else {
                isGridFocused = true
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

    /// Opens the Reader on a Document, or starts an Import for the "+" cell.
    private func open(_ item: GalleryItem) {
        switch item {
        case .importCell: isImporting = true
        case .document(let id):
            if let document = library.visibleDocuments.first(where: { $0.id == id }) { path.append(document) }
        }
    }

    /// Moves the highlight; from the search field, ↓ highlights the first
    /// match and hands the keyboard to the grid. False if the key isn't ours.
    private func handleArrow(_ arrow: GridHighlight.Arrow) -> Bool {
        guard path.isEmpty else { return false }
        if isSearchFocused {
            guard arrow == .down, let first = library.visibleDocuments.first else { return false }
            highlighted = .document(first.id)
            isGridFocused = true
            return true
        }
        let grid = GridHighlight(columns: columnCount, cellCount: items.count)
        let current = highlighted.flatMap(items.firstIndex(of:))
        highlighted = items[grid.moved(from: current, arrow)]
        return true
    }

    /// Return opens the highlighted cell; ⌘⌫ asks to Remove its Document.
    private func handleAction(_ press: KeyPress) -> Bool {
        guard path.isEmpty, !isSearchFocused, let highlighted else { return false }
        switch press.key {
        case .return:
            open(highlighted)
        case .delete where press.modifiers == .command:
            guard case .document(let id) = highlighted else { return false }
            removal = library.visibleDocuments.first { $0.id == id }
        default:
            return false
        }
        return true
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

/// A cell of the grid: the "+" cell, or a Document's.
private enum GalleryItem: Hashable {
    case importCell
    case document(String)
}

extension GridHighlight.Arrow {
    fileprivate init?(_ key: KeyEquivalent) {
        switch key {
        case .upArrow: self = .up
        case .downArrow: self = .down
        case .leftArrow: self = .left
        case .rightArrow: self = .right
        default: return nil
        }
    }
}

/// The grid's measurements. Cells are at least `minimumCellWidth` wide, and
/// the columns that fit are counted here because arrow keys need the count.
private enum Layout {
    static let spacing: CGFloat = 16
    static let minimumCellWidth: CGFloat = 140

    static func columnCount(forWidth width: CGFloat) -> Int {
        let usable = width - 2 * spacing
        return max(1, Int((usable + spacing) / (minimumCellWidth + spacing)))
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

/// The toolbar menu choosing how the Gallery is sorted, like the one in Files.
private struct SortMenu: View {
    @Binding var sort: LibrarySort

    var body: some View {
        Menu("Sort", systemImage: "arrow.up.arrow.down") {
            Picker("Sort By", selection: $sort.key) {
                Text("Date Imported").tag(LibrarySort.Key.dateImported)
                Text("Title").tag(LibrarySort.Key.title)
            }
            Toggle("Reverse Order", isOn: $sort.isReversed)
        }
    }
}
