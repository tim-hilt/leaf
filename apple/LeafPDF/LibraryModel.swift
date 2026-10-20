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

    /// A Document with no details or progress.
    init(id: String, file: URL) {
        self.id = id
        self.file = file
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
    enum Failure {
        case rejected(ImportRejection)
        /// The system's reason.
        case failed(String)
    }

    let file: URL
    let failure: Failure
}

/// What the window shows after Importing Files.
enum ImportResult {
    /// Open these Documents in Tabs, in the order given, with the Files that weren't Imported.
    case open([LibraryDocument], problems: [ImportProblem])
    /// Tell the user this Document already was in the Library, and offer to open it.
    case alreadyInLibrary(LibraryDocument)
    /// Nothing opens; alert if there are problems.
    case problems([ImportProblem])
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

/// Where Sync stands, while Connected.
enum SyncState: Equatable {
    case syncing
    /// The last Sync step succeeded then.
    case synced(Date)
    /// The last Sync step failed; the next one retries.
    case offline
    /// Blocked: the server rejected the password. Still Connected; Sync resumes
    /// once Settings gets the new one.
    case wrongPassword
    /// Blocked: another Device synced a newer version than this app knows, so
    /// nothing is written until the app is updated.
    case updateNeeded

    /// Whether the user has to act for Sync to go on. Being offline isn't blocked.
    var isBlocked: Bool { self == .wrongPassword || self == .updateNeeded }

    /// What Settings says.
    func line(now: Date = .now) -> String {
        switch self {
        case .syncing: "Syncing…"
        case .offline: "Offline"
        case .wrongPassword: "Wrong password"
        case .updateNeeded: "Update LeafPDF to keep syncing"
        case .synced(let date):
            now.timeIntervalSince(date) < 60
                ? "Synced just now" : "Synced \(date.formatted(.relative(presentation: .named)))"
        }
    }
}

/// Files uploading or downloading: what the Gallery's transfer bar shows.
struct FileTransfer: Equatable {
    /// Documents whose File has been transferred.
    let done: Int
    /// Documents whose File this Sync transfers.
    let total: Int

    /// Nil once everything is transferred: there is no bar to show.
    init?(done: Int, total: Int) {
        guard done < total else { return nil }
        self.done = done
        self.total = total
    }

    var text: String { "Syncing \(done) of \(total) Documents" }
}

/// The Cloud Provider this Device is Connected to.
struct CloudConnection: Equatable {
    /// The Server URL, or the directory of a test.
    let server: String
}

extension ConnectError {
    /// What Settings says next to the form.
    var message: String {
        switch self {
        case .WrongCredentials: "Wrong username or password"
        case .Unreachable: "Server not reachable"
        case .NotHttps: "URL must start with https://"
        case .NotWebDav: "Not a WebDAV server"
        }
    }
}

/// Forwards what the core's Sync loop reports, on its thread, to the main actor.
private final class SyncRelay: SyncObserver {
    private let onStatus: @Sendable @MainActor (SyncState) -> Void
    private let onTransfer: @Sendable @MainActor (FileTransfer?) -> Void
    private let onLibraryChanged: @Sendable @MainActor () -> Void
    private let onMarkupChanged: @Sendable @MainActor (String) -> Void

    init(
        status: @escaping @Sendable @MainActor (SyncState) -> Void,
        transfer: @escaping @Sendable @MainActor (FileTransfer?) -> Void,
        libraryChanged: @escaping @Sendable @MainActor () -> Void,
        markupChanged: @escaping @Sendable @MainActor (String) -> Void
    ) {
        onStatus = status
        onTransfer = transfer
        onLibraryChanged = libraryChanged
        onMarkupChanged = markupChanged
    }

    func statusChanged(status: SyncStatus) {
        let state: SyncState =
            switch status {
            case .syncing: .syncing
            case .synced(let at): .synced(Date(timeIntervalSince1970: Double(at) / 1000))
            case .offline: .offline
            case .wrongPassword: .wrongPassword
            case .updateNeeded: .updateNeeded
            }
        Task { @MainActor [onStatus] in onStatus(state) }
    }

    func transferProgress(done: UInt64, total: UInt64) {
        let transfer = FileTransfer(done: Int(done), total: Int(total))
        Task { @MainActor [onTransfer] in onTransfer(transfer) }
    }

    func libraryChanged() {
        Task { @MainActor [onLibraryChanged] in onLibraryChanged() }
    }

