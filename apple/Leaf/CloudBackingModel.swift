import Foundation
import LeafCore
import Network

/// The Library as Cloud Backing's Sync changes it: told what changed, on the main actor.
@MainActor protocol SyncedLibrary: AnyObject {
    /// Documents or Highlight Colors changed: read them again.
    func libraryChanged()
    /// The Markup of Document `id` changed: read it again.
    func markupChanged(of id: String)
}

extension SyncIntervals {
    /// Local changes sync within seconds, Reading Progress within a minute;
    /// polls run every 10 seconds, backing off to every 5 minutes while idle.
    static let standard = SyncIntervals(debounceMs: 3000, progressMs: 60000, pollMs: 10000, idlePollMs: 300_000)
}

/// Cloud Backing: the Connection to the Cloud Provider this Device is Connected
/// to, its credentials and how Sync stands. It drives the core Library it is
/// given, and tells `library` what Sync changed. One per app.
@MainActor @Observable
final class CloudBackingModel {
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
    @ObservationIgnored private let core: LeafCore.Library
    @ObservationIgnored private let library: SyncedLibrary
    @ObservationIgnored private let credentials: CloudCredentials
    @ObservationIgnored private let iCloudDrive: ICloudDrive
    @ObservationIgnored private let cloudCore: CloudCore
    @ObservationIgnored private let syncIntervals: SyncIntervals
    /// The access to iCloud Drive that a Connection to it holds, until it ends.
    @ObservationIgnored private var iCloudGrant: ICloudGrant?
    /// Tells `setOnline` how the system's network stands, once `followNetwork` runs.
    @ObservationIgnored private var network: NWPathMonitor?
    /// Names the current Connection, so reports of a finished one are ignored.
    @ObservationIgnored private var connectionID: UUID?

    /// Cloud Backing for `core`, reporting to `library`. The Cloud Provider saved
    /// in `credentials` is Connected again, without contacting it, so launching
    /// offline works. Sync steps run `syncIntervals` apart.
    init(
        core: LeafCore.Library, library: SyncedLibrary, credentials: CloudCredentials,
        iCloudDrive: ICloudDrive = .system, cloudCore: CloudCore = .system,
        syncIntervals: SyncIntervals = .standard
    ) {
        self.core = core
        self.library = library
        self.credentials = credentials
        self.iCloudDrive = iCloudDrive
        self.cloudCore = cloudCore
        self.syncIntervals = syncIntervals
        if let saved = credentials.load() {
            let id = newConnection()
            do {
                switch saved {
                case .webDAV(let account):
                    try resume(
                        .webDav(url: account.url, username: account.username, password: account.password), as: id)
                    connection = CloudConnection(provider: .webDAV, detail: account.url)
                case .iCloudDrive(let bookmark):
                    connection = Self.iCloudConnection
                    // Without the grant or iCloud Drive there is nothing to sync with until Reconnect.
                    if !resumeICloudDrive(bookmark: bookmark, id: id) { loseAccess() }
                case .oauth(let provider, let token, let account):
                    guard let drive = OAuthDrive(provider) else { throw ConnectError.AccessDenied }
                    try resume(drive.cloud(refreshToken: token, tokens: refreshTokens(token, for: id)), as: id)
                    connection = Self.oauthConnection(provider, account)
                }
            } catch {
                connectionID = nil
            }
        }
    }

    /// Connects to the WebDAV server at `url` and starts syncing, which first
    /// merges this Library with the one in the cloud. Checks the details first
    /// and throws a `ConnectError` if they are wrong. Keeps them, the password
    /// in the Keychain, until `disconnect`. Replaces any earlier Connection.
    func connect(url: String, username: String, password: String) async throws {
        let id = newConnection()
        _ = try await connect(.webDav(url: url, username: username, password: password), as: id)
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
        _ = try await reconnect(.webDav(url: account.url, username: account.username, password: password))
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
        _ = try await connect(iCloud(grant), as: id)
        iCloudGrant = grant
        connection = Self.iCloudConnection
        credentials.save(.iCloudDrive(bookmark: grant.bookmark))
    }

    /// Resumes syncing with the iCloud Drive that `bookmark` gives access to.
    /// False if it can't be resumed: access is lost.
    private func resumeICloudDrive(bookmark: Data, id: UUID) -> Bool {
        guard iCloudDrive.isAvailable(), let grant = ICloudGrant(bookmark: bookmark),
            (try? resume(iCloud(grant), as: id)) != nil
        else { return false }
        iCloudGrant = grant
        return true
    }

    /// Connects Connection `id` to `cloud`. The core blocks while it talks to the
    /// provider, so this runs off the main actor. Clears `id` if that fails.
    private func connect(_ cloud: Cloud, as id: UUID) async throws -> String {
        let (core, cloudCore, observer, intervals) = (core, cloudCore, relay(for: id), syncIntervals)
        do {
            return try await Task.detached {
                try cloudCore.connect(core, cloud, observer, intervals)
            }.value
        } catch {
            if connectionID == id { connectionID = nil }
            throw error
        }
    }

    /// Resumes Connection `id` to `cloud`, contacting nobody. Throws if the Cloud can't be opened.
    private func resume(_ cloud: Cloud, as id: UUID) throws {
        try cloudCore.resume(core, cloud, relay(for: id), syncIntervals)
    }

    /// Gives the running Connection `cloud`, see `CloudCore.reconnect`.
    private func reconnect(_ cloud: Cloud) async throws -> String {
        let (core, cloudCore) = (core, cloudCore)
        return try await Task.detached { try cloudCore.reconnect(core, cloud) }.value
    }

    /// The core's Cloud of the iCloud Drive folder that `grant` gives access to.
    private func iCloud(_ grant: ICloudGrant) -> Cloud {
        .iCloudDrive(folder: grant.folder.path, downloads: DownloadRequests(iCloudDrive.requestDownload))
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
        guard let drive = OAuthDrive(provider) else { throw ConnectError.AccessDenied }
        let id = newConnection()
        let tokens = refreshTokens(refreshToken, for: id)
        let account = try await connect(drive.cloud(refreshToken: refreshToken, tokens: tokens), as: id)
        connection = Self.oauthConnection(provider, account)
        credentials.save(.oauth(provider, refreshToken: tokens.latest, account: account))
    }

    /// Gives the Connection access again, after it was lost, with the token of
    /// a new sign-in: Sync resumes at once, without Disconnecting. Throws a
    /// `ConnectError` if the provider refuses it; the Connection and the saved
    /// token then stay as they were. Does nothing unless a Google Drive or
    /// OneDrive Connection is saved.
    func reconnectOAuth(refreshToken: String) async throws {
        guard case .oauth(let provider, _, _) = credentials.load(), let drive = OAuthDrive(provider),
            let id = connectionID
        else { return }
        let tokens = refreshTokens(refreshToken, for: id)
        let account = try await reconnect(drive.cloud(refreshToken: refreshToken, tokens: tokens))
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
        let id = newConnection()
        _ = try await connect(.directory(path: directory.path), as: id)
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
                library.libraryChanged()
            },
            markupChanged: { [weak self] document in
                guard let self, connectionID == id else { return }
                library.markupChanged(of: document)
            })
    }
}
