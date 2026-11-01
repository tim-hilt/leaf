import Foundation
import LeafCore
import Synchronization

/// A Cloud Provider behind OAuth, as the core has it: its OAuth provider and
/// the OAuth client of this app, from Info.plist (see `Config/CloudClients.xcconfig`).
struct OAuthDrive: Sendable {
    let provider: OAuthProvider
    let clientID: String

    /// Nil for a Cloud Provider without OAuth.
    init?(_ provider: CloudProvider) {
        switch provider {
        case .googleDrive:
            self.provider = .googleDrive
            clientID = OAuthSignIn.configured(.google)?.clientID ?? ""
        case .oneDrive:
            self.provider = .oneDrive
            clientID = OAuthSignIn.configured(.microsoft)?.clientID ?? ""
        case .webDAV, .iCloudDrive:
            return nil
        }
    }

    /// The core's Cloud of this drive for `refreshToken`, a token of its OAuth client.
    func cloud(refreshToken: String, tokens: RefreshTokenObserver) -> Cloud {
        .oAuth(provider: provider, clientId: clientID, refreshToken: refreshToken, tokens: tokens)
    }
}

/// Keeps the latest refresh token of a Connection: the one it started with, or
/// the one the core reported last. `changed` hears of each report, on the main actor.
final class RefreshTokenKeeper: RefreshTokenObserver {
    private let token: Mutex<String>
    private let changed: @Sendable @MainActor (String) -> Void

    init(_ token: String, changed: @escaping @Sendable @MainActor (String) -> Void) {
        self.token = Mutex(token)
        self.changed = changed
    }

    var latest: String { token.withLock { $0 } }

    func newRefreshToken(token: String) {
        self.token.withLock { $0 = token }
        Task { @MainActor [changed] in changed(token) }
    }
}
