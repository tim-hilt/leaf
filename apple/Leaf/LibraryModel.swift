import CoreGraphics
import Foundation
import LeafCore
import Observation
import Synchronization

/// A Document in the Library, as the core last listed it. Holds no open PDF:
/// the Reader opens `file`. Equal only with equal details, progress and Date
/// Imported, so views showing a stale copy update when the Title arrives;
/// compare `id`s to tell whether two values are the same Document.
///
/// Title, Author and page count are read from a PDF at Import or by the
/// core's background pass; the core reads an EPUB's at Import.
/// Documents don't change their Format.
struct LibraryDocument: Identifiable, Hashable {
    fileprivate let stored: LeafCore.Document

    var id: String { stored.id }
    /// An EPUB once the core has read it, else a PDF.
    var format: Format { stored.format }
    /// The stored File. Built without asking the file system whether it is a directory.
    var file: URL { URL(fileURLWithPath: stored.path, isDirectory: false) }
    /// The title stored in the File, or else its name without extension.
    var title: String { stored.title }
    /// Nil if the PDF has none, or until it is read.
    var author: String? { stored.author }
    /// Nil for an EPUB, and for a PDF until read.
    var pageCount: Int? { stored.pageCount.map(Int.init) }
    /// How far the user has got, in whole percent rounded down, counting the
    /// page they are on: 100 only on the last page. Nil if the Document was
    /// never opened or its page count isn't known yet.
    var percentRead: Int? { stored.percentRead.map(Int.init) }
    /// Where the user left off; nil if the Document was never opened.
    private var progress: ReadingProgress? { stored.progress }

    /// When the Document was first Imported.
    var imported: Date { Date(milliseconds: stored.imported) }
    /// The name the File had when it was Imported.
    var fileName: String { file.lastPathComponent }
    /// Where the user left off, to reopen the Document there.
    var place: Place? { progress?.place }
    /// When the Reader last showed the Document; nil if never.
    var lastRead: Date? { progress.map { Date(milliseconds: $0.lastRead) } }

    /// A Document with no details, Imported at the Unix epoch.
    init(id: String, file: URL, progress: ReadingProgress? = nil) {
        stored = LeafCore.Document(
            id: id, path: file.path, format: .pdf, imported: 0, progress: progress,
            title: file.deletingPathExtension().lastPathComponent, author: nil, pageCount: nil, percentRead: nil)
    }

    fileprivate init(_ stored: LeafCore.Document) { self.stored = stored }

    /// Where the Cover of this Document comes from.
    fileprivate func coverSource(core: LeafCore.Library) -> CoverSource {
        switch format {
        case .pdf: .pdf(file)
        case .epub:
            .epub(title: title, author: author) { [id] in (try? core.epubCover(id: id)) ?? nil }
        }
    }
}

/// How an Import ended.
enum ImportOutcome {
    /// The File is now a new Document in the Library.
    case opened(LibraryDocument)
    /// The Library already holds this File's content: the existing Document.
    case duplicate(LibraryDocument)
    /// The File isn't Imported, and nothing was left behind: why, as the core says.
    case failed(LibraryError)
}

/// Where Files to Import came from.
enum ImportOrigin {
    /// Another app handed them over: the share sheet, "Open With", the Dock icon.
    case openWithOrShare
    /// Dropped onto the Gallery.
    case drop
    /// Chosen with the Gallery's "+".
    case picker
}

/// A File that wasn't Imported, and why.
struct ImportProblem {
    let file: URL
    let error: LibraryError
}

/// What the window shows after Importing Files.
enum ImportResult {
    /// A single File was Imported: open its Document.
    case open(LibraryDocument, problems: [ImportProblem])
    /// Tell the user this Document already was in the Library, and offer to open it.
    case alreadyInLibrary(LibraryDocument)
    /// Several Files were Imported, or none: nothing opens, the Gallery shows; alert if there are problems.
    case problems([ImportProblem])
}

/// An Import in progress: what the progress modal shows.
struct RunningImport: Equatable {
    /// The file name until PDFKit has read a PDF, then its Title.
    fileprivate(set) var title: String
    /// Share of the File copied, 0...1.
    fileprivate(set) var fraction: Double = 0
}

