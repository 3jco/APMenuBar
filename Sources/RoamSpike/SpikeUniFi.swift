// Minimal, self-contained controller lookup for the spike, so the APMenuBar
// sources stay untouched. Throwaway code — not the app's client.

import CryptoKit
import Foundation
import os

enum SpikeUniFi {
    // Point the spike at your own controller:
    //   UNIFI_HOST=10.0.0.2:8443 UNIFI_USER=viewer open build/RoamSpike.app
    private static let env = ProcessInfo.processInfo.environment
    static let host = env["UNIFI_HOST"] ?? "unifi.local:8443"
    static let site = env["UNIFI_SITE"] ?? "default"
    static let username = env["UNIFI_USER"] ?? "admin"
    /// Empty means trust whatever certificate the controller presents.
    static let fingerprint = env["UNIFI_FINGERPRINT"] ?? ""

    /// Exact BSSID -> AP name, plus a base-MAC prefix fallback for any radio
    /// the controller didn't list.
    struct Names {
        var byBSSID: [String: String] = [:]
        var byPrefix: [String: String] = [:]

        func name(for bssid: String?) -> String {
            guard let bssid = bssid?.lowercased(), !bssid.isEmpty else { return "" }
            if let exact = byBSSID[bssid] { return exact }
            let prefix = bssid.split(separator: ":").prefix(5).joined(separator: ":")
            return byPrefix[prefix] ?? ""
        }
    }

    private final class Pinner: NSObject, URLSessionDelegate {
        func urlSession(
            _ session: URLSession, didReceive challenge: URLAuthenticationChallenge
        ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
            guard let trust = challenge.protectionSpace.serverTrust,
                  let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
                  let leaf = chain.first
            else { return (.cancelAuthenticationChallenge, nil) }
            let der = SecCertificateCopyData(leaf) as Data
            let seen = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
            guard fingerprint.isEmpty || seen == fingerprint else {
                return (.cancelAuthenticationChallenge, nil)
            }
            return (.useCredential, URLCredential(trust: trust))
        }
    }

    private struct Envelope: Decodable {
        struct Device: Decodable {
            struct VAP: Decodable {
                let bssid: String?
            }
            let mac: String?
            let name: String?
            let model: String?
            let type: String?
            let vapTable: [VAP]?
        }
        let data: [Device]
    }

    private struct Login: Encodable {
        let username: String
        let password: String
        let rememberMe: Bool
    }

    static func password() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "unifi-apmenubar",
            kSecAttrAccount as String: username,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func accessPointNames() async throws -> Names {
        guard let password = password() else {
            throw NSError(domain: "spike", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "no keychain password for \(username)",
            ])
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .always
        configuration.timeoutIntervalForRequest = 8
        let session = URLSession(configuration: configuration,
                                 delegate: Pinner(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        var login = URLRequest(url: URL(string: "https://\(host)/api/login")!)
        login.httpMethod = "POST"
        login.setValue("application/json", forHTTPHeaderField: "Content-Type")
        login.httpBody = try JSONEncoder().encode(
            Login(username: username, password: password, rememberMe: true))
        let (_, loginResponse) = try await session.data(for: login)
        guard (loginResponse as? HTTPURLResponse)?.statusCode == 200 else {
            throw NSError(domain: "spike", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "controller login failed",
            ])
        }

        let url = URL(string: "https://\(host)/api/s/\(site)/stat/device")!
        let (data, _) = try await session.data(from: url)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let devices = try decoder.decode(Envelope.self, from: data).data

        var names = Names()
        for device in devices where device.type == "uap" {
            guard let mac = device.mac?.lowercased() else { continue }
            let label = device.name ?? device.model ?? mac
            names.byPrefix[mac.split(separator: ":").prefix(5).joined(separator: ":")] = label
            for vap in device.vapTable ?? [] {
                if let bssid = vap.bssid?.lowercased(), !bssid.isEmpty {
                    names.byBSSID[bssid] = label
                }
            }
        }
        return names
    }
}
