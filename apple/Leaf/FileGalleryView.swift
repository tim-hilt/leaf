import SwiftUI
import UniformTypeIdentifiers

/// The Library as a vertically scrolling grid of Documents in the order chosen
/// in the toolbar's sort menu, led by a "+" cell that Imports. The window's own
/// search field (⌘F on Mac and iPad) narrows it to matching Documents; with
/// none, "No Results" follows the "+" cell. A click or tap opens a Document in the
/// Reader, one at a time; it reopens after relaunch. The "+" cell and File > Import… (also from the Reader)
/// Import PDFs and EPUBs, as do Files dropped onto the Gallery or handed over by other apps
/// (share sheet, Open With, Dock icon). The first Document of the Files
/// opens; a single File already in the Library is reported
/// for "+" and drops. A cell's context menu
/// (long-press, right-click) or VoiceOver action offers "Remove", after
/// confirmation. A thin bar at the bottom shows "Syncing N of M Documents"
/// while Files transfer, and a toolbar icon shows how Sync stands while Connected
/// (see `SyncStatusButton`). A Document
/// that gets Removed (here or on another Device) closes its Reader, without a message.
///
/// With a keyboard (Mac, iPad), arrow keys move a highlight through the grid,
/// including the "+" cell; nothing is highlighted until the first press.
/// Return opens the highlighted cell, ⌘⌫ asks to Remove it, and ↓ in the
/// search field highlights the first match. Coming back from the Reader
/// highlights the Document read, if a highlight was in use.
struct FileGalleryView: View {
    @Environment(LibraryModel.self) private var library
    /// The Document in the Reader; nil while the Gallery shows.
    @SceneStorage("openDocument") private var openID: String?
    @State private var isImporting = false
    @State private var isDropTargeted = false
    @State private var isShowingSettings = false
    @State private var rejection: ImportAlert?
    /// Files handed over by other apps that haven't been passed on to the Library yet.
    @State private var incoming: [URL] = []
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