/// Forwards the core's progress, reported on the Import's thread, to the main actor.
private final class ProgressRelay: ImportProgress {
    private let update: @Sendable @MainActor (Double) -> Void

    init(_ update: @escaping @Sendable @MainActor (Double) -> Void) { self.update = update }

    /// The last whole percent forwarded.
    private let forwarded = Atomic(-1)

    /// Forwards whole percent steps only, not every chunk copied.
    func report(copied: UInt64, total: UInt64) {
        let fraction = total == 0 ? 1 : Double(copied) / Double(total)
        let percent = Int(fraction * 100)
        guard forwarded.exchange(percent, ordering: .relaxed) != percent else { return }
        Task { @MainActor [update] in update(fraction) }
    }
}

extension Date {
    /// The core's time: milliseconds since the Unix epoch.
    init(milliseconds: UInt64) { self.init(timeIntervalSince1970: Double(milliseconds) / 1000) }

    /// This time as the core takes it: whole milliseconds since the Unix epoch, none before.
    var millisecondsSince1970: UInt64 { UInt64(max(0, timeIntervalSince1970 * 1000).rounded()) }
}

/// The Library as the core listed it at one change: the Documents, newest
/// Import first, and the core's `Listing` that orders and searches those same
/// Documents. One core call makes both, so they can't disagree.
private struct LibraryListing: Sendable {
    let documents: [LibraryDocument]
    /// The same Documents by ID.
    let byID: [String: LibraryDocument]
    /// Library Search over `documents`: positions in them, in Sort order.
    let sorted: Listing

    /// Nil if the core can't list the Library.
    init?(_ core: LeafCore.Library, sort: LeafCore.Sort) {
        guard let sorted = try? core.listing(sort: sort) else { return nil }
        self.sorted = sorted
        documents = sorted.documents().map(LibraryDocument.init)
        byID = Dictionary(documents.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }
}

/// The Library as the clients see it: its Documents, Imports, Covers, Markup
/// and Highlight Colors, on the core's Library folder. One per app, shared by
/// all windows. Cloud Backing (`CloudBackingModel`) changes it through `SyncedLibrary`.
@MainActor @Observable
final class LibraryModel {
    /// Every Document, newest Import first.
    var documents: [LibraryDocument] { listing?.documents ?? [] }
    /// How the Gallery orders its Documents. Remembered on this device (user
    /// defaults, not synced) and shared by all windows; setting it re-orders once the
    /// core has the new listing.
    var sort: LibrarySort {
        didSet {
            guard sort != oldValue else { return }
            sort.save(to: defaults)
            Task { await relist { _ in } }
        }
    }
    /// The Library as the core last listed it, in `sort` order: what the Gallery
    /// shows. Nil only if the core couldn't list it.
    private var listing: LibraryListing?
    /// The Highlight Colors to choose from: the built-in ones, yellow first, then
    /// the Custom Colors in the order added. Kept in the Library's Preferences.
    private(set) var highlightColors: [HighlightColor]
    /// The color of new Highlights; one of `highlightColors`. Yellow until chosen,
    /// kept in the Library's Preferences. Setting it shows at once, in every window.
    private(set) var defaultHighlightColor: HighlightColor
    /// Non-nil from the start of an Import until it finishes. The UI is
    /// disabled meanwhile.
    private(set) var runningImport: RunningImport?
    /// How often Sync changed the Markup of each Document that it changed. A
    /// Reader that sees its Document's number change reads the Markup again.
    private var markupRevisions: [String: Int] = [:]
    @ObservationIgnored private let core: LeafCore.Library
    @ObservationIgnored private let coversFolder: URL
    /// Made per use, so new Covers suit the displays in use (see `CoverStore`).
    private var covers: CoverStore { CoverStore(folder: coversFolder) }
    @ObservationIgnored private let defaults: UserDefaults
    /// Where the system hands over temporary copies of Files; they are deleted
    /// after their Import. Nil where the system hands over the Files themselves.
    @ObservationIgnored private let inbox: URL?
    /// The latest `importFiles` call; the next one waits for it.
    @ObservationIgnored private var lastImportFiles: Task<Void, Never>?
    /// The latest access to a Document's state in the core; the next one waits for it.
    @ObservationIgnored private var lastStateAccess: Task<Void, Never>?
    /// Covers decoded lately, by Document ID; the system evicts them as memory gets tight.
    @ObservationIgnored private let decodedCovers = {
        let cache = NSCache<NSString, CGImage>()
        cache.totalCostLimit = 64 << 20
        return cache
    }()

