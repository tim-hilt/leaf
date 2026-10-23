import Foundation
import LeafCore
import Security
import Testing

@testable import LeafPDF

/// Cloud Backing through `LibraryModel`: two models, each a Device, share a
/// directory as their cloud.
extension LibraryModelTests {
    private static let fast = SyncIntervals(debounceMs: 10, progressMs: 10, pollMs: 30, idlePollMs: 30)

    /// The shared cloud directory of this test.
    private var cloud: URL { root.deletingLastPathComponent().appending(path: "\(root.lastPathComponent)-cloud") }

    /// A second Device with a Library of its own.
    private func openOtherDevice(
        iCloudDrive: ICloudDrive = .system, googleDrive: GoogleDrive = .system
    ) throws -> LibraryModel {
        let name = "\(root.lastPathComponent)-other"
        let parent = root.deletingLastPathComponent()
        let defaults = UserDefaults(suiteName: name)!
        return try LibraryModel(
            root: parent.appending(path: name, directoryHint: .isDirectory),
            coversFolder: parent.appending(path: "\(name)-covers"), defaults: defaults,
            credentials: CloudCredentials(defaults: defaults, service: "leafpdf-test-\(name)"),
            iCloudDrive: iCloudDrive, googleDrive: googleDrive, syncIntervals: Self.fast
        )
    }

    private func ids(_ library: LibraryModel) -> [String] { library.documents.map(\.id) }

    /// True once `condition` holds, within 5 s.
    private func eventually(_ condition: @MainActor () -> Bool) async throws -> Bool {
        for _ in 0..<500 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        return condition()
    }

    /// `eventually` for a condition that needs to wait for the core.
    private func eventuallyAsync(_ condition: @MainActor () async -> Bool) async throws -> Bool {
        for _ in 0..<500 {
            if await condition() { return true }
            try await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }

    private func importedID(_ library: LibraryModel, titled title: String) async throws -> String {
        guard
            case .opened(let document) = await library.import(try writePDF(named: "\(title).pdf", metadataTitle: title))
        else { throw ImportFailure() }
        return document.id
    }

    private struct ImportFailure: Error {}

    @Test func cloudBackingIsOffUntilConnected() throws {
        let library = try openLibrary()

        #expect(library.connection == nil)
    }

    @Test func anImportOnOneDeviceAppearsOnTheOther() async throws {
        let (a, b) = (try openLibrary(syncIntervals: Self.fast), try openOtherDevice())
        try await a.connect(directory: cloud)
        try await b.connect(directory: cloud)

        let id = try await importedID(a, titled: "Paper")

        #expect(try await eventually { ids(b) == [id] })
        #expect(b.documents.first?.fileName.hasSuffix(".pdf") == true)
        #expect(try await eventually { b.documents.first?.title == "Paper" })
    }

    @Test func aRemoveOnOneDeviceRemovesTheDocumentOnTheOther() async throws {
        let (a, b) = (try openLibrary(syncIntervals: Self.fast), try openOtherDevice())
        try await a.connect(directory: cloud)
        try await b.connect(directory: cloud)
        let id = try await importedID(a, titled: "Paper")
        #expect(try await eventually { ids(b) == [id] })

        a.remove(a.documents[0])

        #expect(try await eventually { b.documents.isEmpty })
    }

    @Test func aDocumentRemovedOnAnotherDeviceClosesItsTab() async throws {
        let (a, b, _) = try await twoDevicesWithADocument()
        let tabs = Tabs(defaults: UserDefaults(suiteName: UUID().uuidString)!, library: b.documents)
        tabs.open(b.documents)

        a.remove(try #require(a.documents.first))

        #expect(try await eventually { b.documents.isEmpty })
        tabs.keep(onlyIn: b.documents)
        #expect(tabs.openIDs.isEmpty)
        #expect(!tabs.isShowingReader)
    }

    @Test func connectingMergesTheLibrariesOfBothDevices() async throws {
        let (a, b) = (try openLibrary(syncIntervals: Self.fast), try openOtherDevice())
        let onA = try await importedID(a, titled: "On A")
        let onB = try await importedID(b, titled: "On B")

        try await a.connect(directory: cloud)
        try await b.connect(directory: cloud)

        let both = Set([onA, onB])
        #expect(try await eventually { Set(ids(a)) == both && Set(ids(b)) == both })
    }

    @Test func connectingShowsTheCloudProviderAndTheSyncStatus() async throws {
        let library = try openLibrary(syncIntervals: Self.fast)

        try await library.connect(directory: cloud)

        #expect(library.connection == CloudConnection(provider: .webDAV, detail: cloud.path))
        #expect(
            try await eventually {
                if case .synced = library.syncState { true } else { false }
            })
    }

    @Test func disconnectingStopsSyncingAndKeepsTheLibrary() async throws {
        let (a, b) = (try openLibrary(syncIntervals: Self.fast), try openOtherDevice())
        try await a.connect(directory: cloud)
        try await b.connect(directory: cloud)
        let first = try await importedID(a, titled: "First")
        #expect(try await eventually { ids(b) == [first] })

        await b.disconnect()
        _ = try await importedID(a, titled: "Second")
        try await Task.sleep(for: .milliseconds(300))

        #expect(b.connection == nil)
        #expect(ids(b) == [first])
    }

    @Test func reconnectingSyncsWhatChangedWhileDisconnected() async throws {
        let (a, b) = (try openLibrary(syncIntervals: Self.fast), try openOtherDevice())
        try await a.connect(directory: cloud)
        try await b.connect(directory: cloud)
        await b.disconnect()
        let onA = try await importedID(a, titled: "On A")
        let onB = try await importedID(b, titled: "On B")

        try await b.connect(directory: cloud)

        let both = Set([onA, onB])
        #expect(try await eventually { Set(ids(a)) == both && Set(ids(b)) == both })
    }

    @Test func aConnectionToAnUnreachableServerFailsAndLeavesCloudBackingOff() async throws {
        let library = try openLibrary()

        await #expect(throws: ConnectError.Unreachable) {
            try await library.connect(url: "https://127.0.0.1:1", username: "reader", password: "secret")
        }
        #expect(library.connection == nil)
        #expect(credentials.load() == nil)
    }

