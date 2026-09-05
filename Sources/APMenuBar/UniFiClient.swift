import CryptoKit
import Foundation
import os

enum UniFiError: LocalizedError {
    case badURL
    case noCredential(account: String)
    case certificateMismatch(expected: String, got: String)
    case http(Int)
    case decode(String)
    case command(String)

    var errorDescription: String? {
        switch self {
        case .badURL:
            return "Invalid controller address"
        case .noCredential(let account):
            return "No password in keychain for \(account)"
        case .certificateMismatch:
            return "Controller certificate changed"
        case .http(401), .http(400):
            return "Login rejected"
        case .http(let code):
            return "Controller returned HTTP \(code)"
        case .decode:
            return "Unexpected response from controller"
        case .command(let message) where message.contains("NoPermission"):
            return "Account is read-only — needs a write role"
        case .command(let message):
            return message
        }
    }
}

/// Pins the controller's self-signed leaf certificate by SHA-256 rather than
/// disabling certificate validation outright.
final class PinnedSessionDelegate: NSObject, URLSessionDelegate {
    private let expected: String
    /// Written from the URLSession delegate queue, read from the main actor.
    private let observedState = OSAllocatedUnfairLock<String?>(initialState: nil)

    init(expected: String) {
        self.expected = expected
    }

    var observed: String? { observedState.withLock { $0 } }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first
        else { return (.cancelAuthenticationChallenge, nil) }

        let der = SecCertificateCopyData(leaf) as Data
        let fingerprint = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()

        observedState.withLock { $0 = fingerprint }

        // Empty expectation means trust-on-first-use; the caller records what we saw.
        if expected.isEmpty || expected == fingerprint {
            return (.useCredential, URLCredential(trust: trust))
        }
        return (.cancelAuthenticationChallenge, nil)
    }
}

final class UniFiClient {
    struct Association {
        let apMac: String
        let ssid: String?
        let signal: Int?
    }

    private struct Envelope<T: Decodable>: Decodable { let data: [T] }

    private struct Station: Decodable {
        let mac: String?
        let apMac: String?
        let essid: String?
        let signal: Int?
        let isWired: Bool?
    }

    private struct Device: Decodable {
        let mac: String?
        let name: String?
        let model: String?
        let type: String?
    }

    private struct Meta: Decodable {
        struct Body: Decodable {
            let rc: String
            let msg: String?
        }
        let meta: Body
    }

    private struct Command: Encodable {
        let cmd: String
        let mac: String
    }

    private struct LoginBody: Encodable {
        let username: String
        let password: String
        let rememberMe: Bool
    }

    let config: Config
    private let session: URLSession
    private let delegate: PinnedSessionDelegate
    private var authenticated = false

    init(config: Config) {
        self.config = config
        self.delegate = PinnedSessionDelegate(expected: config.fingerprint)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpShouldSetCookies = true
        self.session = URLSession(configuration: configuration,
                                  delegate: delegate,
                                  delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    /// What the server actually presented, for trust-on-first-use and diagnostics.
    var observedFingerprint: String? { delegate.observed }

    private func url(_ path: String) throws -> URL {
        guard let base = config.baseURL, let url = URL(string: path, relativeTo: base) else {
            throw UniFiError.badURL
        }
        return url
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw UniFiError.http(-1) }
            return (data, http)
        } catch let error as URLError {
            // A pin failure surfaces as a cancelled/secure-connection URLError; turn
            // it into something the menu can explain.
            if let seen = delegate.observed,
               !config.fingerprint.isEmpty,
               seen != config.fingerprint {
                throw UniFiError.certificateMismatch(expected: config.fingerprint, got: seen)
            }
            throw error
        }
    }

    func login() async throws {
        guard let password = Keychain.password(account: config.username) else {
            throw UniFiError.noCredential(account: config.username)
        }
        var request = URLRequest(url: try url("/api/login"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            LoginBody(username: config.username, password: password, rememberMe: true))

        let (_, http) = try await send(request)
        guard http.statusCode == 200 else { throw UniFiError.http(http.statusCode) }
        authenticated = true
    }

    private func get<T: Decodable>(_ path: String) async throws -> [T] {
        if !authenticated { try await login() }

        var request = URLRequest(url: try url(path))
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        var (data, http) = try await send(request)
        if http.statusCode == 401 {
            authenticated = false
            try await login()
            (data, http) = try await send(request)
        }
        guard http.statusCode == 200 else { throw UniFiError.http(http.statusCode) }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(Envelope<T>.self, from: data).data
        } catch {
            throw UniFiError.decode("\(path): \(error)")
        }
    }

    /// The AP this client is associated with, or nil if the controller doesn't
    /// know this MAC (rotated private address, wired, or wrong site).
    func association(forClient mac: String) async throws -> Association? {
        let stations: [Station] = try await get("/api/s/\(config.site)/stat/sta")
        let target = mac.lowercased()
        guard let match = stations.first(where: { $0.mac?.lowercased() == target }),
              let apMac = match.apMac, !apMac.isEmpty
        else { return nil }
        return Association(apMac: apMac, ssid: match.essid, signal: match.signal)
    }

    /// MAC -> display name for every access point on the site.
    func accessPointNames() async throws -> [String: String] {
        let devices: [Device] = try await get("/api/s/\(config.site)/stat/device")
        var names: [String: String] = [:]
        for device in devices where device.type == "uap" {
            guard let mac = device.mac?.lowercased() else { continue }
            names[mac] = device.name ?? device.model ?? mac
        }
        return names
    }
}
