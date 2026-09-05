import Foundation

/// Connection settings. Deliberately empty on a fresh install: baking in one
/// person's controller address makes the app fail confusingly for everyone else.
struct Config: Equatable {
    var host: String
    var port: Int
    var site: String
    var username: String
    /// SHA-256 of the controller's leaf certificate, lowercase hex, no separators.
    /// Empty means "trust on first use and remember what we saw".
    var fingerprint: String
    /// Whether the app icon sits before the AP name in the menu bar.
    var showMenuBarIcon: Bool

    static let keychainService = "unifi-apmenubar"

    /// Nothing to connect to until both of these are known. The site id and port
    /// keep useful defaults, since they are the same on nearly every controller.
    var isConfigured: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty
            && !username.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private enum Key {
        static let host = "controllerHost"
        static let port = "controllerPort"
        static let site = "siteID"
        static let username = "username"
        static let fingerprint = "certFingerprint"
        static let showIcon = "showMenuBarIcon"
    }

    static func load() -> Config {
        let d = UserDefaults.standard
        let port = d.integer(forKey: Key.port)
        return Config(
            host: d.string(forKey: Key.host) ?? "",
            port: port == 0 ? 8443 : port,
            site: d.string(forKey: Key.site) ?? "default",
            username: d.string(forKey: Key.username) ?? "",
            fingerprint: d.string(forKey: Key.fingerprint) ?? "",
            // bool(forKey:) can't distinguish "absent" from "false", so default to on.
            showMenuBarIcon: d.object(forKey: Key.showIcon) as? Bool ?? true
        )
    }

    func save() {
        let d = UserDefaults.standard
        d.set(host, forKey: Key.host)
        d.set(port, forKey: Key.port)
        d.set(site, forKey: Key.site)
        d.set(username, forKey: Key.username)
        d.set(fingerprint, forKey: Key.fingerprint)
        d.set(showMenuBarIcon, forKey: Key.showIcon)
    }

    var baseURL: URL? {
        guard !host.isEmpty else { return nil }
        return URL(string: "https://\(host):\(port)")
    }
}

enum Keychain {
    /// Reads the controller password. The app writes this itself from Settings;
    /// an entry made by the `security` CLI under the same service also works.
    static func password(account: String, service: String = Config.keychainService) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            Log.write("keychain lookup for \(service)/\(account) failed, OSStatus \(status)")
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Attribute-only lookup, so checking for a stored password doesn't prompt.
    static func hasPassword(account: String, service: String = Config.keychainService) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess
    }

    @discardableResult
    static func setPassword(
        _ password: String, account: String, service: String = Config.keychainService
    ) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let data = Data(password.utf8)

        let updated = SecItemUpdate(query as CFDictionary,
                                    [kSecValueData as String: data] as CFDictionary)
        if updated == errSecSuccess { return true }
        if updated == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            let added = SecItemAdd(insert as CFDictionary, nil)
            if added != errSecSuccess { Log.write("keychain add failed, OSStatus \(added)") }
            return added == errSecSuccess
        }
        Log.write("keychain update failed, OSStatus \(updated)")
        return false
    }
}
