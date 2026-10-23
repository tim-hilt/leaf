import Foundation
import LeafCore

/// What Cloud Backing asks of the system's iCloud Drive; tests stand in for it.
struct ICloudDrive: Sendable {
    /// The folder in iCloud Drive that holds the Library, created if missing.
    static let folderName = "LeafPDF"
    /// What Settings shows of the Connection.
    static let folderDescription = "iCloud Drive/\(folderName)"

    /// False while iCloud Drive is off or the user isn't signed in to iCloud.
    var isAvailable: @Sendable () -> Bool
    /// Whether `folder` is iCloud Drive itself, rather than a folder in it or elsewhere.
    var isRoot: @Sendable (URL) -> Bool
    /// Asks the system to download `file`, which another Device wrote.
    var requestDownload: @Sendable (URL) -> Void

    static let system = ICloudDrive(
        isAvailable: { FileManager.default.ubiquityIdentityToken != nil },
        isRoot: { folder in
            folder.standardizedFileURL.path.hasSuffix("/Mobile Documents/com~apple~CloudDocs")
        },
        requestDownload: { try? FileManager.default.startDownloadingUbiquitousItem(at: $0) })
}

/// Hands the core's requests for files that iCloud hasn't downloaded to `request`.
final class DownloadRequests: DownloadRequester {
    private let request: @Sendable (URL) -> Void

    init(_ request: @escaping @Sendable (URL) -> Void) { self.request = request }

    func requestDownload(path: String) { request(URL(filePath: path)) }
}

/// The user's grant of iCloud Drive: access to its root, held for as long as
/// this lives.
final class ICloudGrant {
    let root: URL
    /// What gets the access back after a relaunch.
    let bookmark: Data
    /// Whether the system counted our access, which must be given back.
    private let isScoped: Bool

    #if os(macOS)
        private static let creating: URL.BookmarkCreationOptions = .withSecurityScope
        private static let resolving: URL.BookmarkResolutionOptions = .withSecurityScope
    #else
        private static let creating: URL.BookmarkCreationOptions = []
        private static let resolving: URL.BookmarkResolutionOptions = []
    #endif

    /// Takes the grant of `root`, which the system's folder picker returned.
    /// Throws `AccessDenied` if the system won't keep it.
    init(granting root: URL) throws {
        let scoped = root.startAccessingSecurityScopedResource()
        do {
            bookmark = try root.bookmarkData(options: Self.creating)
        } catch {
            if scoped { root.stopAccessingSecurityScopedResource() }
            throw ConnectError.AccessDenied
        }
        self.root = root
        isScoped = scoped
    }

    /// Gets back the access that `bookmark` kept; nil if it is stale or can't be resolved.
    init?(bookmark: Data) {
        var isStale = false
        guard
            let root = try? URL(
                resolvingBookmarkData: bookmark, options: Self.resolving, relativeTo: nil, bookmarkDataIsStale: &isStale
            ),
            !isStale
        else { return nil }
        isScoped = root.startAccessingSecurityScopedResource()
        self.root = root
        self.bookmark = bookmark
    }

    /// Where the Library lives in it.
    var folder: URL { root.appending(path: ICloudDrive.folderName, directoryHint: .isDirectory) }

    deinit { if isScoped { root.stopAccessingSecurityScopedResource() } }
}
