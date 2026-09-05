import Foundation

/// User-editable connection settings. Defaults match the controller discovered
/// during the spike, so a fresh install works with no configuration.
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

    /// Captured from https://192.168.0.9:8443 (CN=UniFi, Ubiquiti self-signed).
    static let knownFingerprint =
        "c542bc9996d0a3db2b793437d4a7ac166046a9f9e4478abd06b8d3a27fe2dadd"

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
            host: d.string(forKey: Key.host) ?? "192.168.0.9",
            port: port == 0 ? 8443 : port,
            site: d.string(forKey: Key.site) ?? "default",
            username: d.string(forKey: Key.username) ?? "API_access",
            fingerprint: d.string(forKey: Key.fingerprint) ?? Config.knownFingerprint,
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

    var baseURL: URL? { URL(string: "https://\(host):\(port)") }
}

enum Keychain {
    /// Reads the password stored by:
    ///   security add-generic-password -a <account> -s unifi-apmenubar -w
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
}