    /// Shows the Library of `core`, with Covers in `coversFolder` and the sort
    /// choice in `defaults`. Documents whose details the core lacks are listed
    /// by file name; the core's background pass then reads them from the PDFs,
    /// one at a time, and tells this model to list again as they arrive. Files
    /// in `inbox` are temporary copies, deleted after `importFiles`.
    init(core: LeafCore.Library, coversFolder: URL, defaults: UserDefaults, inbox: URL? = nil) {
        self.core = core
        self.coversFolder = coversFolder
        self.defaults = defaults
        self.inbox = inbox
        sort = LibrarySort(from: defaults)
        let stored = core.highlightColors()
        highlightColors = stored.colors
        defaultHighlightColor = stored.defaultColor
        // Listed at once, so the Gallery opens in order rather than filling in.
        listing = LibraryListing(core, sort: sort.core)
        // The core reads the details of PDFs that lack them on a background
        // thread; the Gallery lists again as they arrive.
        core.readMissingDetails(
            reader: PDFKitReader(),
            observer: GalleryRelay { [weak self] in
                Task { await self?.relist { _ in } }
            })
    }

    /// How often Sync changed the Markup of `document`; it changes whenever
    /// `markup(of:)` has news.
    func markupRevision(of document: LibraryDocument) -> Int { markupRevisions[document.id, default: 0] }

    /// Reads the Highlight Colors again, after every write to the Preferences
    /// already queued, as Sync may have changed them.
    private func reloadHighlightColors() async {
        let stored = await inStateOrder { $0.highlightColors() }
        let all = stored.colors
        let defaultColor = stored.defaultColor
        if highlightColors != all { highlightColors = all }
        if defaultHighlightColor != defaultColor { defaultHighlightColor = defaultColor }
    }

    /// The Documents a Gallery shows for Library Search `searchText`: those
    /// whose Title, original file name or Author contains it, ignoring case
    /// and accents, in `sort` order. Blank `searchText` matches every Document.
    /// A Document moves to its place (or into the results) when its Title and
    /// Author arrive.
    func visibleDocuments(matching searchText: String) -> [LibraryDocument] {
        guard let listing else { return [] }
        return listing.sorted.matching(search: searchText).map { listing.documents[Int($0)] }
    }

    /// The Document with `id` as the core stores it now, if it is in the Library.
    /// Read here, as a save doesn't list the Library again unless the Gallery shows
    /// something new; the listed copy may lack the latest place.
    func document(id: String) -> LibraryDocument? {
        guard let stored = try? core.document(id: id) else { return nil }
        return LibraryDocument(stored)
    }

    /// The saved Cover of `document`, loaded and decoded off the main thread,
    /// or nil if there is none. Cheap, so safe to call while scrolling; never renders.
    func savedCover(for document: LibraryDocument) async -> CGImage? {
        let covers = covers
        let id = document.id
        if let decoded = decodedCovers.object(forKey: id as NSString) { return decoded }
        return keepDecoded(await Task.detached { covers.saved(id) }.value, id: id)
    }

    /// Keeps `cover` of Document `id` in memory, so cells scrolled back into
    /// view don't decode it again.
    private func keepDecoded(_ cover: CGImage?, id: String) -> CGImage? {
        if let cover { decodedCovers.setObject(cover, forKey: id as NSString, cost: cover.bytesPerRow * cover.height) }
        return cover
    }

    private func removeCover(_ id: String) {
        decodedCovers.removeObject(forKey: id as NSString)
        covers.remove(id)
    }

    /// The Cover of `document`: the saved one, or else made off the main
    /// thread (a PDF's page 1, an EPUB's image) and saved. Nil if it can't be rendered; the Gallery then keeps
    /// the placeholder. Cancelling the caller drops a request whose rendering
    /// hasn't started yet, so cells that scrolled away don't hold up the others.
    func cover(for document: LibraryDocument) async -> CGImage? {
        guard !Task.isCancelled else { return nil }
        let covers = covers
        let id = document.id
        let source = document.coverSource(core: core)
        let loading = Task.detached(priority: .utility) {
            Task.isCancelled ? nil : covers.cover(id: id, source: source)
        }
        let cover = await withTaskCancellationHandler {
            await loading.value
        } onCancel: {
            loading.cancel()
        }
        return keepDecoded(cover, id: id)
    }

