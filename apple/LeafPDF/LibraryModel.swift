import LeafCore
import Observation
import PDFKit

/// A Document in the Library. Holds no open PDF: the Reader opens `file`.
/// Equal only with equal details, so views showing a stale copy update when the
/// Title arrives; compare `id`s to tell whether two values are the same Document.
struct LibraryDocument: Identifiable, Hashable {
    let id: String
    /// The stored File.
    let file: URL
    /// Read from the PDF at Import or by the Library's background pass; nil until then.
    fileprivate(set) var details: DocumentDetails?
    /// Where the user left off; nil if the Document was never opened.
    fileprivate(set) var progress: ReadingProgress?

    /// The name the File had when it was Imported.
    var fileName: String { file.lastPathComponent }
    /// The saved Title, or the file name without extension until it is read.
    var title: String { details?.title ?? file.deletingPathExtension().lastPathComponent }
    var author: String? { details?.author }
    /// Where the user left off, to reopen the Document there.
    var place: Place? {
        progress.map { Place(pageIndex: Int($0.pageIndex), point: CGPoint(x: $0.x, y: $0.y)) }
    }
    /// When the Reader last showed the Document; nil if never.
    var lastRead: Date? { progress.map { Date(timeIntervalSince1970: Double($0.lastRead) / 1000) } }
    /// Nil until read from the PDF.
    var pageCount: Int? { details?.pageCount }
    /// How far the user has got, in whole percent rounded down, counting the
    /// page they are on: 100 only on the last page. Nil if the Document was
    /// never opened or its page count isn't known yet.
    var percentRead: Int? {
        guard let progress, let pageCount, pageCount > 0 else { return nil }
        return min(100, 100 * (Int(progress.pageIndex) + 1) / pageCount)
    }

    fileprivate init(_ stored: LeafCore.Document, details: DocumentDetails?) {
        id = stored.id
        file = URL(fileURLWithPath: stored.path)
        self.details = details
        progress = stored.progress
    }
}

/// Why a File isn't Imported at all; nothing was copied.
enum ImportRejection: Error {
    /// Not a PDF.
    case notPDF
    /// Looks like a PDF, but PDFKit can't open it.
    case unreadable
    /// Needs a password to open. PDFs that only restrict permissions aren't locked.
    case locked
}

/// How an Import ended.
enum ImportOutcome {
    /// The File is now a new Document in the Library.
    case opened(LibraryDocument)
    /// The Library already holds this File's content: the existing Document.
    case duplicate(LibraryDocument)
    case rejected(ImportRejection)
    /// Copying failed; the system's reason. Nothing was left behind.
    case failed(String)
}

/// An Import in progress: what the progress modal shows.
struct RunningImport: Equatable {
    /// The file name until PDFKit has read the File, then its Title.
    fileprivate(set) var title: String
    /// Share of the File copied, 0...1.
    fileprivate(set) var fraction: Double = 0
}

/// Forwards the core's progress, reported on the Import's thread, to the main actor.
private final class ProgressRelay: ImportProgress {
    private let update: @Sendable @MainActor (Double) -> Void

    init(_ update: @escaping @Sendable @MainActor (Double) -> Void) { self.update = update }

    func report(copied: UInt64, total: UInt64) {
        let fraction = total == 0 ? 1 : Double(copied) / Double(total)
        Task { @MainActor [update] in update(fraction) }
    }
}

/// The Library as the clients see it: the core's Library folder plus its
/// Documents, each with its saved Title and Author. One per app, shared by all
/// windows.
@MainActor @Observable
final class LibraryModel {
    /// Every Document, newest Import first.
    private(set) var documents: [LibraryDocument] = [] { didSet { reorder() } }
    /// How the Gallery orders its Documents. Remembered on this device (user
    /// defaults, not synced) and shared by all windows; setting it re-orders at once.
    var sort: LibrarySort {
        didSet {
            guard sort != oldValue else { return }
            sort.save(to: defaults)
            reorder()
        }
    }
    /// `documents` in `sort` order, kept up to date as Titles arrive.
    private var sorted: [LibraryDocument] = []
    /// The Highlight Colors to choose from: the built-in ones, yellow first, then
    /// the Custom Colors in the order added. Kept in the Library's Preferences.
    private(set) var highlightColors: [HighlightColor]
    /// The color of new Highlights; one of `highlightColors`. Yellow until chosen,
    /// kept in the Library's Preferences. Setting it shows at once, in every window.
    private(set) var defaultHighlightColor: HighlightColor
    /// Non-nil from the start of an Import until it finishes. The UI is
    /// disabled meanwhile.
    private(set) var runningImport: RunningImport?
    @ObservationIgnored private let core: LeafCore.Library
    @ObservationIgnored private let saved: DetailsStore
    @ObservationIgnored private let covers: CoverStore
    @ObservationIgnored private let defaults: UserDefaults
    /// The latest access to a Document's state in the core; the next one waits for it.
    @ObservationIgnored private var lastStateAccess: Task<Void, Never>?

