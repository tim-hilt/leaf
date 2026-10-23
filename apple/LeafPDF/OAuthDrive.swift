import Foundation
import LeafCore

/// What Cloud Backing asks of the core for a Cloud Provider behind OAuth
/// (Google Drive, OneDrive); tests stand in.
struct OAuthDrive: Sendable {
    typealias Connect =
        @Sendable (LeafCore.Library, _ refreshToken: String, RefreshTokenObserver, SyncObserver, SyncIntervals) throws
        -> String
    typealias Resume =
        @Sendable (LeafCore.Library, _ refreshToken: String, RefreshTokenObserver, SyncObserver, SyncIntervals) -> Void
    typealias Reconnect = @Sendable (LeafCore.Library, _ refreshToken: String, RefreshTokenObserver) throws -> String

    /// Starts syncing with the Drive the token belongs to; returns its account.
    var connect: Connect
    /// Like `connect` for a Drive connected before; contacts nobody.
    var resume: Resume
    /// Gives the running Connection a new token, after access was lost; returns the account.
    var reconnect: Reconnect

    /// The core's storage of `provider`, for the OAuth client `clientID`.
    static func core(_ provider: OAuthProvider, clientID: String) -> OAuthDrive {
        OAuthDrive(
            connect: { core, token, tokens, observer, intervals in
                try core.connectOauth(
                    provider: provider, clientId: clientID, refreshToken: token, tokens: tokens, observer: observer,
                    intervals: intervals)
            },
            resume: { core, token, tokens, observer, intervals in
                core.resumeOauth(
                    provider: provider, clientId: clientID, refreshToken: token, tokens: tokens, observer: observer,
                    intervals: intervals)
            },
            reconnect: { core, token, tokens in
                try core.reconnectOauth(provider: provider, clientId: clientID, refreshToken: token, tokens: tokens)
            })
    }

    /// The OAuth clients of this app, from Info.plist (see `Config/CloudClients.xcconfig`).
    static let system: [CloudProvider: OAuthDrive] = [
        .googleDrive: .core(.googleDrive, clientID: OAuthSignIn.configured(.google)?.clientID ?? ""),
        .oneDrive: .core(.oneDrive, clientID: OAuthSignIn.configured(.microsoft)?.clientID ?? ""),
    ]
}

/// Keeps the latest refresh token of a Connection: the one it started with, or
/// the one the core reported last. `changed` hears of each report, on the main actor.
final class RefreshTokenKeeper: RefreshTokenObserver, @unchecked Sendable {
    private let lock = NSLock()
    private var token: String
    private let changed: @Sendable @MainActor (String) -> Void

    init(_ token: String, changed: @escaping @Sendable @MainActor (String) -> Void) {
        self.token = token
        self.changed = changed
    }

    var latest: String { lock.withLock { token } }

    func newRefreshToken(token: String) {
        lock.withLock { self.token = token }
        Task { @MainActor [changed] in changed(token) }
    }
}
