import CryptoKit
import Foundation
import LeafCore

/// What Cloud Backing asks of the core for Google Drive; tests stand in.
struct GoogleDrive: Sendable {
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

    static func with(clientID: String) -> GoogleDrive {
        GoogleDrive(
            connect: { core, token, tokens, observer, intervals in
                try core.connectGoogleDrive(
                    clientId: clientID, refreshToken: token, tokens: tokens, observer: observer, intervals: intervals)
            },
            resume: { core, token, tokens, observer, intervals in
                core.resumeGoogleDrive(
                    clientId: clientID, refreshToken: token, tokens: tokens, observer: observer, intervals: intervals)
            },
            reconnect: { core, token, tokens in
                try core.reconnectGoogleDrive(clientId: clientID, refreshToken: token, tokens: tokens)
            })
    }

    /// The OAuth client of this app, from Info.plist (see `Config/CloudClients.xcconfig`).
    static let system = with(clientID: GoogleSignIn.configured?.clientID ?? "")
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

/// Why the user couldn't Connect Google Drive, besides a `ConnectError`.
enum GoogleSignInError: LocalizedError, Equatable {
    /// The consent page didn't give access to the files LeafPDF creates.
    case missingPermission
    /// The app has no OAuth client yet (`scripts/cloud-oauth-wizard.sh`).
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .missingPermission: "Allow LeafPDF to access its files in Google Drive"
        case .notConfigured: "Google Drive isn't set up in this build"
        }
    }
}

/// Google's sign-in page for a public OAuth client: authorization code flow
/// with PKCE and a custom URL scheme, no SDK. One value is one attempt.
struct GoogleSignIn {
    static let scope = "https://www.googleapis.com/auth/drive.file"
    private static let authorizationEndpoint = "https://accounts.google.com/o/oauth2/v2/auth"
    private static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!

    let clientID: String
    /// The URL scheme of the redirect, registered in Info.plist.
    let redirectScheme: String
    private let verifier: String
    private let state: String

    /// The app's client from Info.plist; nil until the maintainer has set it up.
    static var configured: GoogleSignIn? {
        let info = Bundle.main.infoDictionary
        guard let id = info?["GoogleClientID"] as? String, let scheme = info?["GoogleRedirectScheme"] as? String,
            !id.isEmpty, !scheme.isEmpty
        else { return nil }
        return GoogleSignIn(clientID: id, redirectScheme: scheme)
    }

    init(clientID: String, redirectScheme: String) {
        self.init(clientID: clientID, redirectScheme: redirectScheme, verifier: Self.random(), state: Self.random())
    }

    init(clientID: String, redirectScheme: String, verifier: String, state: String) {
        self.clientID = clientID
        self.redirectScheme = redirectScheme
        self.verifier = verifier
        self.state = state
    }

    private static func random() -> String {
        Data((0..<32).map { _ in UInt8.random(in: .min ... .max) }).base64URL
    }

    private var redirectURI: String { "\(redirectScheme):/oauth2redirect" }

    /// The PKCE challenge of the verifier.
    var challenge: String { Data(SHA256.hash(data: Data(verifier.utf8))).base64URL }

    /// The page to open. Asks for offline access, and for consent every time,
    /// so Google always hands out a refresh token.
    var url: URL {
        var page = URLComponents(string: Self.authorizationEndpoint)!
        page.queryItems = [
            ("client_id", clientID), ("redirect_uri", redirectURI), ("response_type", "code"),
            ("scope", Self.scope), ("code_challenge", challenge), ("code_challenge_method", "S256"),
            ("state", state), ("access_type", "offline"), ("prompt", "consent"),
        ].map { URLQueryItem(name: $0.0, value: $0.1) }
        return page.url!
    }

    /// The authorization code that the redirect to `callback` carries. Throws
    /// `Cancelled` if the user declined on the consent page.
    func code(from callback: URL) throws -> String {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value = { (name: String) in items.first { $0.name == name }?.value }
        if let error = value("error") {
            throw error == "access_denied" ? ConnectError.Cancelled : ConnectError.AccessDenied
        }
        guard value("state") == state, let code = value("code") else { throw ConnectError.AccessDenied }
        return code
    }

    /// The refresh token that `code` is worth. Throws `MissingPermission` if
    /// the user unchecked the permission for Drive, `Unreachable` without network.
    func refreshToken(from callback: URL) async throws -> String {
        let code = try code(from: callback)
        var request = URLRequest(url: Self.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let unreserved = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let form = [
            ("client_id", clientID), ("code", code), ("code_verifier", verifier),
            ("grant_type", "authorization_code"), ("redirect_uri", redirectURI),
        ].map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "")" }
        request.httpBody = Data(form.joined(separator: "&").utf8)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ConnectError.Unreachable
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ConnectError.AccessDenied }
        return try Self.refreshToken(fromTokenResponse: data)
    }

    /// The refresh token in the token endpoint's answer, if it grants Drive.
    static func refreshToken(fromTokenResponse data: Data) throws -> String {
        let answer = try? JSONDecoder().decode(TokenResponse.self, from: data)
        guard let answer, let token = answer.refreshToken else { throw ConnectError.AccessDenied }
        guard answer.scope.split(separator: " ").contains(Substring(scope)) else {
            throw GoogleSignInError.missingPermission
        }
        return token
    }

    private struct TokenResponse: Decodable {
        let refreshToken: String?
        let scope: String

        enum CodingKeys: String, CodingKey {
            case refreshToken = "refresh_token"
            case scope
        }
    }
}

extension Data {
    /// Base64 for URLs, without padding (RFC 4648 §5).
    fileprivate var base64URL: String {
        base64EncodedString().replacing("+", with: "-").replacing("/", with: "_").replacing("=", with: "")
    }
}