    @ToolbarContentBuilder private var galleryToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) { LeafLogo() }.sharedBackgroundVisibility(.hidden)
        ToolbarItemGroup {
            if let indicator = library.syncIndicator {
                SyncStatusButton(indicator: indicator, isShowingSettings: $isShowingSettings)
            }
            SortMenu(sort: Bindable(library).sort)
            #if os(iOS)
                Button("Settings", systemImage: "gear") { isShowingSettings = true }
            #endif
        }
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView { grid }
                    // Only the Gallery takes drops, not the Reader on top of it.
                    .onDrop(
                        of: isShowingReader ? [] : ImportableTypes.all, isTargeted: $isDropTargeted, perform: drop
                    )
                    .overlay {
                        if isDropTargeted { Rectangle().strokeBorder(.tint, lineWidth: 4).allowsHitTesting(false) }
                    }
                    .onGeometryChange(for: Int.self) {
                        Layout.columnCount(forWidth: $0.size.width)
                    } action: {
                        columnCount = $0
                    }
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
            .navigationTitle("Leaf")
            .navigationDestination(isPresented: showsReader) {
                // A new Reader per Document, so that nothing of the previous one carries over.
                if let document = openDocument { ReaderView(document: document).id(document.id) }
            }
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { galleryToolbar }
            // The logo stands in for the title, which still names the back button.
            .toolbar(removing: .title)
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
        .onChange(of: openID) { closed, opened in
            guard opened == nil else { return }
            if highlighted != nil, let closed { highlighted = .document(closed) }
            isGridFocused = true
        }
        .onChange(of: library.documents) { if openDocument == nil { openID = nil } }
        .disabled(library.runningImport != nil)
        .focusedSceneValue(\.isImporting, library.runningImport == nil ? $isImporting : nil)
        .overlay {
            if let running = library.runningImport { ImportProgressModal(running: running) }
        }
        .fileImporter(
            isPresented: $isImporting, allowedContentTypes: ImportableTypes.all, allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result { Task { await importFiles(urls, from: .picker) } }
        }
        // Files other apps hand over: the share sheet, Open With, the Dock icon.
        // The system calls this once per File; Files arriving together are one batch.
        .onOpenURL { url in
            closeSheetsAndPopovers()
            incoming.append(url)
            guard incoming.count == 1 else { return }
            Task {
                try? await Task.sleep(for: .milliseconds(100))
                let urls = incoming
                incoming = []
                await importFiles(urls, from: .openWithOrShare)
            }
        }
        .modifier(GalleryAlerts(openID: $openID, rejection: $rejection, duplicate: $duplicate, removal: $removal))
    }

    /// The cells, "+" first, and "No Results" when a search matches no Document.
    private var grid: some View {
        let visibleDocuments = visibleDocuments
        return VStack(alignment: .leading, spacing: Layout.spacing) {
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(), spacing: Layout.spacing, alignment: .top), count: columnCount),
                spacing: Layout.spacing
            ) {
                Button {
                    open(.importCell)
                } label: {
                    ImportCell()
                }
                .galleryHighlight(highlighted == .importCell)
                .id(GalleryItem.importCell)
                .accessibilityLabel("Import…")
                ForEach(visibleDocuments) { document in
                    Button {
                        open(.document(document.id))
                    } label: {
                        DocumentCell(document: document)
                    }
                    .galleryHighlight(highlighted == .document(document.id))
                    .id(GalleryItem.document(document.id))
                    .contextMenu {
                        DocumentInfoMenuItems(info: DocumentInfo(document))
                        Divider()
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

    /// Opens the Reader on a Document, or starts an Import for the "+" cell.
    private func open(_ item: GalleryItem) {
        switch item {
        case .importCell: isImporting = true
        case .document(let id): openID = id
        }
    }

    /// The Document in the Reader; nil while the Gallery shows.
    private var openDocument: LibraryDocument? {
        library.documents.first { $0.id == openID }
    }

    private var isShowingReader: Bool { openDocument != nil }

    /// Whether the Reader is pushed; the back chevron and edge swipe Go to Gallery.
    private var showsReader: Binding<Bool> {
        Binding(get: { isShowingReader }, set: { if !$0 { openID = nil } })
    }

    /// Moves the highlight; from the search field, ↓ highlights the first
    /// match and hands the keyboard to the grid. False if the key isn't ours.
    private func handleArrow(_ arrow: GridHighlight.Arrow) -> Bool {
        guard !isShowingReader else { return false }
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
        guard !isShowingReader, !isSearchFocused, let highlighted else { return false }
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
    private func closeSheetsAndPopovers() {
        isShowingSettings = false
        isImporting = false
        removal = nil
        duplicate = nil
        rejection = nil
    }

    /// Imports the PDFs and EPUBs among the dropped `providers`. False if there are none.
    private func drop(_ providers: [NSItemProvider]) -> Bool {
        guard DroppedFiles.accepts(providers) else { return false }
        Task {
            let dropped = DroppedFiles()
            let urls = await dropped.receive(providers)
            if !urls.isEmpty {
                closeSheetsAndPopovers()
                await importFiles(urls, from: .drop)
            }
            dropped.removeCopies()
        }
        return true
    }

    private func importFiles(_ urls: [URL], from origin: ImportOrigin) async {
        let result = await library.importFiles(urls, from: origin)
        switch result {
        case .open(let document, let problems):
            openID = document.id
            rejection = ImportAlert(problems)
        case .alreadyInLibrary(let document): duplicate = document
        case .problems(let problems):
            openID = nil
            rejection = ImportAlert(problems)
        }
    }
}

/// The Gallery's alerts, each shown while its item is set: an Import that
/// didn't happen, a File already in the Library (offering to open it), and
/// the confirmation to Remove a Document.
/// The wordmark; a template image, so it follows the light and dark theme.
private struct LeafLogo: View {
    var body: some View {
        Image("LeafLogo").resizable().scaledToFit().frame(height: 18).accessibilityLabel("Leaf")
    }
}

private struct GalleryAlerts: ViewModifier {
    @Environment(LibraryModel.self) private var library
    @Binding var openID: String?
    @Binding var rejection: ImportAlert?
    @Binding var duplicate: LibraryDocument?
    @Binding var removal: LibraryDocument?

    func body(content: Content) -> some View {
        content
            .alert(rejection?.title ?? "", isPresented: Binding(isPresenting: $rejection), presenting: rejection) {
                _ in
            } message: { alert in
                Text(alert.message)
            }
            .confirmationDialog(
                "Remove “\(removal?.title ?? "")”?", isPresented: Binding(isPresenting: $removal),
                titleVisibility: .visible, presenting: removal
            ) { document in
                Button("Remove", role: .destructive) { library.remove(document) }
            } message: { _ in
                Text("The file, its markup and your reading progress are deleted on all your devices.")
            }
            .alert("Already in your Library", isPresented: Binding(isPresenting: $duplicate), presenting: duplicate) {
                existing in
                Button("Open") { openID = existing.id }
                Button("Cancel", role: .cancel) {}
            } message: { existing in
                Text("“\(existing.title)” is already in your Library, so nothing was copied.")
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

    /// The alert for the problems of Files Imported; nil if there are none.
    /// Several are listed in one alert, each with its reason.
    init?(_ problems: [ImportProblem]) {
        guard let problem = problems.first else { return nil }
        guard problems.count > 1 else {
            switch problem.failure {
            case .rejected(let reason): self.init(rejected: problem.file, reason: reason)
            case .failed(let message): self.init(failed: problem.file, message: message)
            }
            return
        }
        self.init(
            title: "Couldn't import \(problems.count) files",
            message: problems.map { "“\($0.file.lastPathComponent)”: \($0.failure.reason)" }.joined(separator: "\n"))
    }

    private init(title: String, message: String) {
        self.title = title
        self.message = message
    }

    private init(rejected url: URL, reason: ImportRejection) {
        let name = url.lastPathComponent
        switch reason {
        case .notPDF:
            title = "Not a PDF or EPUB"
            message = "“\(name)” isn't a PDF or an EPUB."
        case .unreadable:
            title = "Couldn't read PDF"
            message = "“\(name)” can't be opened. The file may be damaged."
        case .locked:
            title = "Password-protected"
            message = "Password-protected PDFs aren't supported yet."
        case .invalidEPUB:
            title = "Couldn't read EPUB"
            message = "“\(name)” isn't a valid EPUB."
        case .drmProtectedEPUB:
            title = "DRM-protected"
            message = "This EPUB is DRM-protected."
        case .fixedLayoutEPUB:
            title = "Fixed-layout EPUB"
            message = "“\(name)” has a fixed layout, which isn't supported."
        }
    }

    private init(failed url: URL, message: String) {
        title = "Couldn't import “\(url.lastPathComponent)”"
        self.message = message
    }
}

extension ImportProblem.Failure {
    /// Why the File wasn't Imported, for a list.
    fileprivate var reason: String {
        switch self {
        case .rejected(.notPDF): "Not a PDF or EPUB."
        case .rejected(.unreadable): "Can't be opened. The file may be damaged."
        case .rejected(.locked): "Password-protected PDFs aren't supported yet."
        case .rejected(.invalidEPUB): "Isn't a valid EPUB."
        case .rejected(.drmProtectedEPUB): "This EPUB is DRM-protected."
        case .rejected(.fixedLayoutEPUB): "Fixed-layout EPUBs aren't supported."
        case .failed(let message): message
        }
    }
}

/// The toolbar icon showing how Sync stands: spinning arrows while syncing, a
/// green check once synced, a red cross after an error, a yellow warning without
/// a network. A click or tap opens a popover saying when Sync last succeeded, or
/// offering to try again. While Sync
/// is blocked (access lost, full, update needed) trying again can't help, so it
/// names the reason and opens Settings instead.
struct SyncStatusButton: View {
    @Environment(LibraryModel.self) private var library
    let indicator: SyncIndicator
    @Binding var isShowingSettings: Bool

    /// The glyph cut out of a filled sync icon: white in light mode, black in dark
    /// mode. An explicit dynamic color, since `.background` resolves against the
    /// toolbar and can end up matching the fill.
    #if os(iOS)
        static let glyphColor = Color(
            uiColor: UIColor { traits in
                traits.userInterfaceStyle == .dark ? .black : .white
            })
    #else
        static let glyphColor = Color(
            nsColor: NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .black : .white
            })
    #endif

    @State private var isShowingPopover = false

    var body: some View {
        Button {
            isShowingPopover = true
        } label: {
            icon
        }
        .accessibilityLabel("Sync Status")
        .accessibilityValue(indicator.message)
        .popover(isPresented: $isShowingPopover) { popover.padding().presentationCompactAdaptation(.popover) }
    }

    @ViewBuilder private var icon: some View {
        switch indicator {
        case .syncing:
            Image(systemName: "arrow.triangle.2.circlepath")
                .symbolEffect(.rotate, options: .repeat(.continuous))
        case .synced:
            Image(systemName: "checkmark.circle.fill").symbolRenderingMode(.palette)
                .foregroundStyle(Self.glyphColor, .green)
        case .failed:
            Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette)
                .foregroundStyle(Self.glyphColor, .red)
        case .noConnection:
            Image(systemName: "exclamationmark.triangle.fill").symbolRenderingMode(.palette)
                .foregroundStyle(Self.glyphColor, .yellow)
        }
    }

    @ViewBuilder private var popover: some View {
        switch indicator {
        case .syncing, .synced: Text(indicator.message)
        // Wrapped: on one line the popover would be too wide.
        case .noConnection: Text(indicator.message).frame(width: 240, alignment: .leading)
        case .failed(let canRetry):
            VStack(alignment: .leading, spacing: 8) {
                Text(indicator.message)
                if canRetry {
                    Button("Try Again") {
                        isShowingPopover = false
                        library.foreground()
                    }
                } else {
                    if let provider = library.connection?.provider {
                        Text(library.syncState.line(for: provider)).font(.caption).foregroundStyle(.secondary)
                    }
                    settingsButton
                }
            }
        }
    }

    @ViewBuilder private var settingsButton: some View {
        #if os(iOS)
            Button("Open Settings") {
                isShowingPopover = false
                isShowingSettings = true
            }
        #else
            SettingsLink { Text("Open Settings") }
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