    /// Opens the Library folder at `root`, creating it if needed, with Titles
    /// and Authors saved in `detailsFile`, Covers in `coversFolder` and the sort
    /// choice in `defaults`. Documents without saved details are
    /// listed by file name; a low-priority background pass then reads them
    /// from the PDFs, one at a time.
    init(root: URL, detailsFile: URL, coversFolder: URL, defaults: UserDefaults) throws {
        core = try LeafCore.Library.open(root: root.path)
        saved = DetailsStore(file: detailsFile)
        covers = CoverStore(folder: coversFolder)
        self.defaults = defaults
        sort = LibrarySort(from: defaults)
        highlightColors = core.highlightColors().map(HighlightColor.init)
        defaultHighlightColor = HighlightColor(core.defaultHighlightColor())
        refresh()
        readMissingDetails()
    }

    /// The Library in a hidden folder in Application Support, with Covers in
    /// the system Caches folder.
    static func inApplicationSupport() throws -> LibraryModel {
        let files = FileManager.default
        let support = try files.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let caches = try files.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return try LibraryModel(
            root: support.appending(path: "Library", directoryHint: .isDirectory),
            detailsFile: support.appending(path: "Details.json"),
            coversFolder: caches.appending(path: "Covers", directoryHint: .isDirectory),
            defaults: .standard)
    }

