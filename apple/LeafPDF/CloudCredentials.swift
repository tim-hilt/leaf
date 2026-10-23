import Foundation
import Security

/// The details of a Connected WebDAV server.
struct WebDAVAccount: Equatable, Sendable {
    let url: String
    let username: String
    let password: String
}

/// What a Connection to a Cloud Provider needs to resume after a relaunch.
enum CloudCredential: Equatable, Sendable {
    case webDAV(WebDAVAccount)
    /// The grant of iCloud Drive: what `ICloudGrant` needs to get its access back.
    case iCloudDrive(bookmark: Data)
    /// Google Drive or OneDrive: the refresh token of the OAuth client, and the
    /// account it belongs to (empty if the provider didn't tell), which Settings shows.
    case oauth(CloudProvider, refreshToken: String, account: String)
}

/// Where the credentials of the Connected Cloud Provider are kept on this
/// Device: plain details in `defaults`, secrets in the Keychain under
/// `service`; each Cloud Provider has its own keys. Only the latest Connection
/// is kept. Never synced. Losing any part means not Connected.
struct CloudCredentials {
    let defaults: UserDefaults
    let service: String

    private static let urlKey = "cloud.webdav.url"
    private static let usernameKey = "cloud.webdav.username"
    private static let bookmarkKey = "cloud.icloud.bookmark"
    private static let webDAVPassword = "WebDAV password"

    /// Where a provider behind OAuth keeps its account (in `defaults`) and its
    /// refresh token (in the Keychain). Providers have their own, so a left-over
    /// of one never passes for another's.
    private static let oauthKeys: [CloudProvider: (accountKey: String, tokenName: String)] = [
        .googleDrive: ("cloud.google.account", "Google refresh token"),
        .oneDrive: ("cloud.onedrive.account", "OneDrive refresh token"),
    ]

    /// What `save` kept; nil if there is none or a part is missing.
    func load() -> CloudCredential? {
        if let bookmark = defaults.data(forKey: Self.bookmarkKey) { return .iCloudDrive(bookmark: bookmark) }
        for (provider, keys) in Self.oauthKeys {
            if let account = defaults.string(forKey: keys.accountKey) {
                return secret(keys.tokenName).map { .oauth(provider, refreshToken: $0, account: account) }
            }
        }
        guard let url = defaults.string(forKey: Self.urlKey),
            let username = defaults.string(forKey: Self.usernameKey),
            let password = secret(Self.webDAVPassword)
        else { return nil }
        return .webDAV(WebDAVAccount(url: url, username: username, password: password))
    }

    /// Replaces what was saved, of any Cloud Provider. False if the Keychain
    /// refused a secret; then nothing is saved.
    @discardableResult
    func save(_ credential: CloudCredential) -> Bool {
        forget()
        switch credential {
        case .webDAV(let account):
            guard store(account.password, as: Self.webDAVPassword) else { return false }
            defaults.set(account.url, forKey: Self.urlKey)
            defaults.set(account.username, forKey: Self.usernameKey)
            return true
        case .iCloudDrive(let bookmark):
            defaults.set(bookmark, forKey: Self.bookmarkKey)
            return true
        case .oauth(let provider, let refreshToken, let account):
            guard let keys = Self.oauthKeys[provider], store(refreshToken, as: keys.tokenName) else { return false }
            defaults.set(account, forKey: keys.accountKey)
            return true
        }
    }

    /// Deletes everything saved, of every Cloud Provider.
    func forget() {
        defaults.removeObject(forKey: Self.urlKey)
        defaults.removeObject(forKey: Self.usernameKey)
        defaults.removeObject(forKey: Self.bookmarkKey)
        SecItemDelete(query(Self.webDAVPassword) as CFDictionary)
        for keys in Self.oauthKeys.values {
            defaults.removeObject(forKey: keys.accountKey)
            SecItemDelete(query(keys.tokenName) as CFDictionary)
        }
    }

    private func store(_ secret: String, as name: String) -> Bool {
        var item = query(name)
        item[kSecValueData] = Data(secret.utf8)
        item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    private func secret(_ name: String) -> String? {
        var item = query(name)
        item[kSecReturnData] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(item as CFDictionary, &result) == errSecSuccess, let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func query(_ name: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: name]
    }
}
