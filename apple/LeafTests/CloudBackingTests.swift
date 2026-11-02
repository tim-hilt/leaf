import Foundation
import LeafCore
import Security
import Testing

@testable import Leaf

#if canImport(UIKit)
    import UIKit
#endif

/// The Cloud Providers behind OAuth.
private let oauthProviders: [CloudProvider] = [.googleDrive, .oneDrive]

/// Cloud Backing through `CloudBackingModel`: each Device is a Library with its
/// Cloud Backing, sharing one core Library; the Devices share a directory as
/// their cloud.
@MainActor @Suite struct CloudBackingTests {
    private static let fast = SyncIntervals(debounceMs: 10, progressMs: 10, pollMs: 30, idlePollMs: 30)

    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    /// The shared cloud directory of this test.
    private var cloudDirectory: URL {
        root.deletingLastPathComponent().appending(path: "\(root.lastPathComponent)-cloud")
    }
    /// This Device's user defaults: one suite per test.
    private var defaults: UserDefaults { UserDefaults(suiteName: root.lastPathComponent)! }
    /// This Device's Cloud Backing credentials: the Keychain item is per test too.
    private var credentials: CloudCredentials {
        CloudCredentials(defaults: defaults, service: "leaf-test-\(root.lastPathComponent)")
    }

    /// A Device: its Library and its Cloud Backing.
    private typealias Device = (library: LibraryModel, cloud: CloudBackingModel)

    /// A Device at `root`, with a `suffix` for a second one. Its Library and
    /// Cloud Backing share one core Library.
    private func openDevice(
        _ suffix: String = "", syncIntervals: SyncIntervals = .standard, iCloudDrive: ICloudDrive = .system,
        cloudCore: CloudCore = .system
    ) throws -> Device {
        let name = root.lastPathComponent + suffix
        let parent = root.deletingLastPathComponent()
        let defaults = UserDefaults(suiteName: name)!
        let core = try LeafCore.Library.open(root: parent.appending(path: name, directoryHint: .isDirectory).path)
        let library = LibraryModel(
            core: core, coversFolder: parent.appending(path: "\(name)-covers"), defaults: defaults)
        let credentials = CloudCredentials(defaults: defaults, service: "leaf-test-\(name)")
        let cloud = CloudBackingModel(
            core: core, library: library, credentials: credentials, iCloudDrive: iCloudDrive, cloudCore: cloudCore,
            syncIntervals: syncIntervals)
        return (library, cloud)
    }

    /// A second Device, which syncs fast.
    private func openOtherDevice(iCloudDrive: ICloudDrive = .system, cloudCore: CloudCore = .system) throws -> Device {
        try openDevice("-other", syncIntervals: Self.fast, iCloudDrive: iCloudDrive, cloudCore: cloudCore)
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
        let (_, cloud) = try openDevice()

        #expect(cloud.connection == nil)
    }

    @Test func anImportOnOneDeviceAppearsOnTheOther() async throws {
        let (a, b) = (try openDevice(syncIntervals: Self.fast), try openOtherDevice())
        try await a.cloud.connect(directory: cloudDirectory)
        try await b.cloud.connect(directory: cloudDirectory)

        let id = try await importedID(a.library, titled: "Paper")

        #expect(try await eventually { ids(b.library) == [id] })
        #expect(b.library.documents.first?.fileName.hasSuffix(".pdf") == true)
        #expect(try await eventually { b.library.documents.first?.title == "Paper" })
    }

    @Test func aRemoveOnOneDeviceRemovesTheDocumentOnTheOther() async throws {
        let (a, b) = (try openDevice(syncIntervals: Self.fast), try openOtherDevice())
        try await a.cloud.connect(directory: cloudDirectory)
        try await b.cloud.connect(directory: cloudDirectory)
        let id = try await importedID(a.library, titled: "Paper")
        #expect(try await eventually { ids(b.library) == [id] })

        await a.library.remove(a.library.documents[0])

        #expect(try await eventually { b.library.documents.isEmpty })
    }

    @Test func connectingMergesTheLibrariesOfBothDevices() async throws {
        let (a, b) = (try openDevice(syncIntervals: Self.fast), try openOtherDevice())
        let onA = try await importedID(a.library, titled: "On A")
        let onB = try await importedID(b.library, titled: "On B")

        try await a.cloud.connect(directory: cloudDirectory)
        try await b.cloud.connect(directory: cloudDirectory)

        let both = Set([onA, onB])
        #expect(try await eventually { Set(ids(a.library)) == both && Set(ids(b.library)) == both })
    }