    func markupChanged(id: String) {
        Task { @MainActor [onMarkupChanged] in onMarkupChanged(id) }
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
    /// The Cloud Provider Connected to; nil while Cloud Backing is off.
    private(set) var connection: CloudConnection?
    /// Where Sync stands. Only meaningful while `connection` isn't nil.
    private(set) var syncState = SyncState.syncing
    /// Sync is blocked until the user acts: the Gallery shows a warning that
    /// opens Settings. Being offline is no reason for one.
    var showsSyncWarning: Bool { connection != nil && syncState.isBlocked }
    /// The File transfers of the running Sync; nil while none runs. Reading
    /// Progress, Markup and Highlight Colors Sync without it.
    private(set) var transfer: FileTransfer?
    /// How often Sync changed the Markup of each Document that it changed. A
    /// Reader that sees its Document's number change reads the Markup again.
    private var markupRevisions: [String: Int] = [:]
    @ObservationIgnored private let core: LeafCore.Library
    @ObservationIgnored private let saved: DetailsStore
    @ObservationIgnored private let covers: CoverStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let credentials: CloudCredentials
    @ObservationIgnored private let syncIntervals: SyncIntervals
    /// Where the system hands over temporary copies of Files; they are deleted
    /// after their Import. Nil where the system hands over the Files themselves.
    @ObservationIgnored private let inbox: URL?
    /// Names the current Connection, so reports of a finished one are ignored.
    @ObservationIgnored private var connectionID: UUID?
    /// Document IDs whose details are being read from their PDFs.
    @ObservationIgnored private var readingDetails: Set<String> = []
    /// The latest `importFiles` call; the next one waits for it.
    @ObservationIgnored private var lastImportFiles: Task<Void, Never>?
    /// The latest access to a Document's state in the core; the next one waits for it.
    @ObservationIgnored private var lastStateAccess: Task<Void, Never>?

    /// Opens the Library folder at `root`, creating it if needed, with Titles
    /// and Authors saved in `detailsFile`, Covers in `coversFolder` and the sort
    /// choice in `defaults`. Documents without saved details are
    /// listed by file name; a low-priority background pass then reads them
    /// from the PDFs, one at a time. A WebDAV server saved in `credentials` is
    /// Connected again, without contacting it, so launching offline works;
    /// Sync steps run `syncIntervals` apart. Files in `inbox` are temporary
    /// copies, deleted after `importFiles`.
    init(
        root: URL, detailsFile: URL, coversFolder: URL, defaults: UserDefaults, credentials: CloudCredentials,
        syncIntervals: SyncIntervals = SyncIntervals(debounceMs: 3000, pollMs: 10000), inbox: URL? = nil
    ) throws {
        core = try LeafCore.Library.open(root: root.path)
        saved = DetailsStore(file: detailsFile)
        covers = CoverStore(folder: coversFolder)
        self.defaults = defaults
        self.credentials = credentials
        self.syncIntervals = syncIntervals
        self.inbox = inbox
        sort = LibrarySort(from: defaults)
        highlightColors = core.highlightColors().map(HighlightColor.init)
        defaultHighlightColor = HighlightColor(core.defaultHighlightColor())
        refresh()
        readMissingDetails()
        if let account = credentials.load() {
            let id = newConnection()
            do {
                try core.resumeWebdav(
                    url: account.url, username: account.username, password: account.password,
                    observer: relay(for: id), intervals: syncIntervals)
                connection = CloudConnection(server: account.url)
            } catch {
                connectionID = nil
            }
        }
    }

    /// The Library in a hidden folder in Application Support, with Covers in
    /// the system Caches folder. On iOS, the system hands over Files from other
    /// apps as copies in `Documents/Inbox`.
    static func inApplicationSupport() throws -> LibraryModel {
        let files = FileManager.default
        let support = try files.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let caches = try files.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return try LibraryModel(
            root: support.appending(path: "Library", directoryHint: .isDirectory),
            detailsFile: support.appending(path: "Details.json"),
            coversFolder: caches.appending(path: "Covers", directoryHint: .isDirectory),
            defaults: .standard,
            credentials: CloudCredentials(defaults: .standard, service: "com.timhilt.leafpdf.cloud"),
            inbox: Self.systemInbox)
    }

    private static var systemInbox: URL? {
        #if os(iOS)
            URL.documentsDirectory.appending(path: "Inbox", directoryHint: .isDirectory)
        #else
            nil
        #endif
    }

    /// Connects to the WebDAV server at `url` and starts syncing, which first
    /// merges this Library with the one in the cloud. Checks the details first
    /// and throws a `ConnectError` if they are wrong. Keeps them, the password
    /// in the Keychain, until `disconnect`. Replaces any earlier Connection.
    func connect(url: String, username: String, password: String) async throws {
        let core = core
        let id = newConnection()
        let observer = relay(for: id)
        let intervals = syncIntervals
        do {
            try await Task.detached {
                try core.connectWebdav(
                    url: url, username: username, password: password, observer: observer, intervals: intervals)
            }.value
        } catch {
            if connectionID == id { connectionID = nil }
            throw error
        }
        connection = CloudConnection(server: url)
        credentials.save(WebDAVAccount(url: url, username: username, password: password))
    }

    /// Gives the Connection a new password, after the server's has changed, without
    /// Disconnecting: Sync resumes at once. Checks it first and throws a
    /// `ConnectError` if it is wrong; the Connection and the saved password then
    /// stay as they were. Does nothing unless Connected to a WebDAV server.
    func updatePassword(_ password: String) async throws {
        guard let account = credentials.load(), let id = connectionID else { return }
        let core = core
        try await Task.detached {
            try core.updateWebdavCredentials(url: account.url, username: account.username, password: password)
        }.value
        // Disconnected meanwhile: nothing to keep.
        guard connectionID == id else { return }
        credentials.save(WebDAVAccount(url: account.url, username: account.username, password: password))
    }

    /// Connects to the directory `directory` as if it were a cloud, for tests.
    /// Not remembered.
    func connect(directory: URL) async throws {
        let core = core
        let id = newConnection()
        let observer = relay(for: id)
        let intervals = syncIntervals
        try await Task.detached {
            try core.connectDirectory(path: directory.path, observer: observer, intervals: intervals)
        }.value
        connection = CloudConnection(server: directory.path)
    }

    /// Stops syncing, cancelling running transfers, and forgets the URL,
    /// username and password. Keeps the whole Library and leaves the cloud as it is.
    func disconnect() async {
        connectionID = nil
        connection = nil
        transfer = nil
        credentials.forget()
        let core = core
        await Task.detached { core.disconnect() }.value
    }

    /// The app is in the foreground: Syncs at once, then regularly.
    func foreground() { core.foreground() }

    /// The app goes to the background: Syncs once more, then stops.
    func background() { core.background() }

    private func newConnection() -> UUID {
        let id = UUID()
        connectionID = id
        syncState = .syncing
        transfer = nil
        return id
    }

    /// What the core reports about Connection `id`, as long as it is the current one.
    private func relay(for id: UUID) -> SyncObserver {
        SyncRelay(
            status: { [weak self] state in
                guard let self, connectionID == id else { return }
                syncState = state
                // A Sync that failed midway reports no end.
                if state != .syncing { transfer = nil }
            },
            transfer: { [weak self] transfer in
                if self?.connectionID == id { self?.transfer = transfer }
            },
            libraryChanged: { [weak self] in
                guard let self, connectionID == id else { return }
                refresh()
                readMissingDetails()
                Task { await self.reloadHighlightColors() }
            },
            markupChanged: { [weak self] document in
                guard let self, connectionID == id else { return }
                markupRevisions[document, default: 0] += 1
            })
    }

    /// How often Sync changed the Markup of `document`; it changes whenever
    /// `highlights(of:)` and `pageNotes(of:)` have news.
    func markupRevision(of document: LibraryDocument) -> Int { markupRevisions[document.id, default: 0] }

    /// Reads the Highlight Colors again, after every write to the Preferences
    /// already queued, as Sync may have changed them.
    private func reloadHighlightColors() async {
        let core = core
        let (colors, chosen) = await inStateOrder { (core.highlightColors(), core.defaultHighlightColor()) }
        let all = colors.map(HighlightColor.init)
        let defaultColor = HighlightColor(chosen)
        if highlightColors != all { highlightColors = all }
        if defaultHighlightColor != defaultColor { defaultHighlightColor = defaultColor }
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
        let covers = covers
        let id = document.id
        return await Task.detached { covers.saved(id) }.value
    }

    /// The Cover of `document`: the saved one, or page 1 rendered off the main
    /// thread and saved. Nil if it can't be rendered; the Gallery then keeps
    /// the placeholder. Cancelling the caller drops a request whose rendering
    /// hasn't started yet, so cells that scrolled away don't hold up the others.
    func cover(for document: LibraryDocument) async -> CGImage? {
        guard !Task.isCancelled else { return nil }
        let covers = covers
        let id = document.id
        let file = document.file
        let loading = Task.detached(priority: .utility) { Task.isCancelled ? nil : covers.cover(id: id, file: file) }
        return await withTaskCancellationHandler {
            await loading.value
        } onCancel: {
            loading.cancel()
        }
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

        let core = core
        let path = url.path
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
            core.localChange()
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

    /// Imports `urls`, which came from `origin`, one after another, and says
    /// what the window shows: every Document of the Files, new or already in
    /// the Library, opens in a Tab. Only a single File already in the Library
    /// from "+" or a drop is reported to the user instead. A File that isn't
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
        var opening: [LibraryDocument] = []
        var duplicate: LibraryDocument?
        var problems: [ImportProblem] = []
        for url in urls {
            switch await `import`(url) {
            case .opened(let document): opening.append(document)
            case .duplicate(let document):
                opening.append(document)
                duplicate = document
            case .rejected(let reason): problems.append(ImportProblem(file: url, failure: .rejected(reason)))
            case .failed(let message): problems.append(ImportProblem(file: url, failure: .failed(message)))
            }
            deleteIfTemporary(url)
        }
        if urls.count == 1, origin != .openWithOrShare, let duplicate { return .alreadyInLibrary(duplicate) }
        return opening.isEmpty ? .problems(problems) : .open(opening, problems: problems)
    }

    private func deleteIfTemporary(_ file: URL) {
        guard let inbox, file.resolvingSymlinksInPath().path.hasPrefix(inbox.resolvingSymlinksInPath().path + "/")
        else { return }
        try? FileManager.default.removeItem(at: file)
    }

    /// Deletes the Document, its File and its saved Title, Author and Cover. If that
    /// fails, the Document stays in `documents`.
    func remove(_ document: LibraryDocument) {
        if (try? core.remove(id: document.id)) != nil {
            saved[document.id] = nil
            covers.remove(document.id)
            core.localChange()
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
            lastRead: lastRead.millisecondsSince1970)
        documents[index].progress = progress

        let core = core
        let id = document.id
        await writing { try? core.saveProgress(id: id, progress: progress) }
    }

    /// The Highlights of `document`, oldest first. Empty if there are none or
    /// the Document was Removed.
    func highlights(of document: LibraryDocument) async -> [Highlight] {
        let core = core
        let id = document.id
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
        let core = core
        let id = document.id
        let pages = anchor.pages.map { page in
            PageRects(
                pageIndex: UInt32(page.pageIndex),
                rects: page.rects.map { Rect(x: $0.minX, y: $0.minY, width: $0.width, height: $0.height) })
        }
        let rgb = Rgb(defaultHighlightColor.color)
        let milliseconds = created.millisecondsSince1970
        let stored = await writing {
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
        let core = core
        let id = document.id
        let highlightID = highlight.id
        let rgb = Rgb(color)
        await writing { try? core.setHighlightColor(id: id, highlight: highlightID, color: rgb) }
    }

    /// Sets the Note of `highlight` of `document` to `note`; empty removes it. The
    /// core writes off the main thread, in order, and this returns when it has.
    /// Does nothing for a Document that was Removed.
    func setNote(_ note: String, of highlight: Highlight, in document: LibraryDocument) async {
        guard documents.contains(where: { $0.id == document.id }) else { return }
        let core = core
        let id = document.id
        let highlightID = highlight.id
        await writing { try? core.setHighlightNote(id: id, highlight: highlightID, note: note) }
    }

    /// Removes `highlight` from `document`. The core writes off the main
    /// thread, in order, and this returns when it has. Does nothing for a
    /// Document that was Removed.
    func removeHighlight(_ highlight: Highlight, from document: LibraryDocument) async {
        guard documents.contains(where: { $0.id == document.id }) else { return }
        let core = core
        let id = document.id
        let highlightID = highlight.id
        await writing { try? core.removeHighlight(id: id, highlight: highlightID) }
    }

    /// The page Notes of `document`, oldest first. Empty if there are none or
    /// the Document was Removed.
    func pageNotes(of document: LibraryDocument) async -> [PageNote] {
        let core = core
        let id = document.id
        let markup = await inStateOrder { try? core.markup(id: id) }
        return markup?.pageNotes.map(PageNote.init) ?? []
    }

    /// Adds a page Note without text at `place` to `document`, `created` now. The
    /// core writes off the main thread, in order, and this returns the stored
    /// page Note when it has. It isn't listed by `pageNotes(of:)` until it has
    /// text (`setText`). Nil for a Document that was Removed, or if the write failed.
    func addPageNote(at place: Place, to document: LibraryDocument, at created: Date = .now) async -> PageNote? {
        guard documents.contains(where: { $0.id == document.id }) else { return nil }
        let core = core
        let id = document.id
        let milliseconds = created.millisecondsSince1970
        let stored = await writing {
            try? core.addPageNote(
                id: id, pageIndex: UInt32(place.pageIndex), x: place.point.x, y: place.point.y, created: milliseconds)
        }
        // Removed meanwhile: the core stored nothing.
        guard documents.contains(where: { $0.id == id }) else { return nil }
        return stored.map(PageNote.init)
    }

    /// Sets the text of `note` of `document` to `text`; empty removes the page
    /// Note. The core writes off the main thread, in order, and this returns when
    /// it has. Does nothing for a Document that was Removed.
    func setText(_ text: String, of note: PageNote, in document: LibraryDocument) async {
        guard documents.contains(where: { $0.id == document.id }) else { return }
        let core = core
        let id = document.id
        let noteID = note.id
        await writing { try? core.setPageNoteText(id: id, note: noteID, text: text) }
    }

    /// Removes the page Note `note` from `document`. The core writes off the main
    /// thread, in order, and this returns when it has. Does nothing for a
    /// Document that was Removed.
    func removePageNote(_ note: PageNote, from document: LibraryDocument) async {
        guard documents.contains(where: { $0.id == document.id }) else { return }
        let core = core
        let id = document.id
        let noteID = note.id
        await writing { try? core.removePageNote(id: id, note: noteID) }
    }

    /// Makes `color`, one of `highlightColors`, the Default Highlight Color. It
    /// shows at once; the core writes off the main thread, in order, and this
    /// returns when it has.
    func setDefaultHighlightColor(_ color: HighlightColor) async {
        defaultHighlightColor = color
        let core = core
        let id = color.id
        await writing { try? core.setDefaultHighlightColor(id: id) }
    }

    /// Adds `color` as a Custom Color after the others, `added` now. It shows at
    /// once, once the core, which writes off the main thread, in order, has
    /// stored it. Nil if that failed.
    @discardableResult
    func addCustomColor(_ color: RGB, at added: Date = .now) async -> HighlightColor? {
        let core = core
        let rgb = Rgb(color)
        let milliseconds = added.millisecondsSince1970
        guard let stored = await writing({ try? core.addCustomColor(rgb: rgb, added: milliseconds) })
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
        let core = core
        let id = color.id
        await writing { try? core.removeCustomColor(id: id) }
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

    /// `inStateOrder` for a write: tells the core, which sends it to the cloud
    /// soon, once it is stored.
    private func writing<T: Sendable>(_ access: @escaping @Sendable () -> T) async -> T {
        let result = await inStateOrder(access)
        core.localChange()
        return result
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
        let kept = Set(stored.map(\.id))
        // Removed on another Device.
        for gone in documents where !kept.contains(gone.id) {
            saved[gone.id] = nil
            covers.remove(gone.id)
        }
        documents = stored.map { LibraryDocument($0, details: saved[$0.id]) }
    }

    /// Reads the details of Documents that have none, or none with a page
    /// count, from their PDFs, one at a time at background priority,
    /// publishing each as it arrives. A PDF that can't be read is skipped and
    /// tried again at the next launch.
    private func readMissingDetails() {
        let missing = documents.filter { $0.pageCount == nil && !readingDetails.contains($0.id) }.map {
            ($0.id, $0.file)
        }
        guard !missing.isEmpty else { return }
        readingDetails.formUnion(missing.map(\.0))
        Task(priority: .utility) { [weak self] in
            for (id, file) in missing {
                let read = await Task.detached(priority: .utility) { PDFDocument(url: file)?.details }.value
                guard let self else { return }
                self.readingDetails.remove(id)
                self.publish(read, for: id)
            }
        }
    }

    /// Saves `details` for Document `id` unless it was Removed or already has
    /// a page count, which means complete details.
    private func publish(_ details: DocumentDetails?, for id: String) {
        guard let details, saved[id]?.pageCount == nil, let index = documents.firstIndex(where: { $0.id == id }) else {
            return
        }
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

extension PageNote {
    fileprivate init(_ stored: LeafCore.PageNote) {
        self.init(
            id: stored.id, place: Place(pageIndex: Int(stored.pageIndex), point: CGPoint(x: stored.x, y: stored.y)),
            text: stored.text)
    }
}

extension Rgb {
    fileprivate init(_ color: RGB) {
        self.init(r: color.r.byte, g: color.g.byte, b: color.b.byte)
    }
}

extension Date {
    /// This time as the core takes it: whole milliseconds since the Unix epoch, none before.
    fileprivate var millisecondsSince1970: UInt64 { UInt64(max(0, timeIntervalSince1970 * 1000).rounded()) }
}

extension Double {
    /// A color component from 0 to 1 as a byte.
    fileprivate var byte: UInt8 { UInt8((min(max(self, 0), 1) * 255).rounded()) }
}
