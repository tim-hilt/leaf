import CryptoKit
import Foundation
import LeafCore

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

/// A provider's sign-in page for a public OAuth client: authorization code
/// flow with PKCE and a custom URL scheme, no SDK. One value is one attempt.
/// What differs per provider is in `Service`.
struct OAuthSignIn {
    /// The endpoints, scopes and client settings of one provider's OAuth.
    struct Service {
        let provider: CloudProvider
        let authorizationEndpoint: String
        let tokenEndpoint: URL
        /// What the page asks for. The first gives access to the files Leaf
        /// creates; the consent has to include it.
        let scopes: [String]
        /// What the page asks for besides the standard, e.g. a refresh token.
        let authorizationParameters: [(String, String)]
        /// What the redirect URI is after its scheme.
        let redirectSuffix: String
        /// Where Info.plist keeps the client ID and the redirect scheme.
        let clientIDKey: String
        let redirectSchemeKey: String

        /// Always asks for offline access and for consent, so Google always
        /// hands out a refresh token.
        static let google = Service(
            provider: .googleDrive,
            authorizationEndpoint: "https://accounts.google.com/o/oauth2/v2/auth",
            tokenEndpoint: URL(string: "https://oauth2.googleapis.com/token")!,
            scopes: ["https://www.googleapis.com/auth/drive.file"],
            authorizationParameters: [("access_type", "offline"), ("prompt", "consent")],
            redirectSuffix: ":/oauth2redirect", clientIDKey: "GoogleClientID",
            redirectSchemeKey: "GoogleRedirectScheme")

        /// The `consumers` endpoint: personal accounts only. `offline_access`
        /// gives the refresh token.
        static let microsoft = Service(
            provider: .oneDrive,
            authorizationEndpoint: "https://login.microsoftonline.com/consumers/oauth2/v2.0/authorize",
            tokenEndpoint: URL(string: "https://login.microsoftonline.com/consumers/oauth2/v2.0/token")!,
            scopes: ["Files.ReadWrite.AppFolder", "offline_access"],
            authorizationParameters: [("prompt", "select_account")],
            redirectSuffix: "://auth", clientIDKey: "MicrosoftClientID", redirectSchemeKey: "MicrosoftRedirectScheme")

        /// The service of `provider`; nil if it doesn't use OAuth.
        static func of(_ provider: CloudProvider) -> Service? {
            switch provider {
            case .googleDrive: .google
            case .oneDrive: .microsoft
            case .webDAV, .iCloudDrive: nil
            }
        }

        /// Whether `granted`, the scope of a token response, includes the access
        /// to Leaf's files. Providers may qualify scopes with a resource URL.
        func grants(_ granted: String) -> Bool {
            let needed = scopes[0].lowercased()
            return granted.lowercased().split(separator: " ").contains { $0 == needed || $0.hasSuffix("/" + needed) }
        }
    }

    let service: Service
    let clientID: String
    /// The URL scheme of the redirect, registered in Info.plist.
    let redirectScheme: String
    private let verifier: String
    private let state: String

    /// The app's client for `service` from Info.plist; nil until the maintainer has set it up.
    static func configured(_ service: Service) -> OAuthSignIn? {
        let info = Bundle.main.infoDictionary
        guard let id = info?[service.clientIDKey] as? String,
            let scheme = info?[service.redirectSchemeKey] as? String, !id.isEmpty, !scheme.isEmpty
        else { return nil }
        return OAuthSignIn(service: service, clientID: id, redirectScheme: scheme)
    }

    init(service: Service, clientID: String, redirectScheme: String) {
        self.init(
            service: service, clientID: clientID, redirectScheme: redirectScheme, verifier: Self.random(),
            state: Self.random())
    }

    init(service: Service, clientID: String, redirectScheme: String, verifier: String, state: String) {
        self.service = service
        self.clientID = clientID
        self.redirectScheme = redirectScheme
        self.verifier = verifier
        self.state = state
    }

    private static func random() -> String {
        Data((0..<32).map { _ in UInt8.random(in: .min ... .max) }).base64URL
    }

    private var redirectURI: String { redirectScheme + service.redirectSuffix }

    /// The PKCE challenge of the verifier.
    var challenge: String { Data(SHA256.hash(data: Data(verifier.utf8))).base64URL }

    /// The page to open.
    var url: URL {
        var page = URLComponents(string: service.authorizationEndpoint)!
        page.queryItems =
            ([
                ("client_id", clientID), ("redirect_uri", redirectURI), ("response_type", "code"),
                ("scope", service.scopes.joined(separator: " ")), ("code_challenge", challenge),
                ("code_challenge_method", "S256"), ("state", state),
            ] + service.authorizationParameters).map { URLQueryItem(name: $0.0, value: $0.1) }
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
    /// the user unchecked the permission for the files, `Unreachable` without network.
    func refreshToken(from callback: URL) async throws -> String {
        let code = try code(from: callback)
        var request = URLRequest(url: service.tokenEndpoint)
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
        return try refreshToken(fromTokenResponse: data)
    }

    /// The refresh token in the token endpoint's answer, if it grants the files.
    func refreshToken(fromTokenResponse data: Data) throws -> String {
        let answer = try? JSONDecoder().decode(TokenResponse.self, from: data)
        guard let answer, let token = answer.refreshToken else { throw ConnectError.AccessDenied }
        guard service.grants(answer.scope) else { throw OAuthSignInError.missingPermission(service.provider) }
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