    /// The Documents a Gallery shows for Library Search `searchText`: those
    /// whose Title, original file name or Author contains it, ignoring case
    /// and accents, in `sort` order. Blank `searchText` matches every Document.
    /// A Document moves to its place (or into the results) when its Title and
    /// Author arrive.
    func visibleDocuments(matching searchText: String) -> [LibraryDocument] {
        let text = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return sorted }
        return sorted.filter { document in
            [document.title, document.fileName, document.author ?? ""].contains { $0.localizedStandardContains(text) }
        }
    }

    /// The saved Cover of `document`, loaded and decoded off the main thread,
    /// or nil if there is none. Cheap, so safe to call while scrolling; never renders.
    func savedCover(for document: LibraryDocument) async -> CGImage? {
        let covers = covers, id = document.id
        return await Task.detached { covers.saved(id) }.value
    }

    /// The Cover of `document`: the saved one, or page 1 rendered off the main
    /// thread and saved. Nil if it can't be rendered; the Gallery then keeps
    /// the placeholder. Cancelling the caller drops a request whose rendering
    /// hasn't started yet, so cells that scrolled away don't hold up the others.
    func cover(for document: LibraryDocument) async -> CGImage? {
        guard !Task.isCancelled else { return nil }
        let covers = covers, id = document.id, file = document.file
        let loading = Task.detached(priority: .utility) { Task.isCancelled ? nil : covers.cover(id: id, file: file) }
        return await withTaskCancellationHandler { await loading.value } onCancel: { loading.cancel() }
    }

    /// Copies the File at `url` into the Library without blocking the main
    /// thread, publishing `runningImport` meanwhile. Files that aren't
    /// readable, unlocked PDFs are rejected before anything is copied. The
    /// Document's Title, Author and Cover are saved before this returns.
    func `import`(_ url: URL) async -> ImportOutcome {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        // Disable the UI before PDFKit reads the File: that alone can take a while.
        runningImport = RunningImport(title: url.deletingPathExtension().lastPathComponent)
        defer { runningImport = nil }

        let read: ReadPDF?
        let covers = covers
        switch await Task.detached(operation: { Self.check(url, covers: covers) }).value {
        case .failure(let rejection): return .rejected(rejection)
        case .success(let details): read = details
        }
        if let read { runningImport?.title = read.details.title }

        let core = core, path = url.path
        // Reports arriving after the Import finished find no runningImport and do nothing.
        let relay = ProgressRelay { [weak self] fraction in
            guard let running = self?.runningImport else { return }
            self?.runningImport?.fraction = max(running.fraction, fraction)
        }
        do {
            let result = try await Task.detached { try core.import(source: path, progress: relay) }.value
            let (stored, isNew) =
                switch result {
                case .imported(let stored): (stored, true)
                case .alreadyImported(let stored): (stored, false)
                }
            if let read {
                if saved[stored.id] == nil { saved[stored.id] = read.details }
                if let cover = read.cover { covers.save(cover, id: stored.id) }
            }
            refresh()
            guard let document = documents.first(where: { $0.id == stored.id }) else {
                return .failed("The imported file couldn't be opened.")
            }
            return isNew ? .opened(document) : .duplicate(document)
        } catch LibraryError.Failed(let message) {
            return .failed(message)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Deletes the Document, its File and its saved Title, Author and Cover. If that
    /// fails, the Document stays in `documents`.
    func remove(_ document: LibraryDocument) {
        if (try? core.remove(id: document.id)) != nil {
            saved[document.id] = nil
            covers.remove(document.id)
        }
        refresh()
    }

    /// Saves `place` as Reading Progress of `document`, read `lastRead`. The
    /// Document is updated at once, so every window shows it; the core writes
    /// off the main thread, in order, and this returns when it has. Does
    /// nothing for a Document that was Removed. A failed write is ignored: the
    /// next save replaces it.
    func saveProgress(_ place: Place, of document: LibraryDocument, at lastRead: Date = .now) async {
        guard let index = documents.firstIndex(where: { $0.id == document.id }) else { return }
        let progress = ReadingProgress(
            pageIndex: UInt32(place.pageIndex), x: place.point.x, y: place.point.y,
            lastRead: UInt64(max(0, lastRead.timeIntervalSince1970 * 1000).rounded()))
        documents[index].progress = progress

        let core = core, id = document.id
        await inStateOrder { try? core.saveProgress(id: id, progress: progress) }
    }

    /// The Highlights of `document`, oldest first. Empty if there are none or
    /// the Document was Removed.
    func highlights(of document: LibraryDocument) async -> [Highlight] {
        let core = core, id = document.id
        let markup = await inStateOrder { try? core.markup(id: id) }
        return markup?.highlights.map(Highlight.init) ?? []
    }

    /// Adds a Highlight over `anchor` in the Default Highlight Color to `document`,
    /// `created` now. The core writes off the main thread, in order, and this
    /// returns the stored Highlight when it has. Nil for a Document that was
    /// Removed, or if the write failed.
    func addHighlight(
        _ anchor: HighlightAnchor, to document: LibraryDocument, at created: Date = .now
    ) async -> Highlight? {
        guard documents.contains(where: { $0.id == document.id }) else { return nil }
        let core = core, id = document.id
        let pages = anchor.pages.map { page in
            PageRects(
                pageIndex: UInt32(page.pageIndex),
                rects: page.rects.map { Rect(x: $0.minX, y: $0.minY, width: $0.width, height: $0.height) })
        }
        let rgb = Rgb(defaultHighlightColor.color)
        let milliseconds = UInt64(max(0, created.timeIntervalSince1970 * 1000).rounded())
        let stored = await inStateOrder {
            try? core.addHighlight(
                id: id, anchor: pages, quotedText: anchor.quotedText, color: rgb, created: milliseconds)
        }
        // Removed meanwhile: the core stored nothing.
        guard documents.contains(where: { $0.id == id }) else { return nil }
        return stored.map(Highlight.init)
    }

    /// Sets the color of `highlight` of `document`. The core writes off the
    /// main thread, in order, and this returns when it has. Does nothing for a
    /// Document that was Removed.
    func setHighlightColor(_ color: RGB, of highlight: Highlight, in document: LibraryDocument) async {
        guard documents.contains(where: { $0.id == document.id }) else { return }
        let core = core, id = document.id, highlightID = highlight.id
        let rgb = Rgb(color)
        await inStateOrder { try? core.setHighlightColor(id: id, highlight: highlightID, color: rgb) }
    }

    /// Sets the Note of `highlight` of `document` to `note`; empty removes it. The
    /// core writes off the main thread, in order, and this returns when it has.
    /// Does nothing for a Document that was Removed.
    func setNote(_ note: String, of highlight: Highlight, in document: LibraryDocument) async {
        guard documents.contains(where: { $0.id == document.id }) else { return }
        let core = core, id = document.id, highlightID = highlight.id
        await inStateOrder { try? core.setHighlightNote(id: id, highlight: highlightID, note: note) }
    }

    /// Removes `highlight` from `document`. The core writes off the main
    /// thread, in order, and this returns when it has. Does nothing for a
    /// Document that was Removed.
    func removeHighlight(_ highlight: Highlight, from document: LibraryDocument) async {
        guard documents.contains(where: { $0.id == document.id }) else { return }
        let core = core, id = document.id, highlightID = highlight.id
        await inStateOrder { try? core.removeHighlight(id: id, highlight: highlightID) }
    }

    /// Makes `color`, one of `highlightColors`, the Default Highlight Color. It
    /// shows at once; the core writes off the main thread, in order, and this
    /// returns when it has.
    func setDefaultHighlightColor(_ color: HighlightColor) async {
        defaultHighlightColor = color
        let core = core, id = color.id
        await inStateOrder { try? core.setDefaultHighlightColor(id: id) }
    }

    /// Adds `color` as a Custom Color after the others, `added` now. It shows at
    /// once, once the core, which writes off the main thread, in order, has
    /// stored it. Nil if that failed.
    @discardableResult
    func addCustomColor(_ color: RGB, at added: Date = .now) async -> HighlightColor? {
        let core = core, rgb = Rgb(color)
        let milliseconds = UInt64(max(0, added.timeIntervalSince1970 * 1000).rounded())
        guard let stored = await inStateOrder({ try? core.addCustomColor(rgb: rgb, added: milliseconds) })
        else { return nil }
        let custom = HighlightColor(stored)
        highlightColors.append(custom)
        return custom
    }

    /// Removes the Custom Color `color`. It goes at once; Highlights keep their
    /// color, and if it was the Default Highlight Color, yellow is again. Does
    /// nothing for a built-in color. The core writes off the main thread, in
    /// order, and this returns when it has.
    func removeCustomColor(_ color: HighlightColor) async {
        guard color.isCustom else { return }
        highlightColors.removeAll { $0 == color }
        if defaultHighlightColor == color { defaultHighlightColor = highlightColors[0] }
        let core = core, id = color.id
        await inStateOrder { try? core.removeCustomColor(id: id) }
    }

    /// Runs `access` off the main thread, after every earlier access to the
    /// core's state (a Document's or the Preferences) has finished, so reads
    /// and writes never overlap.
    private func inStateOrder<T: Sendable>(_ access: @escaping @Sendable () -> T) async -> T {
        let previous = lastStateAccess
        let running = Task.detached {
            await previous?.value
            return access()
        }
        lastStateAccess = Task { _ = await running.value }
        return await running.value
    }

    /// What Import reads from the PDF it opened to check the File.
    private struct ReadPDF: Sendable {
        let details: DocumentDetails
        let cover: CGImage?
    }

    /// What the File at `url` yields if it can be Imported, or why not. A File
    /// that can't be read at all isn't rejected (nil): copying it fails with
    /// the system's own reason. Reads the File and renders its Cover, so keep
    /// it off the main thread.
    private nonisolated static func check(_ url: URL, covers: CoverStore) -> Result<ReadPDF?, ImportRejection> {
        if let pdf = PDFDocument(url: url) {
            return pdf.isLocked ? .failure(.locked) : .success(ReadPDF(details: pdf.details, cover: covers.render(pdf)))
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .success(nil) }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 5)) ?? Data()
        return .failure(head == Data("%PDF-".utf8) ? .unreadable : .notPDF)
    }

    private func reorder() { sorted = sort.ordered(documents) }

    /// Reloads `documents` from the core, with their saved details. If the
    /// listing fails, `documents` stays as it was rather than looking as if
    /// everything was Removed.
    private func refresh() {
        guard let stored = try? core.documents() else { return }
        documents = stored.map { LibraryDocument($0, details: saved[$0.id]) }
    }

    /// Reads the details of Documents that have none, or none with a page
    /// count, from their PDFs, one at a time at background priority,
    /// publishing each as it arrives. A PDF that can't be read is skipped and
    /// tried again at the next launch.
    private func readMissingDetails() {
        let missing = documents.filter { $0.pageCount == nil }.map { ($0.id, $0.file) }
        guard !missing.isEmpty else { return }
        Task(priority: .background) { [weak self] in
            for (id, file) in missing {
                let read = await Task.detached(priority: .background) { PDFDocument(url: file)?.details }.value
                guard let self else { return }
                self.publish(read, for: id)
            }
        }
    }

    /// Saves `details` for Document `id` unless it was Removed or already has
    /// a page count, which means complete details.
    private func publish(_ details: DocumentDetails?, for id: String) {
        guard let details, saved[id]?.pageCount == nil, let index = documents.firstIndex(where: { $0.id == id }) else { return }
        saved[id] = details
        documents[index].details = details
    }
}

extension Highlight {
    fileprivate init(_ stored: LeafCore.Highlight) {
        self.init(
            id: stored.id,
            anchor: HighlightAnchor(
                pages: stored.anchor.map { page in
                    .init(
                        pageIndex: Int(page.pageIndex),
                        rects: page.rects.map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) })
                },
                quotedText: stored.quotedText),
            color: RGB(stored.color), note: stored.note)
    }
}

extension Rgb {
    fileprivate init(_ color: RGB) {
        self.init(r: color.r.byte, g: color.g.byte, b: color.b.byte)
    }
}

extension Double {
    /// A color component from 0 to 1 as a byte.
    fileprivate var byte: UInt8 { UInt8((min(max(self, 0), 1) * 255).rounded()) }
}
