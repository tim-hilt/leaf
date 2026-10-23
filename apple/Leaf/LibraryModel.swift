import LeafCore
import Network
import Observation
import PDFKit
import Synchronization

/// A Document in the Library, as the core last listed it. Holds no open PDF:
/// the Reader opens `file`. Equal only with equal details, progress and Date
/// Imported, so views showing a stale copy update when the Title arrives;
/// compare `id`s to tell whether two values are the same Document.
///
/// Title, Author and page count are read from a PDF at Import or by the
/// Library's background pass; the core reads an EPUB's at Import.
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

    /// The name the File had when it was Imported.
    var fileName: String { file.lastPathComponent }
    /// Where the user left off, to reopen the Document there.
    var place: Place? { progress?.place }
    /// When the Reader last showed the Document; nil if never.
    var lastRead: Date? { progress.map { Date(milliseconds: $0.lastRead) } }

    /// A Document with no details or progress, Imported at the Unix epoch.
    init(id: String, file: URL) {
        stored = LeafCore.Document(
            id: id, path: file.path, format: .pdf, imported: 0, progress: nil,
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

/// Why a File isn't Imported at all; nothing was copied.
enum ImportRejection: Error {
    /// Neither a PDF nor an EPUB.
    case notPDF
    /// Looks like a PDF, but PDFKit can't open it.
    case unreadable
    /// Needs a password to open. PDFs that only restrict permissions aren't locked.
    case locked
    /// Looks like an EPUB, but the core can't read it.
    case invalidEPUB
    /// An EPUB with encrypted content.
    case drmProtectedEPUB
    /// An EPUB with a fixed layout.
    case fixedLayoutEPUB
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
}

/// The Library as the clients see it: the core's Library folder plus its
/// Documents. One per app, shared by all windows.
@MainActor @Observable
final class LibraryModel {
    /// Every Document, newest Import first.
    private(set) var documents: [LibraryDocument] = [] {
        didSet { relist() }
    }
    /// How the Gallery orders its Documents. Remembered on this device (user
    /// defaults, not synced) and shared by all windows; setting it re-orders once the
    /// core has the new listing.
    var sort: LibrarySort {
        didSet {
            guard sort != oldValue else { return }
            sort.save(to: defaults)
            relist()
        }
    }
    /// The core's listing of the Documents in `sort` order, kept up to date as
    /// Titles arrive. Nil only if the core couldn't list them.
    private var listing: Listing?
    /// Counts `relist` calls, so a listing overtaken by a newer one is dropped.
    @ObservationIgnored private var listings = 0
    /// The latest `relist`.
    @ObservationIgnored private var relisting: Task<Void, Never>?
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
    private(set) var syncState = Status.syncing
    /// Whether the Device has a network; nothing Syncs without one.
    private(set) var isOnline = true
    /// What the Gallery's toolbar shows of Sync; nil while not Connected.
    var syncIndicator: SyncIndicator? {
        guard connection != nil else { return nil }
        return isOnline ? SyncIndicator(syncState) : .noConnection
    }
    /// The File transfers of the running Sync; nil while none runs. Reading
    /// Progress, Markup and Highlight Colors Sync without it.
    private(set) var transfer: FileTransfer?
    /// How often Sync changed the Markup of each Document that it changed. A
    /// Reader that sees its Document's number change reads the Markup again.
    private var markupRevisions: [String: Int] = [:]
    @ObservationIgnored private let core: LeafCore.Library
    @ObservationIgnored private let covers: CoverStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let credentials: CloudCredentials
    @ObservationIgnored private let iCloudDrive: ICloudDrive
    @ObservationIgnored private let oauthDrives: [CloudProvider: OAuthDrive]
    /// The access to iCloud Drive that a Connection to it holds, until it ends.
    @ObservationIgnored private var iCloudGrant: ICloudGrant?
    @ObservationIgnored private let syncIntervals: SyncIntervals
    /// Tells `setOnline` how the system's network stands, once `followNetwork` runs.
    @ObservationIgnored private var network: NWPathMonitor?
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
    /// Counts `reload` calls, so a listing overtaken by a newer one is dropped.
    @ObservationIgnored private var reloads = 0
    /// Covers decoded lately, by Document ID; the system evicts them as memory gets tight.
    @ObservationIgnored private let decodedCovers = {
        let cache = NSCache<NSString, CGImage>()
        cache.totalCostLimit = 64 << 20
        return cache
    }()

    /// Opens the Library folder at `root`, creating it if needed, with Covers
    /// in `coversFolder` and the sort choice in `defaults`. Documents whose
    /// details the core lacks are listed by file name; a low-priority
    /// background pass then reads them from the PDFs, one at a time. The Cloud
    /// Provider saved in `credentials` is Connected again, without contacting
    /// it, so launching offline works;
    /// Sync steps run `syncIntervals` apart. Files in `inbox` are temporary
    /// copies, deleted after `importFiles`.
    init(
        root: URL, coversFolder: URL, defaults: UserDefaults, credentials: CloudCredentials,
        iCloudDrive: ICloudDrive = .system, oauth: [CloudProvider: OAuthDrive] = OAuthDrive.system,
        syncIntervals: SyncIntervals = .standard, inbox: URL? = nil
    ) throws {
        core = try LeafCore.Library.open(root: root.path)
        covers = CoverStore(folder: coversFolder)
        self.defaults = defaults
        self.credentials = credentials
        self.iCloudDrive = iCloudDrive
        oauthDrives = oauth
        self.syncIntervals = syncIntervals
        self.inbox = inbox
        sort = LibrarySort(from: defaults)
        let stored = core.highlightColors()
        highlightColors = stored.colors
        defaultHighlightColor = stored.defaultColor
        refresh()
        // Built at once, so the Gallery opens in order rather than filling in.
        listing = try? core.listing(sort: sort.core)
        readMissingDetails()
        if let saved = credentials.load() {
            let id = newConnection()
            do {
                switch saved {
                case .webDAV(let account):
                    try core.resumeWebdav(
                        url: account.url, username: account.username, password: account.password,
                        observer: relay(for: id), intervals: syncIntervals)
                    connection = CloudConnection(provider: .webDAV, detail: account.url)
                case .iCloudDrive(let bookmark):
                    connection = Self.iCloudConnection
                    // Without the grant or iCloud Drive there is nothing to sync with until Reconnect.
                    if !resumeICloudDrive(bookmark: bookmark, id: id) { loseAccess() }
                case .oauth(let provider, let token, let account):
                    guard let drive = oauthDrives[provider] else { throw ConnectError.AccessDenied }
                    drive.resume(core, token, refreshTokens(token, for: id), relay(for: id), syncIntervals)
                    connection = Self.oauthConnection(provider, account)
                }
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
        // Where details were kept before the core kept them; the background pass reads them again.
        try? files.removeItem(at: support.appending(path: "Details.json"))
        let library = try LibraryModel(
            root: support.appending(path: "Library", directoryHint: .isDirectory),
            coversFolder: caches.appending(path: "Covers", directoryHint: .isDirectory),
            defaults: .standard,
            credentials: CloudCredentials(defaults: .standard, service: "com.timhilt.leaf.cloud"),
            inbox: Self.systemInbox)
        library.followNetwork()
        return library
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
        connection = CloudConnection(provider: .webDAV, detail: url)
        credentials.save(.webDAV(WebDAVAccount(url: url, username: username, password: password)))
    }

    /// Gives the Connection access again, after it was lost, with a new password
    /// for the WebDAV server: Sync resumes at once, without Disconnecting. Checks
    /// it first and throws a `ConnectError` if it is wrong; the Connection and
    /// the saved password then stay as they were. Does nothing unless a WebDAV
    /// Connection is saved.
    func reconnect(password: String) async throws {
        guard case .webDAV(let account) = credentials.load(), let id = connectionID else { return }
        let core = core
        try await Task.detached {
            try core.reconnectWebdav(url: account.url, username: account.username, password: password)
        }.value
        // Disconnected meanwhile: nothing to keep.
        guard connectionID == id else { return }
        credentials.save(.webDAV(WebDAVAccount(url: account.url, username: account.username, password: password)))
    }

    /// Whether iCloud Drive is on and the user is signed in to iCloud: if not,
    /// Connecting to it has to wait.
    var iCloudDriveIsAvailable: Bool { iCloudDrive.isAvailable() }

    private static let iCloudConnection = CloudConnection(
        provider: .iCloudDrive, detail: ICloudDrive.folderDescription)

    /// Connects to iCloud Drive and starts syncing, which first merges this
    /// Library with the one in the cloud. `granted` is the folder the user chose
    /// in the system's folder picker: iCloud Drive itself, else this throws
    /// `WrongFolder`; `ICloudDriveUnavailable` while iCloud Drive is off. Keeps
    /// the grant until `disconnect`, and holds the access meanwhile. Replaces any
    /// earlier Connection, and also serves to Reconnect when access was lost.
    func connectICloudDrive(granting granted: URL) async throws {
        guard iCloudDrive.isAvailable() else { throw ConnectError.ICloudDriveUnavailable }
        guard iCloudDrive.isRoot(granted) else { throw ConnectError.WrongFolder }
        let grant = try ICloudGrant(granting: granted)
        let id = newConnection()
        let folder = grant.folder.path
        let (core, observer, intervals) = (core, relay(for: id), syncIntervals)
        let downloads = DownloadRequests(iCloudDrive.requestDownload)
        do {
            try await Task.detached {
                try core.connectIcloudDrive(
                    folder: folder, downloads: downloads, observer: observer, intervals: intervals)
            }.value
        } catch {
            if connectionID == id { connectionID = nil }
            throw error
        }
        iCloudGrant = grant
        connection = Self.iCloudConnection
        credentials.save(.iCloudDrive(bookmark: grant.bookmark))
    }

    /// Resumes syncing with the iCloud Drive that `bookmark` gives access to.
    /// False if it can't be resumed: access is lost.
    private func resumeICloudDrive(bookmark: Data, id: UUID) -> Bool {
        guard iCloudDrive.isAvailable(), let grant = ICloudGrant(bookmark: bookmark),
            (try? core.connectIcloudDrive(
                folder: grant.folder.path, downloads: DownloadRequests(iCloudDrive.requestDownload),
                observer: relay(for: id), intervals: syncIntervals)) != nil
        else { return false }
        iCloudGrant = grant
        return true
    }

    private static func oauthConnection(_ provider: CloudProvider, _ account: String) -> CloudConnection {
        CloudConnection(provider: provider, detail: account.isEmpty ? provider.unnamedAccount : account)
    }

    /// Keeps the latest refresh token of Connection `id`, and saves each one the core reports.
    private func refreshTokens(_ token: String, for id: UUID) -> RefreshTokenKeeper {
        RefreshTokenKeeper(token) { [weak self] rotated in
            // While connecting, `connection` is nil: connecting saves the latest.
            guard let self, connectionID == id, connection != nil,
                case .oauth(let provider, _, let account) = credentials.load()
            else { return }
            credentials.save(.oauth(provider, refreshToken: rotated, account: account))
        }
    }

    /// Connects to the Google Drive or OneDrive (`provider`) of the user who
    /// owns `refreshToken`, which the sign-in page handed out, and starts
    /// syncing, which first merges this Library with the one in the cloud.
    /// Throws a `ConnectError` if the provider refuses it (`UnsupportedAccount`
    /// for a work or school account) or can't be reached. Keeps the token, in
    /// the Keychain, until `disconnect`; tokens that the provider rotates
    /// replace it. Replaces any earlier Connection.
    func connectOAuth(_ provider: CloudProvider, refreshToken: String) async throws {
        guard let drive = oauthDrives[provider] else { throw ConnectError.AccessDenied }
        let id = newConnection()
        let tokens = refreshTokens(refreshToken, for: id)
        let (core, observer, intervals) = (core, relay(for: id), syncIntervals)
        let account: String
        do {
            account = try await Task.detached {
                try drive.connect(core, refreshToken, tokens, observer, intervals)
            }.value
        } catch {
            if connectionID == id { connectionID = nil }
            throw error
        }
        connection = Self.oauthConnection(provider, account)
        credentials.save(.oauth(provider, refreshToken: tokens.latest, account: account))
    }

    /// Gives the Connection access again, after it was lost, with the token of
    /// a new sign-in: Sync resumes at once, without Disconnecting. Throws a
    /// `ConnectError` if the provider refuses it; the Connection and the saved
    /// token then stay as they were. Does nothing unless a Google Drive or
    /// OneDrive Connection is saved.
    func reconnectOAuth(refreshToken: String) async throws {
        guard case .oauth(let provider, _, _) = credentials.load(), let drive = oauthDrives[provider],
            let id = connectionID
        else { return }
        let tokens = refreshTokens(refreshToken, for: id)
        let core = core
        let account = try await Task.detached {
            try drive.reconnect(core, refreshToken, tokens)
        }.value
        // Disconnected meanwhile: nothing to keep.
        guard connectionID == id else { return }
        connection = Self.oauthConnection(provider, account)
        credentials.save(.oauth(provider, refreshToken: tokens.latest, account: account))
    }

    /// Sync can't go on until the user gives access again: Reconnect.
    private func loseAccess() {
        // Reports of the Connection that was running no longer count.
        connectionID = nil
        iCloudGrant = nil
        transfer = nil
        syncState = .accessLost
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
        connection = CloudConnection(provider: .webDAV, detail: directory.path)
    }

    /// Stops syncing, cancelling running transfers, and forgets the saved
    /// credentials. Keeps the whole Library and leaves the cloud as it is.
    func disconnect() async {
        connectionID = nil
        connection = nil
        transfer = nil
        iCloudGrant = nil
        credentials.forget()
        let core = core
        await Task.detached { core.disconnect() }.value
    }

    /// The app is in the foreground: Syncs at once, then regularly.
    func foreground() {
        if connection?.provider == .iCloudDrive, syncState != .accessLost, !iCloudDrive.isAvailable() {
            loseAccess()
        } else {
            core.foreground()
        }
    }

    /// The app goes to the background: Syncs once more, then stops.
    func background() { core.background() }

    /// Whether the Device has a network. Without one nothing Syncs; once it is
    /// back, Sync runs at once.
    func setOnline(_ online: Bool) {
        guard online != isOnline else { return }
        isOnline = online
        core.setOnline(online: online)
    }

    /// Follows the system's network from now on, see `setOnline`.
    func followNetwork() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in self?.setOnline(online) }
        }
        monitor.start(queue: DispatchQueue(label: "com.timhilt.leaf.network"))
        network = monitor
    }

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
                Task {
                    await self.reload()
                    self.readMissingDetails()
                }
                Task { await self.reloadHighlightColors() }
            },
            markupChanged: { [weak self] document in
                guard let self, connectionID == id else { return }
                markupRevisions[document, default: 0] += 1
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
        let byID = Dictionary(documents.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // A Document Removed since the listing was built is skipped.
        return listing.matching(search: searchText).compactMap { byID[$0] }
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
    /// thread, publishing `runningImport` meanwhile. Files that aren't
    /// readable, unlocked PDFs or valid EPUBs without DRM are rejected, and
    /// nothing stays in the Library. The Document's details and Cover are
    /// saved before this returns.
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
        case .success(let pdf): read = pdf
        }

        let core = core
        let path = url.path
        // Reports arriving after the Import finished find no runningImport and do nothing.
        let relay = ProgressRelay { [weak self] fraction in
            guard let running = self?.runningImport else { return }
            self?.runningImport?.fraction = max(running.fraction, fraction)
        }
        let details = read?.details
        do {
            let (stored, isNew) = try await Task.detached {
                let (stored, isNew) =
                    switch try core.import(source: path, progress: relay) {
                    case .imported(let stored): (stored, true)
                    case .alreadyImported(let stored): (stored, false)
                    }
                if let details { try? core.setDetails(stored.id, details) }
                // An EPUB's Cover is made from the File in the Library.
                if stored.format == .epub {
                    _ = covers.cover(id: stored.id, source: LibraryDocument(stored).coverSource(core: core))
                }
                return (stored, isNew)
            }.value
            if let cover = read?.cover { covers.save(cover, id: stored.id) }
            let id = stored.id
            // With its details.
            guard let listed = await Task.detached(operation: { try? core.document(id: id) }).value else {
                return .failed("The imported file couldn't be opened.")
            }
            let document = LibraryDocument(listed)
            runningImport?.title = document.title
            if let index = documents.firstIndex(where: { $0.id == id }) {
                documents[index] = document
            } else {
                // The newest Import.
                documents.insert(document, at: 0)
            }
            await relisting?.value
            return isNew ? .opened(document) : .duplicate(document)
        } catch LibraryError.Failed(let message) {
            return .failed(message)
        } catch LibraryError.InvalidEpub {
            return .rejected(.invalidEPUB)
        } catch LibraryError.DrmProtectedEpub {
            return .rejected(.drmProtectedEPUB)
        } catch LibraryError.FixedLayoutEpub {
            return .rejected(.fixedLayoutEPUB)
        } catch LibraryError.UnsupportedFormat {
            return .rejected(.notPDF)
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

    /// Deletes the Document, its File, its details and its Cover. If that
    /// fails, the Document stays in `documents`.
    func remove(_ document: LibraryDocument) {
        guard (try? core.remove(id: document.id)) != nil else { return }
        removeCover(document.id)
        documents.removeAll { $0.id == document.id }
    }

    /// EPUB `document`, opened for reading off the main thread. Nil for a PDF, and
    /// for an EPUB the core can't read.
    func epub(of document: LibraryDocument) async -> EpubBook? {
        let core = core
        let id = document.id
        return await Task.detached { (try? core.openEpub(id: id)) ?? nil }.value
    }

    /// Saves `place` as Reading Progress of `document`, read `lastRead`. The
    /// core writes off the main thread, in order; this returns when it has,
    /// with the Document updated in every window. Does nothing for a Document
    /// that was Removed. A failed write is ignored: the next save replaces it.
    func saveProgress(_ place: Place, of document: LibraryDocument, at lastRead: Date = .now) async {
        let progress = ReadingProgress(place: place, lastRead: lastRead.millisecondsSince1970)
        let id = document.id
        update(
            await inStateOrder {
                try? $0.saveProgress(id: id, progress: progress)
                return try? $0.document(id: id)
            })
        await relisting?.value
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

    /// What Import reads from a PDF it opened to check the File.
    /// An EPUB is checked by the core, which reads its details and Cover itself.
    private struct ReadPDF: Sendable {
        let details: PDFDetails
        let cover: CGImage?
    }

    /// What the File at `url` yields if it can be Imported, or why not. The
    /// core decides its Format; PDFKit checks a PDF. A File that can't be read
    /// at all isn't rejected (nil): copying it fails with the system's own
    /// reason. Nor is an EPUB: the core checks it. Reads the File and renders
    /// its Cover, so keep it off the main thread.
    private nonisolated static func check(_ url: URL, covers: CoverStore) -> Result<ReadPDF?, ImportRejection> {
        let format: Format?
        do { format = try formatOfFile(path: url.path) } catch { return .success(nil) }
        switch format {
        case nil: return .failure(.notPDF)
        case .epub: return .success(nil)
        case .pdf:
            guard let pdf = PDFDocument(url: url) else { return .failure(.unreadable) }
            guard !pdf.isLocked else { return .failure(.locked) }
            return .success(ReadPDF(details: pdf.details, cover: covers.render(pdf)))
        }
    }

    /// Asks the core for a new listing off the main thread, which replaces
    /// `listing` unless a newer request overtook it. The core lists what it
    /// has stored, which is at least as new as `documents`.
    private func relist() {
        listings += 1
        let current = listings
        let core = core
        let sort = sort.core
        relisting = Task { [weak self] in
            let built = await Task.detached(priority: .userInitiated) { try? core.listing(sort: sort) }.value
            guard let self, current == listings, let built else { return }
            listing = built
        }
    }

    /// Reloads `documents` from the core. If the listing fails, `documents`
    /// stays as it was rather than looking as if everything was Removed.
    private func refresh() { apply(try? core.documents()) }

    /// `refresh`, listing off the main thread. A reload overtaken by a newer
    /// one changes nothing.
    private func reload() async {
        reloads += 1
        let reload = reloads
        let core = core
        let stored = await Task.detached(priority: .userInitiated) { try? core.documents() }.value
        guard reload == reloads else { return }
        apply(stored)
        await relisting?.value
    }

    private func apply(_ stored: [LeafCore.Document]?) {
        guard let stored else { return }
        let kept = Set(stored.map(\.id))
        // Removed on another Device.
        for gone in documents where !kept.contains(gone.id) { removeCover(gone.id) }
        let reloaded = stored.map(LibraryDocument.init)
        if reloaded != documents { documents = reloaded }
    }

    /// Replaces a Document in `documents` with `stored`, its newer copy from
    /// the core; nothing if it was Removed meanwhile.
    private func update(_ stored: LeafCore.Document?) { update(stored.map { [$0] } ?? []) }

    /// `update` for several Documents at once, so the listing is made once.
    private func update(_ stored: [LeafCore.Document]) {
        var updated = documents
        for stored in stored {
            guard let index = updated.firstIndex(where: { $0.id == stored.id }) else { continue }
            updated[index] = LibraryDocument(stored)
        }
        if updated != documents { documents = updated }
    }

    /// Reads the details of Documents the core has none of from their PDFs,
    /// one at a time at background priority, publishing them in small batches.
    /// A PDF that can't be read is skipped and tried again at the next launch.
    private func readMissingDetails() {
        let missing = documents.filter { $0.format == .pdf && $0.pageCount == nil && !readingDetails.contains($0.id) }
            .map { ($0.id, $0.file) }
        guard !missing.isEmpty else { return }
        readingDetails.formUnion(missing.map(\.0))
        Task(priority: .utility) { [weak self] in
            // Each publish lists every Document again, so not one by one.
            var read: [LeafCore.Document] = []
            var published = ContinuousClock.now
            for (id, file) in missing {
                let details = await Task.detached(priority: .utility) { PDFDocument(url: file)?.details }.value
                guard let self else { return }
                readingDetails.remove(id)
                guard let details else { continue }
                let stored = await inStateOrder {
                    try? $0.setDetails(id, details)
                    return try? $0.document(id: id)
                }
                if let stored { read.append(stored) }
                if read.count >= 16 || published.duration(to: .now) > .milliseconds(500) {
                    update(read)
                    read = []
                    published = .now
                }
            }
            self?.update(read)
        }
    }
}

extension SyncIntervals {
    /// Local changes sync within seconds, Reading Progress within a minute;
    /// polls run every 10 seconds, backing off to every 5 minutes while idle.
    static let standard = SyncIntervals(debounceMs: 3000, progressMs: 60000, pollMs: 10000, idlePollMs: 300_000)
}

extension LeafCore.Library {
    /// Keeps `details`, read from the File of Document `id`, on this Device.
    fileprivate func setDetails(_ id: String, _ details: PDFDetails) throws {
        try setDetails(
            id: id, title: details.title, author: details.author, pageCount: UInt32(clamping: details.pageCount))
    }
}

extension Date {
    /// This time as the core takes it: whole milliseconds since the Unix epoch, none before.
    fileprivate var millisecondsSince1970: UInt64 { UInt64(max(0, timeIntervalSince1970 * 1000).rounded()) }
}