    /// Copies the File at `url` into the Library without blocking the main
    /// thread, publishing `runningImport` meanwhile. The core refuses a File it
    /// can't Import, e.g. a PDF that can't be opened, and nothing stays in the
    /// Library. The Document's details and Cover are saved before this returns.
    func `import`(_ url: URL) async -> ImportOutcome {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        // Disable the UI before the core reads the File: that alone can take a while.
        runningImport = RunningImport(title: url.deletingPathExtension().lastPathComponent)
        defer { runningImport = nil }

        let core = core
        let covers = covers
        let path = url.path
        // Reports arriving after the Import finished find no runningImport and do nothing.
        let relay = ProgressRelay { [weak self] fraction in
            guard let running = self?.runningImport else { return }
            self?.runningImport?.fraction = max(running.fraction, fraction)
        }
        do {
            let (stored, isNew) = try await Task.detached {
                let (stored, isNew) =
                    switch try core.import(source: path, reader: PDFKitReader(), progress: relay) {
                    case .imported(let stored): (stored, true)
                    case .alreadyImported(let stored): (stored, false)
                    }
                // The Cover is made from the File in the Library, PDF or EPUB.
                _ = covers.cover(id: stored.id, source: LibraryDocument(stored).coverSource(core: core))
                return (stored, isNew)
            }.value
            let id = stored.id
            // Listed with the Document, so the Gallery shows it too.
            guard let listed = await relist(after: { try? $0.document(id: id) }) else {
                return .failed(.Failed(message: "The imported file couldn't be opened."))
            }
            let document = LibraryDocument(listed)
            runningImport?.title = document.title
            return isNew ? .opened(document) : .duplicate(document)
        } catch let error as LibraryError {
            return .failed(error)
        } catch {
            return .failed(.Failed(message: error.localizedDescription))
        }
    }

    /// Imports `urls`, which came from `origin`, one after another, and says
    /// what the window shows: the Document of a single File, new or already in
    /// the Library, opens; several Files open nothing. Only a single File already
    /// in the Library from "+" or a drop is reported to the user instead. A File that isn't
    /// Imported is a problem. Temporary copies in the Inbox are deleted
    /// afterwards, whatever the outcome. A call made while an Import runs
    /// waits until it has finished.
    func importFiles(_ urls: [URL], from origin: ImportOrigin) async -> ImportResult {
        let previous = lastImportFiles
        let running = Task { @MainActor in
            await previous?.value
            return await importQueued(urls, from: origin)
        }
        lastImportFiles = Task { _ = await running.value }
        return await running.value
    }

    private func importQueued(_ urls: [URL], from origin: ImportOrigin) async -> ImportResult {
        var opening: LibraryDocument?
        var duplicate: LibraryDocument?
        var problems: [ImportProblem] = []
        for url in urls {
            switch await `import`(url) {
            case .opened(let document): opening = document
            case .duplicate(let document):
                opening = document
                duplicate = document
            case .failed(let error): problems.append(ImportProblem(file: url, error: error))
            }
            deleteIfTemporary(url)
        }
        if urls.count == 1, origin != .openWithOrShare, let duplicate { return .alreadyInLibrary(duplicate) }
        guard urls.count == 1, let opening else { return .problems(problems) }
        return .open(opening, problems: problems)
    }

    private func deleteIfTemporary(_ file: URL) {
        guard let inbox, file.resolvingSymlinksInPath().path.hasPrefix(inbox.resolvingSymlinksInPath().path + "/")
        else { return }
        try? FileManager.default.removeItem(at: file)
    }

    /// Deletes the Document, its File, its details and its Cover. If that
    /// fails, the Document stays in `documents`.
    func remove(_ document: LibraryDocument) async {
        let id = document.id
        await relist { try? $0.remove(id: id) }
    }