    @Test func aURLWithoutHTTPSIsRefusedBeforeAnythingIsSent() async throws {
        let library = try openLibrary()

        await #expect(throws: ConnectError.NotHttps) {
            try await library.connect(url: "http://example.com", username: "reader", password: "secret")
        }
        #expect(library.connection == nil)
    }

    @Test func connectErrorsSayWhatToFix() {
        #expect(ConnectError.WrongCredentials.message == "Wrong username or password")
        #expect(ConnectError.Unreachable.message == "Server not reachable")
        #expect(ConnectError.NotHttps.message == "URL must start with https://")
        #expect(ConnectError.NotWebDav.message == "Not a WebDAV server")
        #expect(ConnectError.AccessDenied.message == "Access denied")
        #expect(ConnectError.ICloudDriveUnavailable.message == "Turn on iCloud Drive in Settings")
        #expect(ConnectError.WrongFolder.message == "Choose iCloud Drive")
        #expect(ConnectError.UnsupportedAccount.message == "Only personal accounts are supported")
    }

    @Test func cancellingSaysNothing() {
        #expect(ConnectError.Cancelled.message == nil)
    }

    @Test func eachCloudProviderHasANameAnIconAndALabelForWhatSettingsShows() {
        #expect(CloudProvider.allCases == [.webDAV, .iCloudDrive, .googleDrive])
        #expect(CloudProvider.webDAV.name == "WebDAV")
        #expect(CloudProvider.webDAV.icon == .symbol("server.rack"))
        #expect(CloudProvider.webDAV.detailLabel == "Server")
        #expect(CloudProvider.iCloudDrive.name == "iCloud Drive")
        #expect(CloudProvider.iCloudDrive.icon == .symbol("icloud"))
        #expect(CloudProvider.iCloudDrive.detailLabel == "Folder")
        #expect(CloudProvider.googleDrive.name == "Google Drive")
        #expect(CloudProvider.googleDrive.icon == .logo("GoogleDrive"))
        #expect(CloudProvider.googleDrive.detailLabel == "Account")
    }

    @Test func theGoogleDriveLogoIsInTheApp() {
        let app = Bundle(for: LibraryModel.self)
        #if os(macOS)
            #expect(app.image(forResource: "GoogleDrive") != nil)
        #else
            #expect(UIImage(named: "GoogleDrive", in: app, compatibleWith: nil) != nil)
        #endif
    }

    // MARK: iCloud Drive

    /// Stands in for the system's iCloud Drive: a folder of this test, which can be turned off.
    private final class FakeICloudDrive: @unchecked Sendable {
        let root: URL
        private let lock = NSLock()
        private var available = true
        private var requested: [URL] = []

        init(root: URL) throws {
            self.root = root
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        var isAvailable: Bool {
            get { lock.withLock { available } }
            set { lock.withLock { available = newValue } }
        }

        /// The files the Library asked the system to download.
        var downloads: [URL] { lock.withLock { requested } }

        var system: ICloudDrive {
            ICloudDrive(
                isAvailable: { self.isAvailable },
                isRoot: { $0.resolvingSymlinksInPath() == self.root.resolvingSymlinksInPath() },
                requestDownload: { url in self.lock.withLock { self.requested.append(url) } })
        }
    }

    private func fakeICloudDrive() throws -> FakeICloudDrive {
        try FakeICloudDrive(root: root.deletingLastPathComponent().appending(path: "\(root.lastPathComponent)-icloud"))
    }

    private static let iCloudConnection = CloudConnection(provider: .iCloudDrive, detail: "iCloud Drive/LeafPDF")

    @Test func connectingToICloudDriveShowsTheFolderAndSyncsThroughIt() async throws {
        let icloud = try fakeICloudDrive()
        let library = try openLibrary(syncIntervals: Self.fast, iCloudDrive: icloud.system)

        try await library.connectICloudDrive(granting: icloud.root)

        #expect(library.connection == Self.iCloudConnection)
        #expect(try await eventually { if case .synced = library.syncState { true } else { false } })
        #expect(FileManager.default.fileExists(atPath: icloud.root.appending(path: "LeafPDF").path))
    }

    @Test func anImportOnOneDeviceAppearsOnTheOtherThroughICloudDrive() async throws {
        let icloud = try fakeICloudDrive()
        let a = try openLibrary(syncIntervals: Self.fast, iCloudDrive: icloud.system)
        let b = try openOtherDevice(iCloudDrive: icloud.system)
        try await a.connectICloudDrive(granting: icloud.root)
        try await b.connectICloudDrive(granting: icloud.root)

        let id = try await importedID(a, titled: "Paper")

        #expect(try await eventually { ids(b) == [id] })
    }

    @Test func aFolderOtherThanICloudDriveIsRefused() async throws {
        let icloud = try fakeICloudDrive()
        let library = try openLibrary(iCloudDrive: icloud.system)
        let elsewhere = icloud.root.appending(path: "Documents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)

        await #expect(throws: ConnectError.WrongFolder) {
            try await library.connectICloudDrive(granting: elsewhere)
        }
        #expect(library.connection == nil)
        #expect(credentials.load() == nil)
    }

    @Test func connectingWhileICloudDriveIsOffAsksToTurnItOn() async throws {
        let icloud = try fakeICloudDrive()
        icloud.isAvailable = false
        let library = try openLibrary(iCloudDrive: icloud.system)

        await #expect(throws: ConnectError.ICloudDriveUnavailable) {
            try await library.connectICloudDrive(granting: icloud.root)
        }
        #expect(library.connection == nil)
        #expect(library.iCloudDriveIsAvailable == false)
    }

    @Test func theGrantSurvivesARelaunchAndIsForgottenOnDisconnect() async throws {
        let icloud = try fakeICloudDrive()
        let first = try openLibrary(syncIntervals: Self.fast, iCloudDrive: icloud.system)
        try await first.connectICloudDrive(granting: icloud.root)
        let id = try await importedID(first, titled: "Paper")
        let other = try openOtherDevice(iCloudDrive: icloud.system)
        try await other.connectICloudDrive(granting: icloud.root)
        #expect(try await eventually { ids(other) == [id] })

        // Relaunch.
        let library = try openLibrary(syncIntervals: Self.fast, iCloudDrive: icloud.system)
        #expect(library.connection == Self.iCloudConnection)
        let more = try await importedID(other, titled: "More")
        #expect(try await eventually { Set(ids(library)) == [id, more] })

        await library.disconnect()

        #expect(library.connection == nil)
        #expect(credentials.load() == nil)
        #expect(try openLibrary(iCloudDrive: icloud.system).connection == nil)
    }

    @Test func aLostGrantIsAccessLostAndReconnectingGrantsAgain() async throws {
        let icloud = try fakeICloudDrive()
        let first = try openLibrary(syncIntervals: Self.fast, iCloudDrive: icloud.system)
        try await first.connectICloudDrive(granting: icloud.root)
        try FileManager.default.removeItem(at: icloud.root)

        let library = try openLibrary(syncIntervals: Self.fast, iCloudDrive: icloud.system)

        #expect(library.connection == Self.iCloudConnection)
        #expect(library.syncState == .accessLost)
        #expect(library.syncIndicator == .failed(canRetry: false))
        try FileManager.default.createDirectory(at: icloud.root, withIntermediateDirectories: true)
        try await library.connectICloudDrive(granting: icloud.root)
        #expect(library.connection == Self.iCloudConnection)
        #expect(try await eventually { if case .synced = library.syncState { true } else { false } })
        #expect(try openLibrary(syncIntervals: Self.fast, iCloudDrive: icloud.system).syncState != .accessLost)
    }

    @Test func iCloudDriveTurnedOffIsAccessLostOnLaunchAndWhenTheAppReturns() async throws {
        let icloud = try fakeICloudDrive()
        let first = try openLibrary(syncIntervals: Self.fast, iCloudDrive: icloud.system)
        try await first.connectICloudDrive(granting: icloud.root)
        #expect(try await eventually { if case .synced = first.syncState { true } else { false } })

        icloud.isAvailable = false
        first.foreground()
        #expect(first.syncState == .accessLost)
        try await Task.sleep(for: .milliseconds(200))
        #expect(first.syncState == .accessLost)

        let relaunched = try openLibrary(syncIntervals: Self.fast, iCloudDrive: icloud.system)
        #expect(relaunched.connection == Self.iCloudConnection)
        #expect(relaunched.syncState == .accessLost)

        icloud.isAvailable = true
        try await relaunched.connectICloudDrive(granting: icloud.root)
        #expect(try await eventually { if case .synced = relaunched.syncState { true } else { false } })
    }

    @Test func filesICloudHasNotDownloadedYetAreRequested() async throws {
        let icloud = try fakeICloudDrive()
        let remote = icloud.root.appending(path: "LeafPDF/v1", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        try Data().write(to: remote.appending(path: ".chunk.icloud"))
        let library = try openLibrary(syncIntervals: Self.fast, iCloudDrive: icloud.system)

        try await library.connectICloudDrive(granting: icloud.root)

        #expect(
            try await eventually {
                icloud.downloads.map(\.lastPathComponent).contains("chunk")
            })
    }

    @Test func onlyICloudDrivesOwnRootCountsAsICloudDrive() {
        let root = "/Users/a/Library/Mobile Documents/com~apple~CloudDocs"
        #expect(ICloudDrive.system.isRoot(URL(filePath: root)))
        #expect(ICloudDrive.system.isRoot(URL(filePath: root, directoryHint: .isDirectory)))
        #expect(!ICloudDrive.system.isRoot(URL(filePath: root + "/LeafPDF")))
        #expect(!ICloudDrive.system.isRoot(URL(filePath: "/Users/a/Library/Mobile Documents")))
        #expect(!ICloudDrive.system.isRoot(URL(filePath: "/Users/a/Documents")))
    }

    @Test func theICloudDriveGrantIsKeptAndTheLatestConnectionWins() {
        let bookmark = Data([1, 2, 3])
        credentials.save(.webDAV(WebDAVAccount(url: "https://a.example", username: "a", password: "1")))

        credentials.save(.iCloudDrive(bookmark: bookmark))

        #expect(credentials.load() == .iCloudDrive(bookmark: bookmark))
        credentials.save(.webDAV(WebDAVAccount(url: "https://b.example", username: "b", password: "2")))
        #expect(credentials.load() == .webDAV(WebDAVAccount(url: "https://b.example", username: "b", password: "2")))
        credentials.save(.iCloudDrive(bookmark: bookmark))
        credentials.forget()
        #expect(credentials.load() == nil)
    }

    // MARK: Google Drive

    /// Stands in for the core's Google Drive: the shared cloud directory is the Drive.
    private final class FakeGoogleDrive: @unchecked Sendable {
        let cloud: URL
        private let lock = NSLock()
        private var state = State()

        private struct State {
            var account = "reader@example.com"
            var refusal: ConnectError?
            var rotatesWhileConnecting: String?
            var tokensGiven: [String] = []
            var tokens: RefreshTokenObserver?
        }

        init(cloud: URL) { self.cloud = cloud }

        var account: String {
            get { lock.withLock { state.account } }
            set { lock.withLock { state.account = newValue } }
        }

        /// Connecting and reconnecting fail like this, as when Google refuses the token.
        var refusal: ConnectError? {
            get { lock.withLock { state.refusal } }
            set { lock.withLock { state.refusal = newValue } }
        }

        /// Google rotates the refresh token while Connecting.
        var rotatesWhileConnecting: String? {
            get { lock.withLock { state.rotatesWhileConnecting } }
            set { lock.withLock { state.rotatesWhileConnecting = newValue } }
        }

        /// The refresh tokens that connecting, resuming and reconnecting got.
        var tokensGiven: [String] { lock.withLock { state.tokensGiven } }

        /// Google rotates the refresh token of the running Connection.
        func rotate(to token: String) { lock.withLock { state.tokens }?.newRefreshToken(token: token) }

        private func take(_ token: String, _ tokens: RefreshTokenObserver) throws -> String {
            try lock.withLock {
                if let refusal = state.refusal { throw refusal }
                state.tokensGiven.append(token)
                state.tokens = tokens
                return state.account
            }
        }

        var drive: GoogleDrive {
            GoogleDrive(
                connect: { core, token, tokens, observer, intervals in
                    let account = try self.take(token, tokens)
                    try core.connectDirectory(path: self.cloud.path, observer: observer, intervals: intervals)
                    if let rotated = self.rotatesWhileConnecting { tokens.newRefreshToken(token: rotated) }
                    return account
                },
                resume: { core, token, tokens, observer, intervals in
                    _ = try? self.take(token, tokens)
                    try? core.connectDirectory(path: self.cloud.path, observer: observer, intervals: intervals)
                },
                reconnect: { _, token, tokens in try self.take(token, tokens) })
        }
    }

    private static func googleConnection(_ account: String = "reader@example.com") -> CloudConnection {
        CloudConnection(provider: .googleDrive, detail: account)
    }

    private func isSynced(_ library: LibraryModel) -> Bool {
        if case .synced = library.syncState { true } else { false }
    }

    @Test func connectingToGoogleDriveShowsTheAccountAndSyncsThroughIt() async throws {
        let google = FakeGoogleDrive(cloud: cloud)
        let a = try openLibrary(syncIntervals: Self.fast, googleDrive: google.drive)
        let b = try openOtherDevice(googleDrive: google.drive)
        try await a.connectGoogleDrive(refreshToken: "token")
        try await b.connectGoogleDrive(refreshToken: "token")

        let id = try await importedID(a, titled: "Paper")

        #expect(a.connection == Self.googleConnection())
        #expect(try await eventually { isSynced(a) })
        #expect(try await eventually { ids(b) == [id] })
    }

    @Test func theTokenAndAccountSurviveARelaunchAndAreForgottenOnDisconnect() async throws {
        let google = FakeGoogleDrive(cloud: cloud)
        let first = try openLibrary(syncIntervals: Self.fast, googleDrive: google.drive)
        try await first.connectGoogleDrive(refreshToken: "token")
        #expect(credentials.load() == .googleDrive(refreshToken: "token", account: "reader@example.com"))

        // Relaunch: Connected again with the saved token, without signing in.
        let library = try openLibrary(syncIntervals: Self.fast, googleDrive: google.drive)
        #expect(library.connection == Self.googleConnection())
        #expect(google.tokensGiven == ["token", "token"])
        #expect(try await eventually { isSynced(library) })

        await library.disconnect()

        #expect(library.connection == nil)
        #expect(credentials.load() == nil)
        #expect(try openLibrary(googleDrive: google.drive).connection == nil)
    }

    @Test func aRotatedRefreshTokenReplacesTheSavedOne() async throws {
        let google = FakeGoogleDrive(cloud: cloud)
        let library = try openLibrary(syncIntervals: Self.fast, googleDrive: google.drive)
        try await library.connectGoogleDrive(refreshToken: "token")

        google.rotate(to: "rotated")

        #expect(
            try await eventually {
                credentials.load() == .googleDrive(refreshToken: "rotated", account: "reader@example.com")
            })
        // A relaunch resumes with it.
        _ = try openLibrary(googleDrive: google.drive)
        #expect(google.tokensGiven.last == "rotated")
    }

    @Test func aRefreshTokenRotatedWhileConnectingIsTheOneSaved() async throws {
        let google = FakeGoogleDrive(cloud: cloud)
        google.rotatesWhileConnecting = "rotated"
        let library = try openLibrary(syncIntervals: Self.fast, googleDrive: google.drive)

        try await library.connectGoogleDrive(refreshToken: "token")
        try await Task.sleep(for: .milliseconds(100))

        #expect(credentials.load() == .googleDrive(refreshToken: "rotated", account: "reader@example.com"))
    }

    @Test func aTokenGoogleRefusesLeavesCloudBackingOff() async throws {
        let google = FakeGoogleDrive(cloud: cloud)
        google.refusal = .AccessDenied
        let library = try openLibrary(googleDrive: google.drive)

        await #expect(throws: ConnectError.AccessDenied) {
            try await library.connectGoogleDrive(refreshToken: "token")
        }

        #expect(library.connection == nil)
        #expect(credentials.load() == nil)
    }

    @Test func lostAccessToGoogleDriveIsReconnectedWithANewSignIn() async throws {
        let google = FakeGoogleDrive(cloud: cloud)
        let library = try openLibrary(syncIntervals: Self.fast, googleDrive: google.drive)
        try await library.connectGoogleDrive(refreshToken: "old")
        #expect(try await eventually { isSynced(library) })
        // Google refuses access, as after the user revoked it.
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: cloud.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cloud.path) }
        #expect(try await eventually { library.syncState == .accessLost })
        #expect(library.syncIndicator == .failed(canRetry: false))

        google.account = "other@example.com"
        try await library.reconnectGoogleDrive(refreshToken: "new")

        #expect(library.connection == Self.googleConnection("other@example.com"))
        #expect(credentials.load() == .googleDrive(refreshToken: "new", account: "other@example.com"))
    }

    @Test func reconnectingWithATokenGoogleRefusesLeavesTheConnectionAndTheSavedTokenAlone() async throws {
        let google = FakeGoogleDrive(cloud: cloud)
        let library = try openLibrary(syncIntervals: Self.fast, googleDrive: google.drive)
        try await library.connectGoogleDrive(refreshToken: "old")
        google.refusal = .AccessDenied

        await #expect(throws: ConnectError.AccessDenied) {
            try await library.reconnectGoogleDrive(refreshToken: "new")
        }

        #expect(library.connection == Self.googleConnection())
        #expect(credentials.load() == .googleDrive(refreshToken: "old", account: "reader@example.com"))
    }

    @Test func reconnectingGoogleDriveWithoutAGoogleDriveConnectionDoesNothing() async throws {
        let google = FakeGoogleDrive(cloud: cloud)
        let library = try openLibrary(syncIntervals: Self.fast, googleDrive: google.drive)
        try await library.connect(directory: cloud)

        try await library.reconnectGoogleDrive(refreshToken: "new")

        #expect(google.tokensGiven.isEmpty)
        #expect(credentials.load() == nil)
    }

    @Test func theGoogleTokenIsKeptAndTheLatestConnectionWins() {
        let google = CloudCredential.googleDrive(refreshToken: "token", account: "a@example.com")
        let webDAV = WebDAVAccount(url: "https://a.example", username: "a", password: "1")
        credentials.save(.webDAV(webDAV))

        #expect(credentials.save(google))

        #expect(credentials.load() == google)
        credentials.save(.webDAV(webDAV))
        #expect(credentials.load() == .webDAV(webDAV))
        credentials.save(google)
        credentials.forget()
        #expect(credentials.load() == nil)
    }

    @Test func aSavedAccountWithoutItsTokenIsNotConnected() {
        defaults.set("a@example.com", forKey: "cloud.google.account")

        #expect(credentials.load() == nil)
    }

    @Test func googleDriveSettingsSaySyncIsFull() {
        #expect(Status.full.line(for: .googleDrive) == "Google Drive is full")
        #expect(Status.accessLost.line(for: .googleDrive) == "Access lost")
    }

    // MARK: Google sign-in

    private func signIn() -> GoogleSignIn {
        // The verifier and challenge of RFC 7636, appendix B.
        GoogleSignIn(
            clientID: "123-abc.apps.googleusercontent.com",
            redirectScheme: "com.googleusercontent.apps.123-abc",
            verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk", state: "xyz")
    }

    @Test func theSignInPageAsksForTheFilesLeafPDFCreatesAndProvesItsCode() throws {
        let signIn = signIn()
        let page = try #require(URLComponents(url: signIn.url, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (page.queryItems ?? []).map { ($0.name, $0.value) })

        #expect(page.host == "accounts.google.com")
        #expect(query["scope"] == "https://www.googleapis.com/auth/drive.file")
        #expect(query["client_id"] == "123-abc.apps.googleusercontent.com")
        #expect(query["redirect_uri"] == "com.googleusercontent.apps.123-abc:/oauth2redirect")
        #expect(query["code_challenge"] == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        #expect(query["code_challenge_method"] == "S256")
        #expect(query["access_type"] == "offline")
    }

    @Test func theSignInRedirectGivesTheCodeAndDecliningCancelsSilently() throws {
        let signIn = signIn()
        let redirect = "com.googleusercontent.apps.123-abc:/oauth2redirect"

        #expect(try signIn.code(from: URL(string: "\(redirect)?state=xyz&code=4%2F0Abc")!) == "4/0Abc")
        #expect(throws: ConnectError.Cancelled) {
            try signIn.code(from: URL(string: "\(redirect)?state=xyz&error=access_denied")!)
        }
        #expect(throws: ConnectError.AccessDenied) {
            try signIn.code(from: URL(string: "\(redirect)?state=other&code=4%2F0Abc")!)
        }
    }

    @Test func aConsentWithoutThePermissionForDriveFailsAndSaysWhy() throws {
        let granted = Data(#"{"refresh_token": "r", "scope": "https://www.googleapis.com/auth/drive.file"}"#.utf8)
        let declined = Data(#"{"refresh_token": "r", "scope": "openid"}"#.utf8)

        #expect(try GoogleSignIn.refreshToken(fromTokenResponse: granted) == "r")
        #expect(throws: GoogleSignInError.missingPermission) {
            try GoogleSignIn.refreshToken(fromTokenResponse: declined)
        }
        #expect(
            GoogleSignInError.missingPermission.errorDescription
                == "Allow LeafPDF to access its files in Google Drive")
    }

    @Test func credentialsSurviveARelaunchAndAreGoneAfterDisconnect() async throws {
        let account = WebDAVAccount(url: "https://127.0.0.1:1", username: "reader", password: "secret")
        #expect(credentials.save(.webDAV(account)))

        // Relaunch: Connected again without contacting the server, which is down.
        let library = try openLibrary(syncIntervals: Self.fast)
        #expect(library.connection == CloudConnection(provider: .webDAV, detail: account.url))
        #expect(try await eventually { library.syncState == .offline })

        await library.disconnect()

        #expect(library.connection == nil)
        #expect(credentials.load() == nil)
        #expect(try openLibrary().connection == nil)
    }

    @Test func savedCredentialsHoldOnlyTheLatestConnection() {
        credentials.save(.webDAV(WebDAVAccount(url: "https://a.example", username: "a", password: "1")))
        credentials.save(.webDAV(WebDAVAccount(url: "https://b.example", username: "b", password: "2")))

        #expect(credentials.load() == .webDAV(WebDAVAccount(url: "https://b.example", username: "b", password: "2")))
        credentials.forget()
        #expect(credentials.load() == nil)
    }

    /// What LeafPDF saved before Cloud Providers had names: the URL and username
    /// in the defaults, the password in the Keychain.
    @Test func credentialsSavedBeforeCloudProvidersHadNamesStillLoad() throws {
        let service = "leafpdf-test-\(root.lastPathComponent)"
        defaults.set("https://old.example", forKey: "cloud.webdav.url")
        defaults.set("old", forKey: "cloud.webdav.username")
        let item: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword, kSecAttrService: service,
            kSecAttrAccount: "WebDAV password", kSecValueData: Data("pw".utf8),
        ]
        #expect(SecItemAdd(item as CFDictionary, nil) == errSecSuccess)
        defer { credentials.forget() }

        #expect(
            credentials.load() == .webDAV(WebDAVAccount(url: "https://old.example", username: "old", password: "pw")))
    }

    @Test func theTransferBarSaysHowManyDocumentsAreDoneAndIsGoneAtTheEnd() {
        #expect(FileTransfer(done: 0, total: 120)?.text == "Syncing 0 of 120 Documents")
        #expect(FileTransfer(done: 12, total: 120)?.text == "Syncing 12 of 120 Documents")
        #expect(FileTransfer(done: 120, total: 120) == nil)
    }

    @Test func theTransferBarCountsUpDuringAMultiFileSyncAndIsGoneAfterwards() async throws {
        let (a, b) = (try openLibrary(syncIntervals: Self.fast), try openOtherDevice())
        let count = 8
        for number in 0..<count { _ = try await importedID(a, titled: "Doc \(number)") }
        try await a.connect(directory: cloud)
        // All Files are in the cloud, so B downloads them in one Sync.
        #expect(
            try await eventually {
                if case .synced = a.syncState { true } else { false }
            })

        try await b.connect(directory: cloud)
        var seen: [Int] = []
        for _ in 0..<5000 {
            if let done = b.transfer?.done, seen.last != done { seen.append(done) }
            if b.documents.count == count && b.transfer == nil { break }
            try await Task.sleep(for: .milliseconds(1))
        }

        #expect(!seen.isEmpty)
        #expect(seen == seen.sorted())
        #expect(b.documents.count == count)
        #expect(b.transfer == nil)
    }

    @Test func syncsOfStateOnlyShowNoTransferBar() async throws {
        let (a, b, _) = try await twoDevicesWithADocument()
        let onA = try #require(a.documents.first)
        let onB = try #require(b.documents.first)
        let before = b.markupRevision(of: onB)

        _ = try #require(await a.addHighlight(anchor, quotedText: quote, to: onA))
        await a.saveProgress(place, of: onA, at: lastRead)
        var bars: [FileTransfer] = []
        for _ in 0..<500 where b.markupRevision(of: onB) == before || b.documents.first?.place == nil {
            bars += [a.transfer, b.transfer].compactMap { $0 }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(b.markupRevision(of: onB) > before)
        #expect(bars.isEmpty)
    }

    @Test func theStatusLineSaysHowSyncStands() {
        let now = Date(timeIntervalSince1970: 1_000_000)

        func synced(_ secondsAgo: Double) -> Status {
            .synced(at: UInt64(now.addingTimeInterval(-secondsAgo).timeIntervalSince1970 * 1000))
        }

        #expect(Status.syncing.line(for: .webDAV, now: now) == "Syncing…")
        #expect(Status.offline.line(for: .webDAV, now: now) == "Offline")
        #expect(synced(5).line(for: .webDAV, now: now) == "Synced just now")
        #expect(synced(300).line(for: .webDAV, now: now).hasPrefix("Synced "))
        #expect(synced(300).line(for: .webDAV, now: now) != "Synced just now")
    }

    @Test func theStatusLineNamesTheBlockedStates() {
        #expect(Status.accessLost.line(for: .webDAV) == "Access lost")
        #expect(Status.full.line(for: .webDAV) == "WebDAV is full")
        #expect(Status.updateNeeded.line(for: .webDAV) == "Update LeafPDF to keep syncing")
    }

    @Test func aFullCloudIsBlockedInTheGalleryAndNotRetryable() {
        #expect(SyncIndicator(.full) == .failed(canRetry: false))
    }

    @Test func theIndicatorShowsHowSyncStandsWhileConnected() async throws {
        // Offline: the server is down. Trying again can help.
        let account = WebDAVAccount(url: "https://127.0.0.1:1", username: "reader", password: "secret")
        #expect(credentials.save(.webDAV(account)))
        let offline = try openLibrary(syncIntervals: Self.fast)
        #expect(try await eventually { offline.syncState == .offline })
        #expect(offline.syncIndicator == .failed(canRetry: true))
        await offline.disconnect()

        // Not Connected.
        let library = try openLibrary(syncIntervals: Self.fast)
        #expect(library.syncIndicator == nil)

        // Blocked: the cloud refuses access, as a server does with a changed password.
        try await library.connect(directory: cloud)
        #expect(try await eventually { if case .synced = library.syncState { true } else { false } })
        if case .synced(let at) = library.syncState {
            #expect(library.syncIndicator == .synced(Date(milliseconds: at)))
        }
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: cloud.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cloud.path) }
        #expect(try await eventually { library.syncState == .accessLost })
        #expect(library.syncIndicator == .failed(canRetry: false))
        #expect(library.connection != nil)

        await library.disconnect()
        #expect(library.syncIndicator == nil)
    }

    @Test func theIndicatorsMessageSaysWhenSyncLastSucceeded() {
        let date = Date(timeIntervalSince1970: 1_000_000)
        let time = date.formatted(date: .omitted, time: .shortened)
        let day = date.formatted(date: .abbreviated, time: .omitted)

        #expect(SyncIndicator.synced(date).message == "Last synced at \(time) \(day)")
        #expect(SyncIndicator.syncing.message == "Syncing…")
        #expect(SyncIndicator.failed(canRetry: true).message == "Error while syncing")
        #expect(SyncIndicator.failed(canRetry: false).message == "Error while syncing")
    }

    @Test func reconnectingWithAPasswordThatTheServerCantCheckLeavesTheConnectionAndTheSavedPasswordAlone() async throws
    {
        let account = WebDAVAccount(url: "https://127.0.0.1:1", username: "reader", password: "old")
        #expect(credentials.save(.webDAV(account)))
        let library = try openLibrary(syncIntervals: Self.fast)

        await #expect(throws: ConnectError.Unreachable) { try await library.reconnect(password: "new") }

        #expect(library.connection == CloudConnection(provider: .webDAV, detail: account.url))
        #expect(credentials.load() == .webDAV(account))
    }

    @Test func reconnectingWithoutASavedConnectionDoesNothing() async throws {
        let library = try openLibrary(syncIntervals: Self.fast)
        try await library.connect(directory: cloud)

        try await library.reconnect(password: "new")

        #expect(library.connection == CloudConnection(provider: .webDAV, detail: cloud.path))
        #expect(credentials.load() == nil)
    }

    /// Two connected Devices that both hold one Document, imported on the first.
    private func twoDevicesWithADocument() async throws -> (LibraryModel, LibraryModel, String) {
        let (a, b) = (try openLibrary(syncIntervals: Self.fast), try openOtherDevice())
        try await a.connect(directory: cloud)
        try await b.connect(directory: cloud)
        let id = try await importedID(a, titled: "Paper")
        #expect(try await eventually { ids(b) == [id] })
        return (a, b, id)
    }

    @Test func aHighlightAddedOnOneDeviceAppearsOnTheOtherAndTheReaderIsTold() async throws {
        let (a, b, id) = try await twoDevicesWithADocument()
        let onB = try #require(b.documents.first)
        let before = b.markupRevision(of: onB)

        let onA = try #require(a.documents.first)
        let added = try #require(await a.addHighlight(anchor, quotedText: quote, to: onA))

        #expect(try await eventually { b.markupRevision(of: onB) > before })
        #expect(await b.markup(of: onB).highlights == [added])
        #expect(onB.id == id)
    }

    @Test func aNoteAndAPageNoteAddedOnOneDeviceAppearOnTheOther() async throws {
        let (a, b, _) = try await twoDevicesWithADocument()
        let onA = try #require(a.documents.first)
        let onB = try #require(b.documents.first)
        let highlight = try #require(await a.addHighlight(anchor, quotedText: quote, to: onA))
        await a.setNote("worth a note", of: highlight, in: onA)
        let pageNote = try #require(await a.addPageNote(at: place, to: onA))
        await a.setText("page note", of: pageNote, in: onA)

        #expect(
            try await eventuallyAsync {
                let note = await b.markup(of: onB).highlights.first?.note
                let pageNotes = await b.markup(of: onB).pageNotes
                return note == "worth a note" && pageNotes.count == 1
            })
    }

    @Test func incomingReadingProgressShowsInTheGalleryButNeverMovesAnOpenReader() async throws {
        let (a, b, _) = try await twoDevicesWithADocument()
        // What the Reader of B holds: the Document as it was opened.
        let open = try #require(b.documents.first)
        await b.saveProgress(place, of: open, at: lastRead)
        let opened = try #require(b.documents.first)

        await a.saveProgress(
            Place.pdf(pageIndex: 3, point: .zero), of: try #require(a.documents.first),
            at: lastRead.addingTimeInterval(60))

        #expect(try await eventually { b.documents.first?.place?.pageIndex == 3 })
        #expect(opened.place == place)
        // Its next save carries the newer Last Read, so it wins everywhere.
        let later = lastRead.addingTimeInterval(120)
        await b.saveProgress(place, of: opened, at: later)
        #expect(try await eventually { a.documents.first?.lastRead == later })
        #expect(a.documents.first?.place == place)
    }

    @Test func customColorsAndTheDefaultHighlightColorSyncBetweenDevices() async throws {
        let (a, b) = (try openLibrary(syncIntervals: Self.fast), try openOtherDevice())
        try await a.connect(directory: cloud)
        try await b.connect(directory: cloud)

        let custom = try #require(await a.addCustomColor(RGB(0.2, 0.4, 0.6)))
        await a.setDefaultHighlightColor(custom)

        #expect(try await eventually { b.highlightColors.contains(custom) && b.defaultHighlightColor == custom })
        await b.removeCustomColor(custom)
        #expect(try await eventually { !a.highlightColors.contains(custom) && a.defaultHighlightColor.id == "Yellow" })
    }
}
