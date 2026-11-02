import Foundation
import LeafCore
import Synchronization

/// Why the user couldn't Connect a Cloud Provider behind OAuth, besides a `ConnectError`.
enum OAuthSignInError: LocalizedError, Equatable {
    /// The consent page didn't give access to the files Leaf creates.
    case missingPermission(CloudProvider)
    /// The app has no OAuth client yet (`scripts/cloud-oauth-wizard.sh`).
    case notConfigured(CloudProvider)

    var errorDescription: String? {
        switch self {
        case .missingPermission(let provider): "Allow Leaf to access its files in \(provider.name)"
        case .notConfigured(let provider): "\(provider.name) isn't set up in this build"
        }
    }
}

/// A Cloud Provider behind OAuth, as the core has it: its OAuth provider and
/// the OAuth client of this app, from Info.plist (see `Config/CloudClients.xcconfig`).
struct OAuthDrive: Sendable {
    let cloudProvider: CloudProvider
    let provider: OAuthProvider
    /// Empty until the app has an OAuth client.
    let clientID: String
    /// The URL scheme the consent page redirects to; empty until the app has an OAuth client.
    let redirectScheme: String

    /// Nil for a Cloud Provider without OAuth.
    init?(_ cloudProvider: CloudProvider) {
        let info = Bundle.main.infoDictionary
        self.cloudProvider = cloudProvider
        switch cloudProvider {
        case .googleDrive:
            provider = .googleDrive
            clientID = info?["GoogleClientID"] as? String ?? ""
            redirectScheme = info?["GoogleRedirectScheme"] as? String ?? ""
        case .oneDrive:
            provider = .oneDrive
            clientID = info?["MicrosoftClientID"] as? String ?? ""
            redirectScheme = info?["MicrosoftRedirectScheme"] as? String ?? ""
        case .webDAV, .iCloudDrive:
            return nil
        }
    }

    /// The sign-in to start with the consent page at `authorizationUrl`.
    func signIn() throws -> OAuthSignIn {
        guard !clientID.isEmpty, !redirectScheme.isEmpty else { throw OAuthSignInError.notConfigured(cloudProvider) }
        return OAuthSignIn(provider: provider, clientId: clientID, redirectScheme: redirectScheme)
    }

    /// The refresh token that the redirect to `callback` leads to, worded as Connecting words it.
    func refreshToken(of attempt: OAuthSignIn, from callback: URL) async throws -> String {
        do {
            return try await Task.detached { try attempt.refreshToken(callbackUrl: callback.absoluteString) }.value
        } catch let error as OAuthError {
            switch error {
            case .Cancelled: throw ConnectError.Cancelled
            case .AccessDenied: throw ConnectError.AccessDenied
            case .MissingPermission: throw OAuthSignInError.missingPermission(cloudProvider)
            case .Unreachable: throw ConnectError.Unreachable
            }
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