    @Test func connectingShowsTheCloudProviderAndTheSyncStatus() async throws {
        let (_, cloud) = try openDevice(syncIntervals: Self.fast)

        try await cloud.connect(directory: cloudDirectory)

        #expect(cloud.connection == CloudConnection(provider: .webDAV, detail: cloudDirectory.path))
        #expect(
            try await eventually {
                if case .synced = cloud.syncState { true } else { false }
            })
    }

    @Test func disconnectingStopsSyncingAndKeepsTheLibrary() async throws {
        let (a, b) = (try openDevice(syncIntervals: Self.fast), try openOtherDevice())
        try await a.cloud.connect(directory: cloudDirectory)
        try await b.cloud.connect(directory: cloudDirectory)
        let first = try await importedID(a.library, titled: "First")
        #expect(try await eventually { ids(b.library) == [first] })

        await b.cloud.disconnect()
        _ = try await importedID(a.library, titled: "Second")
        try await Task.sleep(for: .milliseconds(300))

        #expect(b.cloud.connection == nil)
        #expect(ids(b.library) == [first])
    }

    @Test func reconnectingSyncsWhatChangedWhileDisconnected() async throws {
        let (a, b) = (try openDevice(syncIntervals: Self.fast), try openOtherDevice())
        try await a.cloud.connect(directory: cloudDirectory)
        try await b.cloud.connect(directory: cloudDirectory)
        await b.cloud.disconnect()
        let onA = try await importedID(a.library, titled: "On A")
        let onB = try await importedID(b.library, titled: "On B")

        try await b.cloud.connect(directory: cloudDirectory)

        let both = Set([onA, onB])
        #expect(try await eventually { Set(ids(a.library)) == both && Set(ids(b.library)) == both })
    }

    @Test func aConnectionToAnUnreachableServerFailsAndLeavesCloudBackingOff() async throws {
        let (_, cloud) = try openDevice()

        await #expect(throws: ConnectError.Unreachable) {
            try await cloud.connect(url: "https://127.0.0.1:1", username: "reader", password: "secret")
        }
        #expect(cloud.connection == nil)
        #expect(credentials.load() == nil)
    }

    @Test func aURLWithoutHTTPSIsRefusedBeforeAnythingIsSent() async throws {
        let (_, cloud) = try openDevice()

        await #expect(throws: ConnectError.NotHttps) {
            try await cloud.connect(url: "http://example.com", username: "reader", password: "secret")
        }
        #expect(cloud.connection == nil)
    }

    @Test func connectErrorsSayWhatToFix() {
        #expect(ConnectError.WrongCredentials.message == "Wrong username or password")
        #expect(ConnectError.Unreachable.message == "Server not reachable")
        #expect(ConnectError.NotHttps.message == "URL must start with https://")
        #expect(ConnectError.NotWebDav.message == "Not a WebDAV server")
        #expect(ConnectError.AccessDenied.message == "Access denied")
        #expect(ConnectError.ICloudDriveUnavailable.message == "Turn on iCloud Drive in Settings")
        #expect(ConnectError.WrongFolder.message == "Choose iCloud Drive")
        #expect(ConnectError.UnsupportedAccount.message == "Only personal Microsoft accounts are supported")
    }

    @Test func cancellingSaysNothing() {
        #expect(ConnectError.Cancelled.message == nil)
    }

    @Test func eachCloudProviderHasANameAnIconAndALabelForWhatSettingsShows() {
        #expect(CloudProvider.allCases == [.webDAV, .iCloudDrive, .googleDrive, .oneDrive])
        #expect(CloudProvider.webDAV.name == "WebDAV")
        #expect(CloudProvider.webDAV.icon == .symbol("server.rack"))
        #expect(CloudProvider.webDAV.detailLabel == "Server")
        #expect(CloudProvider.iCloudDrive.name == "iCloud Drive")
        #expect(CloudProvider.iCloudDrive.icon == .logo("ICloudDrive"))
        #expect(CloudProvider.iCloudDrive.detailLabel == "Folder")
        #expect(CloudProvider.googleDrive.name == "Google Drive")
        #expect(CloudProvider.googleDrive.icon == .logo("GoogleDrive"))
        #expect(CloudProvider.googleDrive.detailLabel == "Account")
        #expect(CloudProvider.oneDrive.name == "OneDrive")
        #expect(CloudProvider.oneDrive.icon == .logo("OneDrive"))
        #expect(CloudProvider.oneDrive.detailLabel == "Account")
    }

    @Test(arguments: ["GoogleDrive", "OneDrive"]) func theLogoIsInTheApp(name: String) {
        let app = Bundle(for: LibraryModel.self)
        #if os(macOS)
            #expect(app.image(forResource: name) != nil)
        #else
            #expect(UIImage(named: name, in: app, compatibleWith: nil) != nil)
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

    private static let iCloudConnection = CloudConnection(provider: .iCloudDrive, detail: "iCloud Drive/Leaf")

    @Test func connectingToICloudDriveShowsTheFolderAndSyncsThroughIt() async throws {
        let icloud = try fakeICloudDrive()
        let (_, cloud) = try openDevice(syncIntervals: Self.fast, iCloudDrive: icloud.system)

        try await cloud.connectICloudDrive(granting: icloud.root)

        #expect(cloud.connection == Self.iCloudConnection)
        #expect(try await eventually { if case .synced = cloud.syncState { true } else { false } })
        #expect(FileManager.default.fileExists(atPath: icloud.root.appending(path: "Leaf").path))
    }

    @Test func anImportOnOneDeviceAppearsOnTheOtherThroughICloudDrive() async throws {
        let icloud = try fakeICloudDrive()
        let a = try openDevice(syncIntervals: Self.fast, iCloudDrive: icloud.system)
        let b = try openOtherDevice(iCloudDrive: icloud.system)
        try await a.cloud.connectICloudDrive(granting: icloud.root)
        try await b.cloud.connectICloudDrive(granting: icloud.root)

        let id = try await importedID(a.library, titled: "Paper")

        #expect(try await eventually { ids(b.library) == [id] })
    }

    @Test func aFolderOtherThanICloudDriveIsRefused() async throws {
        let icloud = try fakeICloudDrive()
        let (_, cloud) = try openDevice(iCloudDrive: icloud.system)
        let elsewhere = icloud.root.appending(path: "Documents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)

        await #expect(throws: ConnectError.WrongFolder) {
            try await cloud.connectICloudDrive(granting: elsewhere)
        }
        #expect(cloud.connection == nil)
        #expect(credentials.load() == nil)
    }

    @Test func connectingWhileICloudDriveIsOffAsksToTurnItOn() async throws {
        let icloud = try fakeICloudDrive()
        icloud.isAvailable = false
        let (_, cloud) = try openDevice(iCloudDrive: icloud.system)

        await #expect(throws: ConnectError.ICloudDriveUnavailable) {
            try await cloud.connectICloudDrive(granting: icloud.root)
        }
        #expect(cloud.connection == nil)
        #expect(cloud.iCloudDriveIsAvailable == false)
    }

    @Test func theGrantSurvivesARelaunchAndIsForgottenOnDisconnect() async throws {
        let icloud = try fakeICloudDrive()
        let first = try openDevice(syncIntervals: Self.fast, iCloudDrive: icloud.system)
        try await first.cloud.connectICloudDrive(granting: icloud.root)
        let id = try await importedID(first.library, titled: "Paper")
        let other = try openOtherDevice(iCloudDrive: icloud.system)
        try await other.cloud.connectICloudDrive(granting: icloud.root)
        #expect(try await eventually { ids(other.library) == [id] })

        // Relaunch.
        let (library, cloud) = try openDevice(syncIntervals: Self.fast, iCloudDrive: icloud.system)
        #expect(cloud.connection == Self.iCloudConnection)
        let more = try await importedID(other.library, titled: "More")
        #expect(try await eventually { Set(ids(library)) == [id, more] })

        await cloud.disconnect()

        #expect(cloud.connection == nil)
        #expect(credentials.load() == nil)
        #expect(try openDevice(iCloudDrive: icloud.system).cloud.connection == nil)
    }

    @Test func aLostGrantIsAccessLostAndReconnectingGrantsAgain() async throws {
        let icloud = try fakeICloudDrive()
        let first = try openDevice(syncIntervals: Self.fast, iCloudDrive: icloud.system)
        try await first.cloud.connectICloudDrive(granting: icloud.root)
        try FileManager.default.removeItem(at: icloud.root)

        let (_, cloud) = try openDevice(syncIntervals: Self.fast, iCloudDrive: icloud.system)

        #expect(cloud.connection == Self.iCloudConnection)
        #expect(cloud.syncState == .accessLost)
        #expect(cloud.syncIndicator == .failed(canRetry: false))
        try FileManager.default.createDirectory(at: icloud.root, withIntermediateDirectories: true)
        try await cloud.connectICloudDrive(granting: icloud.root)
        #expect(cloud.connection == Self.iCloudConnection)
        #expect(try await eventually { if case .synced = cloud.syncState { true } else { false } })
        #expect(
            try openDevice(syncIntervals: Self.fast, iCloudDrive: icloud.system).cloud.syncState != .accessLost)
    }

    @Test func iCloudDriveTurnedOffIsAccessLostOnLaunchAndWhenTheAppReturns() async throws {
        let icloud = try fakeICloudDrive()
        let first = try openDevice(syncIntervals: Self.fast, iCloudDrive: icloud.system)
        try await first.cloud.connectICloudDrive(granting: icloud.root)
        #expect(try await eventually { if case .synced = first.cloud.syncState { true } else { false } })

        icloud.isAvailable = false
        first.cloud.foreground()
        #expect(first.cloud.syncState == .accessLost)
        try await Task.sleep(for: .milliseconds(200))
        #expect(first.cloud.syncState == .accessLost)

        let (_, relaunched) = try openDevice(syncIntervals: Self.fast, iCloudDrive: icloud.system)
        #expect(relaunched.connection == Self.iCloudConnection)
        #expect(relaunched.syncState == .accessLost)

        icloud.isAvailable = true
        try await relaunched.connectICloudDrive(granting: icloud.root)
        #expect(try await eventually { if case .synced = relaunched.syncState { true } else { false } })
    }

    @Test func filesICloudHasNotDownloadedYetAreRequested() async throws {
        let icloud = try fakeICloudDrive()
        let remote = icloud.root.appending(path: "Leaf/v1", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        try Data().write(to: remote.appending(path: ".chunk.icloud"))
        let (_, cloud) = try openDevice(syncIntervals: Self.fast, iCloudDrive: icloud.system)

        try await cloud.connectICloudDrive(granting: icloud.root)

        #expect(
            try await eventually {
                icloud.downloads.map(\.lastPathComponent).contains("chunk")
            })
    }

    @Test func onlyICloudDrivesOwnRootCountsAsICloudDrive() {
        let root = "/Users/a/Library/Mobile Documents/com~apple~CloudDocs"
        #expect(ICloudDrive.system.isRoot(URL(filePath: root)))
        #expect(ICloudDrive.system.isRoot(URL(filePath: root, directoryHint: .isDirectory)))
        #expect(!ICloudDrive.system.isRoot(URL(filePath: root + "/Leaf")))
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

    // MARK: Google Drive and OneDrive (OAuth)

    /// Stands in for the core's Google Drive or OneDrive: the shared cloud directory is the Drive.
    private final class FakeOAuthDrive: @unchecked Sendable {
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

        /// Connecting and reconnecting fail like this, as when the provider refuses the token.
        var refusal: ConnectError? {
            get { lock.withLock { state.refusal } }
            set { lock.withLock { state.refusal = newValue } }
        }

        /// The provider rotates the refresh token while Connecting.
        var rotatesWhileConnecting: String? {
            get { lock.withLock { state.rotatesWhileConnecting } }
            set { lock.withLock { state.rotatesWhileConnecting = newValue } }
        }

        /// The refresh tokens that connecting, resuming and reconnecting got.
        var tokensGiven: [String] { lock.withLock { state.tokensGiven } }

        /// The provider rotates the refresh token of the running Connection.
        func rotate(to token: String) { lock.withLock { state.tokens }?.newRefreshToken(token: token) }

        private func take(_ token: String, _ tokens: RefreshTokenObserver) throws -> String {
            try lock.withLock {
                if let refusal = state.refusal { throw refusal }
                state.tokensGiven.append(token)
                state.tokens = tokens
                return state.account
            }
        }

        /// The core's calls: this fake answers for the OAuth Clouds, the core for the others.
        var cloudCore: CloudCore {
            CloudCore(
                connect: { core, target, observer, intervals in
                    guard case .oAuth(_, _, let token, let tokens) = target else {
                        return try CloudCore.system.connect(core, target, observer, intervals)
                    }
                    let account = try self.take(token, tokens)
                    _ = try core.connect(
                        cloud: .directory(path: self.cloud.path), observer: observer, intervals: intervals)
                    if let rotated = self.rotatesWhileConnecting { tokens.newRefreshToken(token: rotated) }
                    return account
                },
                resume: { core, target, observer, intervals in
                    guard case .oAuth(_, _, let token, let tokens) = target else {
                        return try CloudCore.system.resume(core, target, observer, intervals)
                    }
                    _ = try? self.take(token, tokens)
                    try? core.resume(
                        cloud: .directory(path: self.cloud.path), observer: observer, intervals: intervals)
                },
                reconnect: { core, target in
                    guard case .oAuth(_, _, let token, let tokens) = target else {
                        return try CloudCore.system.reconnect(core, target)
                    }
                    return try self.take(token, tokens)
                })
        }
    }

    private static func connection(_ provider: CloudProvider, _ account: String = "reader@example.com")
        -> CloudConnection
    {
        CloudConnection(provider: provider, detail: account)
    }

    private func isSynced(_ cloud: CloudBackingModel) -> Bool {
        if case .synced = cloud.syncState { true } else { false }
    }

    @Test(arguments: oauthProviders)
    func connectingShowsTheAccountAndSyncsThroughTheDrive(provider: CloudProvider) async throws {
        let fake = FakeOAuthDrive(cloud: cloudDirectory)
        let a = try openDevice(syncIntervals: Self.fast, cloudCore: fake.cloudCore)
        let b = try openOtherDevice(cloudCore: fake.cloudCore)
        try await a.cloud.connectOAuth(provider, refreshToken: "token")
        try await b.cloud.connectOAuth(provider, refreshToken: "token")

        let id = try await importedID(a.library, titled: "Paper")

        #expect(a.cloud.connection == Self.connection(provider))
        #expect(try await eventually { isSynced(a.cloud) })
        #expect(try await eventually { ids(b.library) == [id] })
    }

    @Test func aDriveThatDoesntTellTheAccountShowsAGenericName() async throws {
        let fake = FakeOAuthDrive(cloud: cloudDirectory)
        fake.account = ""
        let (_, cloud) = try openDevice(cloudCore: fake.cloudCore)

        try await cloud.connectOAuth(.googleDrive, refreshToken: "token")
        #expect(cloud.connection == Self.connection(.googleDrive, "Google Account"))

        try await cloud.connectOAuth(.oneDrive, refreshToken: "token")
        #expect(cloud.connection == Self.connection(.oneDrive, "Microsoft Account"))
    }

    @Test(arguments: oauthProviders)
    func theTokenAndAccountSurviveARelaunchAndAreForgottenOnDisconnect(provider: CloudProvider) async throws {
        let fake = FakeOAuthDrive(cloud: cloudDirectory)
        let first = try openDevice(syncIntervals: Self.fast, cloudCore: fake.cloudCore)
        try await first.cloud.connectOAuth(provider, refreshToken: "token")
        #expect(credentials.load() == .oauth(provider, refreshToken: "token", account: "reader@example.com"))

        // Relaunch: Connected again with the saved token, without signing in.
        let (_, cloud) = try openDevice(syncIntervals: Self.fast, cloudCore: fake.cloudCore)
        #expect(cloud.connection == Self.connection(provider))
        #expect(fake.tokensGiven == ["token", "token"])
        #expect(try await eventually { isSynced(cloud) })

        await cloud.disconnect()

        #expect(cloud.connection == nil)
        #expect(credentials.load() == nil)
        #expect(try openDevice(cloudCore: fake.cloudCore).cloud.connection == nil)
    }

    @Test(arguments: oauthProviders)
    func aRotatedRefreshTokenReplacesTheSavedOne(provider: CloudProvider) async throws {
        let fake = FakeOAuthDrive(cloud: cloudDirectory)
        let (_, cloud) = try openDevice(syncIntervals: Self.fast, cloudCore: fake.cloudCore)
        try await cloud.connectOAuth(provider, refreshToken: "token")

        fake.rotate(to: "rotated")

        #expect(
            try await eventually {
                credentials.load() == .oauth(provider, refreshToken: "rotated", account: "reader@example.com")
            })
        // A relaunch resumes with it.
        _ = try openDevice(cloudCore: fake.cloudCore)
        #expect(fake.tokensGiven.last == "rotated")
    }

    @Test(arguments: oauthProviders)
    func aRefreshTokenRotatedWhileConnectingIsTheOneSaved(provider: CloudProvider) async throws {
        let fake = FakeOAuthDrive(cloud: cloudDirectory)
        fake.rotatesWhileConnecting = "rotated"
        let (_, cloud) = try openDevice(syncIntervals: Self.fast, cloudCore: fake.cloudCore)

        try await cloud.connectOAuth(provider, refreshToken: "token")
        try await Task.sleep(for: .milliseconds(100))

        #expect(credentials.load() == .oauth(provider, refreshToken: "rotated", account: "reader@example.com"))
    }

    @Test(arguments: oauthProviders)
    func aTokenTheProviderRefusesLeavesCloudBackingOff(provider: CloudProvider) async throws {
        let fake = FakeOAuthDrive(cloud: cloudDirectory)
        fake.refusal = .AccessDenied
        let (_, cloud) = try openDevice(cloudCore: fake.cloudCore)

        await #expect(throws: ConnectError.AccessDenied) {
            try await cloud.connectOAuth(provider, refreshToken: "token")
        }

        #expect(cloud.connection == nil)
        #expect(credentials.load() == nil)
    }

    @Test func aWorkOrSchoolAccountIsRefusedWithAMessage() async throws {
        let fake = FakeOAuthDrive(cloud: cloudDirectory)
        fake.refusal = .UnsupportedAccount
        let (_, cloud) = try openDevice(cloudCore: fake.cloudCore)

        await #expect(throws: ConnectError.UnsupportedAccount) {
            try await cloud.connectOAuth(.oneDrive, refreshToken: "token")
        }

        #expect(cloud.connection == nil)
        #expect(credentials.load() == nil)
    }

    @Test(arguments: oauthProviders)
    func lostAccessIsReconnectedWithANewSignIn(provider: CloudProvider) async throws {
        let fake = FakeOAuthDrive(cloud: cloudDirectory)
        let (_, cloud) = try openDevice(syncIntervals: Self.fast, cloudCore: fake.cloudCore)
        try await cloud.connectOAuth(provider, refreshToken: "old")
        #expect(try await eventually { isSynced(cloud) })
        // The provider refuses access, as after the user revoked it.
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: cloudDirectory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cloudDirectory.path) }
        #expect(try await eventually { cloud.syncState == .accessLost })
        #expect(cloud.syncIndicator == .failed(canRetry: false))

        fake.account = "other@example.com"
        try await cloud.reconnectOAuth(refreshToken: "new")

        #expect(cloud.connection == Self.connection(provider, "other@example.com"))
        #expect(credentials.load() == .oauth(provider, refreshToken: "new", account: "other@example.com"))
    }

    @Test(arguments: oauthProviders)
    func reconnectingWithATokenTheProviderRefusesLeavesTheConnectionAndTheSavedTokenAlone(
        provider: CloudProvider
    ) async throws {
        let fake = FakeOAuthDrive(cloud: cloudDirectory)
        let (_, cloud) = try openDevice(syncIntervals: Self.fast, cloudCore: fake.cloudCore)
        try await cloud.connectOAuth(provider, refreshToken: "old")
        fake.refusal = .AccessDenied

        await #expect(throws: ConnectError.AccessDenied) {
            try await cloud.reconnectOAuth(refreshToken: "new")
        }

        #expect(cloud.connection == Self.connection(provider))
        #expect(credentials.load() == .oauth(provider, refreshToken: "old", account: "reader@example.com"))
    }

    @Test func reconnectingOAuthWithoutAnOAuthConnectionDoesNothing() async throws {
        let fake = FakeOAuthDrive(cloud: cloudDirectory)
        let (_, cloud) = try openDevice(syncIntervals: Self.fast, cloudCore: fake.cloudCore)
        try await cloud.connect(directory: cloudDirectory)

        try await cloud.reconnectOAuth(refreshToken: "new")

        #expect(fake.tokensGiven.isEmpty)
        #expect(credentials.load() == nil)
    }

    @Test(arguments: oauthProviders)
    func theTokenIsKeptAndTheLatestConnectionWins(provider: CloudProvider) {
        let saved = CloudCredential.oauth(provider, refreshToken: "token", account: "a@example.com")
        let webDAV = WebDAVAccount(url: "https://a.example", username: "a", password: "1")
        credentials.save(.webDAV(webDAV))

        #expect(credentials.save(saved))

        #expect(credentials.load() == saved)
        credentials.save(.webDAV(webDAV))
        #expect(credentials.load() == .webDAV(webDAV))
        credentials.save(saved)
        credentials.forget()
        #expect(credentials.load() == nil)
    }

    @Test func connectingToAnotherOAuthProviderReplacesTheSavedToken() {
        let google = CloudCredential.oauth(.googleDrive, refreshToken: "g", account: "a@example.com")
        let oneDrive = CloudCredential.oauth(.oneDrive, refreshToken: "o", account: "b@example.com")
        credentials.save(google)

        credentials.save(oneDrive)
        #expect(credentials.load() == oneDrive)

        credentials.save(google)
        #expect(credentials.load() == google)
    }

    @Test func aSavedAccountWithoutItsTokenIsNotConnected() {
        defaults.set("a@example.com", forKey: "cloud.google.account")
        #expect(credentials.load() == nil)

        defaults.removeObject(forKey: "cloud.google.account")
        defaults.set("a@example.com", forKey: "cloud.onedrive.account")
        #expect(credentials.load() == nil)
    }

    @Test(arguments: oauthProviders)
    func settingsSaySyncIsFullOrAccessIsLost(provider: CloudProvider) {
        #expect(Status.full.line(for: provider) == "\(provider.name) is full")
        #expect(Status.accessLost.line(for: provider) == "Access lost")
    }

    // MARK: Sign-in

    @Test func signInErrorsSayWhatTheUserCanDo() {
        #expect(
            OAuthSignInError.missingPermission(.googleDrive).errorDescription
                == "Allow Leaf to access its files in Google Drive")
        #expect(
            OAuthSignInError.missingPermission(.oneDrive).errorDescription
                == "Allow Leaf to access its files in OneDrive")
    }

    /// The core checks the redirect and the sign-in is done without contacting the provider.
    @Test func aRedirectThatDeclinesOrIsNotForThisAttemptFailsWithoutContactingTheProvider() async throws {
        let drive = try #require(OAuthDrive(.googleDrive))
        let attempt = OAuthSignIn(provider: .googleDrive, clientId: "client", redirectScheme: "com.example.app")
        let redirect = { (query: String) in URL(string: "com.example.app:/oauth2redirect?\(query)")! }

        await #expect(throws: ConnectError.Cancelled) {
            try await drive.refreshToken(of: attempt, from: redirect("state=x&error=access_denied"))
        }
        await #expect(throws: ConnectError.AccessDenied) {
            try await drive.refreshToken(of: attempt, from: redirect("state=x&code=4%2F0Abc"))
        }
    }

    @Test func credentialsSurviveARelaunchAndAreGoneAfterDisconnect() async throws {
        let account = WebDAVAccount(url: "https://127.0.0.1:1", username: "reader", password: "secret")
        #expect(credentials.save(.webDAV(account)))

        // Relaunch: Connected again without contacting the server, which is down.
        let (_, cloud) = try openDevice(syncIntervals: Self.fast)
        #expect(cloud.connection == CloudConnection(provider: .webDAV, detail: account.url))
        #expect(try await eventually { cloud.syncState == .offline })

        await cloud.disconnect()

        #expect(cloud.connection == nil)
        #expect(credentials.load() == nil)
        #expect(try openDevice().cloud.connection == nil)
    }

    @Test func savedCredentialsHoldOnlyTheLatestConnection() {
        credentials.save(.webDAV(WebDAVAccount(url: "https://a.example", username: "a", password: "1")))
        credentials.save(.webDAV(WebDAVAccount(url: "https://b.example", username: "b", password: "2")))

        #expect(credentials.load() == .webDAV(WebDAVAccount(url: "https://b.example", username: "b", password: "2")))
        credentials.forget()
        #expect(credentials.load() == nil)
    }

    /// What Leaf saved before Cloud Providers had names: the URL and username
    /// in the defaults, the password in the Keychain.
    @Test func credentialsSavedBeforeCloudProvidersHadNamesStillLoad() throws {
        let service = "leaf-test-\(root.lastPathComponent)"
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
        let (a, b) = (try openDevice(syncIntervals: Self.fast), try openOtherDevice())
        let count = 8
        for number in 0..<count { _ = try await importedID(a.library, titled: "Doc \(number)") }
        try await a.cloud.connect(directory: cloudDirectory)
        // All Files are in the cloud, so B downloads them in one Sync.
        #expect(
            try await eventually {
                if case .synced = a.cloud.syncState { true } else { false }
            })

        try await b.cloud.connect(directory: cloudDirectory)
        var seen: [Int] = []
        for _ in 0..<5000 {
            if let done = b.cloud.transfer?.done, seen.last != done { seen.append(done) }
            if b.library.documents.count == count && b.cloud.transfer == nil { break }
            try await Task.sleep(for: .milliseconds(1))
        }

        #expect(!seen.isEmpty)
        #expect(seen == seen.sorted())
        #expect(b.library.documents.count == count)
        #expect(b.cloud.transfer == nil)
    }

    @Test func syncsOfStateOnlyShowNoTransferBar() async throws {
        let (a, b, _) = try await twoDevicesWithADocument()
        let onA = try #require(a.library.documents.first)
        let onB = try #require(b.library.documents.first)
        let before = b.library.markupRevision(of: onB)

        _ = try #require(await a.library.addHighlight(anchor, quotedText: quote, to: onA))
        await a.library.saveProgress(place, of: onA, at: lastRead)
        var bars: [FileTransfer] = []
        for _ in 0..<500
        where b.library.markupRevision(of: onB) == before || b.library.documents.first?.place == nil {
            bars += [a.cloud.transfer, b.cloud.transfer].compactMap { $0 }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(b.library.markupRevision(of: onB) > before)
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
        #expect(Status.updateNeeded.line(for: .webDAV) == "Update Leaf to keep syncing")
    }

    @Test func aFullCloudIsBlockedInTheGalleryAndNotRetryable() {
        #expect(SyncIndicator(.full) == .failed(canRetry: false))
    }

    @Test func theIndicatorShowsHowSyncStandsWhileConnected() async throws {
        // Offline: the server is down. Trying again can help.
        let account = WebDAVAccount(url: "https://127.0.0.1:1", username: "reader", password: "secret")
        #expect(credentials.save(.webDAV(account)))
        let (_, offline) = try openDevice(syncIntervals: Self.fast)
        #expect(try await eventually { offline.syncState == .offline })
        #expect(offline.syncIndicator == .failed(canRetry: true))
        await offline.disconnect()

        // Not Connected.
        let (_, cloud) = try openDevice(syncIntervals: Self.fast)
        #expect(cloud.syncIndicator == nil)

        // Blocked: the cloud refuses access, as a server does with a changed password.
        try await cloud.connect(directory: cloudDirectory)
        #expect(try await eventually { if case .synced = cloud.syncState { true } else { false } })
        if case .synced(let at) = cloud.syncState {
            #expect(cloud.syncIndicator == .synced(Date(milliseconds: at)))
        }
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: cloudDirectory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cloudDirectory.path) }
        #expect(try await eventually { cloud.syncState == .accessLost })
        #expect(cloud.syncIndicator == .failed(canRetry: false))
        #expect(cloud.connection != nil)

        await cloud.disconnect()
        #expect(cloud.syncIndicator == nil)
    }

    @Test func withoutANetworkNothingSyncsAndTheIndicatorWarns() async throws {
        let (a, b) = (try openDevice(syncIntervals: Self.fast), try openOtherDevice())
        a.cloud.setOnline(false)
        try await a.cloud.connect(directory: cloudDirectory)
        try await b.cloud.connect(directory: cloudDirectory)
        let id = try await importedID(a.library, titled: "Paper")

        #expect(a.cloud.syncIndicator == .noConnection)
        try await Task.sleep(for: .milliseconds(200))
        #expect(ids(b.library).isEmpty)

        a.cloud.setOnline(true)

        #expect(try await eventually { ids(b.library) == [id] })
        #expect(a.cloud.syncIndicator == SyncIndicator(a.cloud.syncState))
    }

    @Test func theIndicatorsMessageSaysWhenSyncLastSucceeded() {
        let date = Date(timeIntervalSince1970: 1_000_000)
        let time = date.formatted(date: .omitted, time: .shortened)
        let day = date.formatted(date: .abbreviated, time: .omitted)

        #expect(SyncIndicator.synced(date).message == "Last synced at \(time) \(day)")
        #expect(SyncIndicator.syncing.message == "Syncing…")
        #expect(SyncIndicator.failed(canRetry: true).message == "Error while syncing")
        #expect(SyncIndicator.failed(canRetry: false).message == "Error while syncing")
        #expect(
            SyncIndicator.noConnection.message
                == "No internet connection. Connect to the internet to resume syncing.")
    }

    @Test func reconnectingWithAPasswordThatTheServerCantCheckLeavesTheConnectionAndTheSavedPasswordAlone() async throws
    {
        let account = WebDAVAccount(url: "https://127.0.0.1:1", username: "reader", password: "old")
        #expect(credentials.save(.webDAV(account)))
        let (_, cloud) = try openDevice(syncIntervals: Self.fast)

        await #expect(throws: ConnectError.Unreachable) { try await cloud.reconnect(password: "new") }

        #expect(cloud.connection == CloudConnection(provider: .webDAV, detail: account.url))
        #expect(credentials.load() == .webDAV(account))
    }

    @Test func reconnectingWithoutASavedConnectionDoesNothing() async throws {
        let (_, cloud) = try openDevice(syncIntervals: Self.fast)
        try await cloud.connect(directory: cloudDirectory)

        try await cloud.reconnect(password: "new")

        #expect(cloud.connection == CloudConnection(provider: .webDAV, detail: cloudDirectory.path))
        #expect(credentials.load() == nil)
    }

    /// Two connected Devices that both hold one Document, imported on the first.
    private func twoDevicesWithADocument() async throws -> (Device, Device, String) {
        let (a, b) = (try openDevice(syncIntervals: Self.fast), try openOtherDevice())
        try await a.cloud.connect(directory: cloudDirectory)
        try await b.cloud.connect(directory: cloudDirectory)
        let id = try await importedID(a.library, titled: "Paper")
        #expect(try await eventually { ids(b.library) == [id] })
        return (a, b, id)
    }

    // MARK: Markup and Reading Progress through Sync

    private let place = Place.pdf(pageIndex: 7, point: CGPoint(x: 12.5, y: 700.25))
    private let lastRead = Date(timeIntervalSince1970: 1_700_000_000.5)
    private let anchor = Anchor.pdf([
        PageRects(pageIndex: 2, rects: [CGRect(x: 72, y: 700.5, width: 200, height: 12)]),
        PageRects(
            pageIndex: 3,
            rects: [CGRect(x: 72, y: 720, width: 100, height: 12), CGRect(x: 72, y: 706, width: 40, height: 12)]),
    ])
    private let quote = "the passage"

    @Test func aHighlightAddedOnOneDeviceAppearsOnTheOtherAndTheReaderIsTold() async throws {
        let (a, b, id) = try await twoDevicesWithADocument()
        let onB = try #require(b.library.documents.first)
        let before = b.library.markupRevision(of: onB)

        let onA = try #require(a.library.documents.first)
        let added = try #require(await a.library.addHighlight(anchor, quotedText: quote, to: onA))

        #expect(try await eventually { b.library.markupRevision(of: onB) > before })
        #expect(await b.library.markup(of: onB).highlights == [added])
        #expect(onB.id == id)
    }

    @Test func aNoteAndAPageNoteAddedOnOneDeviceAppearOnTheOther() async throws {
        let (a, b, _) = try await twoDevicesWithADocument()
        let onA = try #require(a.library.documents.first)
        let onB = try #require(b.library.documents.first)
        let highlight = try #require(await a.library.addHighlight(anchor, quotedText: quote, to: onA))
        await a.library.setNote("worth a note", of: highlight, in: onA)
        let pageNote = try #require(await a.library.addPageNote(at: place, to: onA))
        await a.library.setText("page note", of: pageNote, in: onA)

        #expect(
            try await eventuallyAsync {
                let note = await b.library.markup(of: onB).highlights.first?.note
                let pageNotes = await b.library.markup(of: onB).pageNotes
                return note == "worth a note" && pageNotes.count == 1
            })
    }

    @Test func incomingReadingProgressShowsInTheGalleryButNeverMovesAnOpenReader() async throws {
        let (a, b, _) = try await twoDevicesWithADocument()
        // What the Reader of B holds: the Document as it was opened.
        let open = try #require(b.library.documents.first)
        await b.library.saveProgress(place, of: open, at: lastRead)
        let opened = try #require(b.library.documents.first)

        await a.library.saveProgress(
            Place.pdf(pageIndex: 3, point: .zero), of: try #require(a.library.documents.first),
            at: lastRead.addingTimeInterval(60))

        #expect(try await eventually { b.library.documents.first?.place?.pageIndex == 3 })
        #expect(opened.place == place)
        // Its next save carries the newer Last Read, so it wins everywhere.
        let later = lastRead.addingTimeInterval(120)
        await b.library.saveProgress(place, of: opened, at: later)
        #expect(try await eventually { a.library.documents.first?.lastRead == later })
        #expect(a.library.documents.first?.place == place)
    }

    @Test func customColorsAndTheDefaultHighlightColorSyncBetweenDevices() async throws {
        let (a, b) = (try openDevice(syncIntervals: Self.fast), try openOtherDevice())
        try await a.cloud.connect(directory: cloudDirectory)
        try await b.cloud.connect(directory: cloudDirectory)

        let custom = try #require(await a.library.addCustomColor(RGB(0.2, 0.4, 0.6)))
        await a.library.setDefaultHighlightColor(custom)

        #expect(
            try await eventually {
                b.library.highlightColors.contains(custom) && b.library.defaultHighlightColor == custom
            })
        await b.library.removeCustomColor(custom)
        #expect(
            try await eventually {
                !a.library.highlightColors.contains(custom) && a.library.defaultHighlightColor.id == "Yellow"
            })
    }

    // MARK: The seam to the Library

    /// Stands in for the Library: records what Cloud Backing tells it.
    @MainActor private final class RecordingLibrary: SyncedLibrary {
        private(set) var libraryChanges = 0
        private(set) var markupChanges: [String] = []

        func libraryChanged() { libraryChanges += 1 }
        func markupChanged(of id: String) { markupChanges.append(id) }
    }

    /// Cloud Backing of this test's root, reporting to `library` instead of a LibraryModel.
    private func openCloud(reportingTo library: RecordingLibrary) throws -> CloudBackingModel {
        CloudBackingModel(
            core: try LeafCore.Library.open(root: root.path), library: library, credentials: credentials,
            syncIntervals: Self.fast)
    }

    @Test func aChangeFromTheCloudTellsTheLibraryItChanged() async throws {
        let recorder = RecordingLibrary()
        let cloud = try openCloud(reportingTo: recorder)
        let other = try openOtherDevice()
        try await cloud.connect(directory: cloudDirectory)
        try await other.cloud.connect(directory: cloudDirectory)

        _ = try await importedID(other.library, titled: "Paper")

        #expect(try await eventually { recorder.libraryChanges > 0 })
    }

    @Test func aMarkupChangeFromTheCloudNamesTheDocumentThatChanged() async throws {
        let recorder = RecordingLibrary()
        let cloud = try openCloud(reportingTo: recorder)
        let other = try openOtherDevice()
        try await cloud.connect(directory: cloudDirectory)
        try await other.cloud.connect(directory: cloudDirectory)
        let id = try await importedID(other.library, titled: "Paper")
        let document = try #require(other.library.documents.first)

        _ = try #require(await other.library.addHighlight(anchor, quotedText: quote, to: document))

        #expect(try await eventually { recorder.markupChanges.contains(id) })
    }

    @Test func aDisconnectedDeviceTellsTheLibraryNothingMore() async throws {
        let recorder = RecordingLibrary()
        let cloud = try openCloud(reportingTo: recorder)
        let other = try openOtherDevice()
        try await cloud.connect(directory: cloudDirectory)
        try await other.cloud.connect(directory: cloudDirectory)
        _ = try await importedID(other.library, titled: "First")
        #expect(try await eventually { recorder.libraryChanges > 0 })

        await cloud.disconnect()
        let reported = recorder.libraryChanges
        _ = try await importedID(other.library, titled: "Second")
        try await Task.sleep(for: .milliseconds(300))

        #expect(recorder.libraryChanges == reported)
    }
}
