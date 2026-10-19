import Foundation
import Security

/// The details of a Connected WebDAV server.
struct WebDAVAccount: Equatable, Sendable {
    let url: String
    let username: String
    let password: String
}

/// Where a Connected WebDAV server's details are kept on this Device: Server
/// URL and username in `defaults`, the password in the Keychain under `service`.
/// Never synced. Losing any part means not Connected.
struct CloudCredentials {
    let defaults: UserDefaults
    let service: String

    private static let urlKey = "cloud.webdav.url"
    private static let usernameKey = "cloud.webdav.username"
    private static let account = "WebDAV password"

    /// The account saved by `save`; nil if there is none or a part is missing.
    func load() -> WebDAVAccount? {
        guard let url = defaults.string(forKey: Self.urlKey),
            let username = defaults.string(forKey: Self.usernameKey),
            let password = password()
        else { return nil }
        return WebDAVAccount(url: url, username: username, password: password)
    }

    /// Replaces the saved account. False if the Keychain refused the password;
    /// then nothing is saved.
    @discardableResult
    func save(_ account: WebDAVAccount) -> Bool {
        forget()
        var item = query
        item[kSecValueData] = Data(account.password.utf8)
        item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { return false }
        defaults.set(account.url, forKey: Self.urlKey)
        defaults.set(account.username, forKey: Self.usernameKey)
        return true
    }

    /// Deletes everything saved.
    func forget() {
        defaults.removeObject(forKey: Self.urlKey)
        defaults.removeObject(forKey: Self.usernameKey)
        SecItemDelete(query as CFDictionary)
    }

    private func password() -> String? {
        var item = query
        item[kSecReturnData] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(item as CFDictionary, &result) == errSecSuccess, let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private var query: [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: Self.account]
    }
}
