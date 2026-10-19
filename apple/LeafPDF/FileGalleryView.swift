import SwiftUI
import UniformTypeIdentifiers

/// The Library as a vertically scrolling grid of Documents in the order chosen
/// in the toolbar's sort menu, led by a "+" cell that Imports. The window's own
/// search field (⌘F on Mac and iPad) narrows it to matching Documents; with
/// none, "No Results" follows the "+" cell. A click or tap opens a Document in the
/// Reader. The toolbar "+" and File > Import… (also from the Reader) Import a
/// PDF and open it, replacing any open Document. A cell's context menu
/// (long-press, right-click) or VoiceOver action offers "Remove", after
/// confirmation. A thin bar at the bottom shows "Syncing N of M Documents"
/// while Files transfer, and a warning in the toolbar opens Settings while Sync is
/// blocked (wrong password, update needed), but not while offline. A window reading a Document that gets Removed (here or in
/// another window or Device) returns to the grid, without a message.
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
    @State private var isShowingSettings = false
    @State private var rejection: ImportAlert?
    @State private var duplicate: LibraryDocument?
    @State private var removal: LibraryDocument?
    @State private var scroll = ScrollActivity()
    @State private var columnCount = 2
    /// The keyboard highlight; nil until the first arrow press.
    @State private var highlighted: GalleryItem?
    @FocusState private var isGridFocused: Bool
    @FocusState private var isSearchFocused: Bool
    /// This window's Library Search; empty when not searching.
    @State private var searchText = ""

    /// The Documents shown, in grid order after the "+" cell.
    private var visibleDocuments: [LibraryDocument] { library.visibleDocuments(matching: searchText) }
    /// Every cell in grid order.
    private var items: [GalleryItem] { [.importCell] + visibleDocuments.map { .document($0.id) } }

    var body: some View {
        let visibleDocuments = visibleDocuments
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
                            ForEach(visibleDocuments) { document in
                                Button { open(.document(document.id)) } label: { DocumentCell(document: document) }
                                    .galleryHighlight(highlighted == .document(document.id))
                                    .id(GalleryItem.document(document.id))
                                    .contextMenu {
                                        Button("Remove", systemImage: "trash", role: .destructive) { removal = document }
                                    }
                                    .accessibilityLabel(document.accessibilityLabel)
                                    .accessibilityAction(named: "Remove") { removal = document }
                            }
                        }
                        .buttonStyle(.plain)
                        // Animates a Document to its new place when the order changes.
                        .animation(.default, value: visibleDocuments.map(\.id))
                        if visibleDocuments.isEmpty && !searchText.isEmpty {
                            Text("No Results for “\(searchText)”").foregroundStyle(.secondary)
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
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let transfer = library.transfer { TransferBar(transfer: transfer) }
            }
            .animation(.default, value: library.transfer != nil)
            .searchable(text: $searchText)
            .searchFocused($isSearchFocused)
            .navigationTitle("LeafPDF")
            .navigationDestination(for: LibraryDocument.self) { ReaderView(document: $0) }
            .toolbar {
                if library.showsSyncWarning { SyncWarning(isShowingSettings: $isShowingSettings) }
                SortMenu(sort: Bindable(library).sort)
                Button("Import…", systemImage: "plus") { isImporting = true }
                #if os(iOS)
                    Button("Settings", systemImage: "gear") { isShowingSettings = true }
                #endif
            }
            #if os(iOS)
                .sheet(isPresented: $isShowingSettings) { SettingsSheet() }
            #endif
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
        .onChange(of: library.documents) {
            path = library.readers(keeping: path)
        }
        .disabled(library.runningImport != nil)
        .focusedSceneValue(\.isImporting, library.runningImport == nil ? $isImporting : nil)
        .overlay {
            if let running = library.runningImport { ImportProgressModal(running: running) }
        }
        .fileImporter(
            isPresented: $isImporting, allowedContentTypes: [.pdf], allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result { Task { await importFiles(urls, from: .picker) } }
        }
        // Files other apps hand over: the share sheet, Open With, the Dock icon.
        .onOpenURL { url in
            closeSheetsAndPopovers()
            Task { await importFiles([url], from: .openWithOrShare) }
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
            if let document = visibleDocuments.first(where: { $0.id == id }) { path.append(document) }
        }
    }

    /// Moves the highlight; from the search field, ↓ highlights the first
    /// match and hands the keyboard to the grid. False if the key isn't ours.
    private func handleArrow(_ arrow: GridHighlight.Arrow) -> Bool {
        guard path.isEmpty else { return false }
        if isSearchFocused {
            guard arrow == .down, let first = visibleDocuments.first else { return false }
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
            removal = visibleDocuments.first { $0.id == id }
        default:
            return false
        }
        return true
    }

    /// Dismisses whatever covers the Gallery, so that an incoming File's result shows.
    /// An open Reader, with its popovers, is replaced by that result.
    private func closeSheetsAndPopovers() {
        isShowingSettings = false
        isImporting = false
        removal = nil
        duplicate = nil
        rejection = nil
    }

    private func importFiles(_ urls: [URL], from origin: ImportOrigin) async {
        switch await library.importFiles(urls, from: origin) {
        case .openReader(let document): path = [document]
        case .alreadyInLibrary(let document): duplicate = document
        case .problems(let problems): rejection = ImportAlert(problems)
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

    /// The alert for the problem of the one File Imported; nil if there is none.
    init?(_ problems: [ImportProblem]) {
        guard let problem = problems.first else { return nil }
        switch problem.failure {
        case .rejected(let reason): self.init(rejected: problem.file, reason: reason)
        case .failed(let message): self.init(failed: problem.file, message: message)
        }
    }

    private init(rejected url: URL, reason: ImportRejection) {
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

    private init(failed url: URL, message: String) {
        title = "Couldn't import “\(url.lastPathComponent)”"
        self.message = message
    }
}

/// The toolbar's warning, shown only while Sync is blocked, that opens Settings.
private struct SyncWarning: View {
    @Environment(LibraryModel.self) private var library
    @Binding var isShowingSettings: Bool

    var body: some View {
        #if os(iOS)
            Button("Sync Blocked", systemImage: "exclamationmark.triangle") { isShowingSettings = true }
                .help(library.syncState.line())
        #else
            SettingsLink { Label("Sync Blocked", systemImage: "exclamationmark.triangle") }
                .help(library.syncState.line())
        #endif
    }
}

/// A thin bar under the grid, like the one Files shows, while Files transfer.
/// On the Gallery only: the Reader, which is pushed on top, has none.
private struct TransferBar: View {
    let transfer: FileTransfer

    var body: some View {
        VStack(spacing: 4) {
            ProgressView(value: Double(transfer.done), total: Double(transfer.total))
            Text(transfer.text).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, Layout.spacing)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .accessibilityElement(children: .combine)
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
                Text("Recently Read").tag(LibrarySort.Key.recentlyRead)
            }
            Toggle("Reverse Order", isOn: $sort.isReversed)
        }
    }
}