    /// EPUB `document`, opened for reading off the main thread. Nil for a PDF, and
    /// for an EPUB the core can't read.
    func epub(of document: LibraryDocument) async -> EpubBook? {
        let core = core
        let id = document.id
        return await Task.detached { (try? core.openEpub(id: id)) ?? nil }.value
    }

    /// Saves `place` as Reading Progress of `document`, read `lastRead`. The
    /// core writes off the main thread, in order; this returns when it has. The
    /// Library is listed again only if the core says the Gallery shows something
    /// new. Does nothing for a Document that was Removed. A failed write is
    /// ignored: the next save replaces it.
    func saveProgress(_ place: Place, of document: LibraryDocument, at lastRead: Date = .now) async {
        let progress = ReadingProgress(place: place, lastRead: lastRead.millisecondsSince1970)
        let id = document.id
        let sort = sort.core
        let changes = await inStateOrder { core in
            let changes = try? core.wouldChangeGallery(id: id, progress: progress, sort: sort)
            try? core.saveProgress(id: id, progress: progress)
            return changes ?? true
        }
        if changes { await relist { _ in } }
    }

    /// The Highlights and page Notes of `document`, each oldest first, read at
    /// once. Empty if there are none or the Document was Removed.
    func markup(of document: LibraryDocument) async -> (highlights: [Highlight], pageNotes: [PageNote]) {
        let id = document.id
        let markup = await inStateOrder { try? $0.markup(id: id) }
        return (markup?.highlights ?? [], markup?.pageNotes ?? [])
    }

    /// Adds a Highlight over `anchor` in the Default Highlight Color to `document`,
    /// `created` now. The core writes off the main thread, in order, and this
    /// returns the stored Highlight when it has. Nil for a Document that was
    /// Removed, or if the write failed.
    func addHighlight(
        _ anchor: Anchor, quotedText: String, to document: LibraryDocument, at created: Date = .now
    ) async -> Highlight? {
        let id = document.id
        let rgb = defaultHighlightColor.rgb
        let milliseconds = created.millisecondsSince1970
        return await inStateOrder {
            try? $0.addHighlight(id: id, anchor: anchor, quotedText: quotedText, color: rgb, created: milliseconds)
        }
    }

    /// Sets the color of `highlight` of `document`. The core writes off the
    /// main thread, in order, and this returns when it has. Does nothing for a
    /// Document that was Removed.
    func setHighlightColor(_ color: RGB, of highlight: Highlight, in document: LibraryDocument) async {
        let id = document.id
        let highlightID = highlight.id
        let rgb = Rgb(color)
        await inStateOrder { try? $0.setHighlightColor(id: id, highlight: highlightID, color: rgb) }
    }

    /// Sets the Note of `highlight` of `document` to `note`; empty removes it. The
    /// core writes off the main thread, in order, and this returns when it has.
    /// Does nothing for a Document that was Removed.
    func setNote(_ note: String, of highlight: Highlight, in document: LibraryDocument) async {
        let id = document.id
        let highlightID = highlight.id
        await inStateOrder { try? $0.setHighlightNote(id: id, highlight: highlightID, note: note) }
    }

    /// Removes `highlight` from `document`. The core writes off the main
    /// thread, in order, and this returns when it has. Does nothing for a
    /// Document that was Removed.
    func removeHighlight(_ highlight: Highlight, from document: LibraryDocument) async {
        let id = document.id
        let highlightID = highlight.id
        await inStateOrder { try? $0.removeHighlight(id: id, highlight: highlightID) }
    }

    /// Adds a page Note without text at `place` to `document`, `created` now. The
    /// core writes off the main thread, in order, and this returns the stored
    /// page Note when it has. It isn't listed by `markup(of:)` until it has
    /// text (`setText`). Nil for a Document that was Removed, or if the write failed.
    func addPageNote(at place: Place, to document: LibraryDocument, at created: Date = .now) async -> PageNote? {
        let id = document.id
        let milliseconds = created.millisecondsSince1970
        return await inStateOrder { try? $0.addPageNote(id: id, place: place, created: milliseconds) }
    }

    /// Sets the text of `note` of `document` to `text`; empty removes the page
    /// Note. The core writes off the main thread, in order, and this returns when
    /// it has. Does nothing for a Document that was Removed.
    func setText(_ text: String, of note: PageNote, in document: LibraryDocument) async {
        let id = document.id
        let noteID = note.id
        await inStateOrder { try? $0.setPageNoteText(id: id, note: noteID, text: text) }
    }

    /// Removes the page Note `note` from `document`. The core writes off the main
    /// thread, in order, and this returns when it has. Does nothing for a
    /// Document that was Removed.
    func removePageNote(_ note: PageNote, from document: LibraryDocument) async {
        let id = document.id
        let noteID = note.id
        await inStateOrder { try? $0.removePageNote(id: id, note: noteID) }
    }

    /// Makes `color`, one of `highlightColors`, the Default Highlight Color. It
    /// shows at once; the core writes off the main thread, in order, and this
    /// returns when it has.
    func setDefaultHighlightColor(_ color: HighlightColor) async {
        defaultHighlightColor = color
        let id = color.id
        await inStateOrder { try? $0.setDefaultHighlightColor(id: id) }
    }

    /// Adds `color` as a Custom Color after the others, `added` now. It shows at
    /// once, once the core, which writes off the main thread, in order, has
    /// stored it. Nil if that failed.
    @discardableResult
    func addCustomColor(_ color: RGB, at added: Date = .now) async -> HighlightColor? {
        let rgb = Rgb(color)
        let milliseconds = added.millisecondsSince1970
        guard let stored = await inStateOrder({ try? $0.addCustomColor(rgb: rgb, added: milliseconds) })
        else { return nil }
        highlightColors.append(stored)
        return stored
    }

    /// Removes the Custom Color `color`. It goes at once; Highlights keep their
    /// color, and if it was the Default Highlight Color, yellow is again. Does
    /// nothing for a built-in color. The core writes off the main thread, in
    /// order, and this returns when it has.
    func removeCustomColor(_ color: HighlightColor) async {
        guard color.isCustom else { return }
        highlightColors.removeAll { $0 == color }
        if defaultHighlightColor == color { defaultHighlightColor = highlightColors[0] }
        let id = color.id
        await inStateOrder { try? $0.removeCustomColor(id: id) }
    }

    /// Runs `access` on the core off the main thread, after every earlier access
    /// to its state (a Document's or the Preferences) has finished, so reads
    /// and writes never overlap.
    private func inStateOrder<T: Sendable>(_ access: @escaping @Sendable (LeafCore.Library) -> T) async -> T {
        let previous = lastStateAccess
        let core = core
        let running = Task.detached {
            await previous?.value
            return access(core)
        }
        lastStateAccess = Task { _ = await running.value }
        return await running.value
    }

    /// Changes the Library in the core, off the main thread and in order with
    /// its other changes, then shows the Library as the core lists it after
    /// `change`. Each listing includes every change before it and is shown as
    /// it arrives, so the last one shown is the newest. Returns what `change` returned.
    @discardableResult
    private func relist<T: Sendable>(after change: @escaping @Sendable (LeafCore.Library) -> T) async -> T {
        let sort = sort.core
        let (result, listed) = await inStateOrder { core in (change(core), LibraryListing(core, sort: sort)) }
        guard let listed else { return result }
        // Gone from the Library, here or on another Device: so is its Cover.
        for gone in documents where listed.byID[gone.id] == nil { removeCover(gone.id) }
        listing = listed
        return result
    }
}

/// Forwards the core's details pass, reported on its thread, to the main
/// actor: the Gallery lists again as the core reads details.
private final class GalleryRelay: GalleryObserver {
    private let onChanged: @Sendable @MainActor () -> Void

    init(_ onChanged: @escaping @Sendable @MainActor () -> Void) { self.onChanged = onChanged }

    func galleryChanged() {
        Task { @MainActor [onChanged] in onChanged() }
    }
}

/// Cloud Backing reports what Sync changed here, see `SyncedLibrary`.
extension LibraryModel: SyncedLibrary {
    /// Lists the Documents again, as Sync may have changed them, and reads the
    /// Highlight Colors again. The core's details pass runs by itself after a
    /// Sync that changed the Documents.
    func libraryChanged() {
        Task { await relist { _ in } }
        Task { await reloadHighlightColors() }
    }

    func markupChanged(of id: String) { markupRevisions[id, default: 0] += 1 }
}
