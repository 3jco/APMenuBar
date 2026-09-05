// Throwaway spike: can macOS be told to associate with a *specific* BSSID?
// Separate bundle from APMenuBar so the real app stays untouched.

import AppKit
import CoreLocation
import CoreWLAN
import SwiftUI

@main
struct RoamSpikeApp: App {
    var body: some Scene {
        WindowGroup("Roam Spike") {
            SpikeView(model: SpikeModel())
                .frame(minWidth: 620, minHeight: 460)
        }
    }
}

@MainActor
final class SpikeModel: NSObject, ObservableObject {
    struct Row: Identifiable {
        let id = UUID()
        let ssid: String
        let bssid: String?
        let rssi: Int
        let channel: Int
        let network: CWNetwork
    }

    @Published var authorization = "checking…"
    @Published var rows: [Row] = []
    @Published var current = "?"
    @Published var password = ""
    @Published var disassociateFirst = true
    @Published var lines: [String] = []
    @Published var apNames = SpikeUniFi.Names()

    private let locationManager = CLLocationManager()
    private var interface: CWInterface? { CWWiFiClient.shared().interface() }

    override init() {
        super.init()
        locationManager.delegate = self
        updateAuthorization()
    }

    func requestAccess() { locationManager.requestWhenInUseAuthorization() }

    /// Exact BSSID -> AP name from the controller's vap_table.
    func loadAPNames() {
        Task { @MainActor in
            // The first call after a fresh build is often refused while the
            // Local Network grant settles, so retry before giving up.
            for attempt in 1...3 {
                do {
                    apNames = try await SpikeUniFi.accessPointNames()
                    log("controller: \(apNames.byBSSID.count) BSSIDs across "
                        + "\(apNames.byPrefix.count) APs")
                    return
                } catch {
                    log("controller lookup attempt \(attempt): \(error.localizedDescription)")
                    try? await Task.sleep(for: .seconds(2))
                }
            }
            log("give up — if this says 'offline', enable RoamSpike under "
                + "System Settings ▸ Privacy & Security ▸ Local Network")
        }
    }

    func updateAuthorization() {
        switch locationManager.authorizationStatus {
        case .notDetermined: authorization = "notDetermined — press Request access"
        case .denied: authorization = "denied — enable in Privacy & Security ▸ Location"
        case .restricted: authorization = "restricted"
        case .authorizedAlways, .authorizedWhenInUse: authorization = "authorized ✓"
        @unknown default: authorization = "unknown"
        }
        current = interface?.bssid() ?? "<redacted>"
    }

    /// Mirrored to a file so results can be read without fighting window focus.
    static let logPath = "/tmp/roamspike.log"

    func log(_ message: String) {
        lines.append(message)
        let line = ISO8601DateFormatter().string(from: Date()) + " " + message + "\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = FileHandle(forWritingAtPath: Self.logPath) {
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: URL(fileURLWithPath: Self.logPath))
        }
    }

    func scan() {
        guard let interface else { return log("no Wi-Fi interface") }
        do {
            let found = try interface.scanForNetworks(withSSID: nil)
            rows = found
                .map {
                    Row(ssid: $0.ssid ?? "-", bssid: $0.bssid,
                        rssi: $0.rssiValue, channel: $0.wlanChannel?.channelNumber ?? 0,
                        network: $0)
                }
                .sorted { $0.rssi > $1.rssi }
            let readable = rows.filter { $0.bssid?.isEmpty == false }.count
            log("scan: \(rows.count) networks, \(readable) with a readable BSSID")
            for row in rows {
                log(String(format: "  %-12@ %-18@ %-18@ %4d dBm ch%d",
                           apNames.name(for: row.bssid) as NSString,
                           row.ssid as NSString,
                           (row.bssid ?? "<redacted>") as NSString,
                           row.rssi, row.channel))
            }
        } catch {
            log("scan failed: \(error.localizedDescription)")
        }
        current = interface.bssid() ?? "<redacted>"
    }

    /// The question isn't whether associate() returns cleanly — it's where we land.
    func associate(_ row: Row) {
        guard let interface, let bssid = row.bssid else { return }
        log("associate → \(row.ssid) / \(bssid) (\(row.rssi) dBm, ch\(row.channel))")
        log("  password supplied: \(password.isEmpty ? "no" : "yes"), "
            + "disassociate first: \(disassociateFirst)")

        if disassociateFirst {
            // macOS generally refuses to re-associate while still joined to the
            // same SSID, so drop the link before asking for a specific BSSID.
            interface.disassociate()
            log("  disassociate() called")
            Thread.sleep(forTimeInterval: 1.5)
        }

        do {
            try interface.associate(to: row.network,
                                    password: password.isEmpty ? nil : password)
            log("  associate() returned without error")
        } catch {
            let nsError = error as NSError
            log("  associate() failed: \(error.localizedDescription) "
                + "[domain=\(nsError.domain) code=\(nsError.code)]")
            return
        }
        Task { @MainActor in
            for attempt in 1...12 {
                try? await Task.sleep(for: .seconds(1.5))
                let now = interface.bssid() ?? "<redacted>"
                current = now
                log("  t+\(attempt): \(now)")
                if now.lowercased() == bssid.lowercased() {
                    log("  >>> LANDED ON THE REQUESTED AP")
                    return
                }
            }
            log("  >>> did NOT land on \(bssid) — macOS chose its own AP")
        }
    }
}

extension SpikeModel: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in self.updateAuthorization() }
    }
}

struct SpikeView: View {
    @ObservedObject var model: SpikeModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Location: \(model.authorization)")
                Spacer()
                Button("Request access") { model.requestAccess() }
                Button("AP names") { model.loadAPNames() }
                Button("Scan") { model.scan() }
            }
            Text("Currently on: \(model.current)").font(.system(.body, design: .monospaced))

            HStack {
                Text("Wi-Fi password:")
                SecureField("PSK for AE1", text: $model.password)
                Toggle("Disassociate first", isOn: $model.disassociateFirst)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(model.rows) { row in
                        HStack(spacing: 10) {
                            Text(model.apNames.name(for: row.bssid))
                                .fontWeight(.semibold)
                                .frame(width: 96, alignment: .leading)
                            Text(row.ssid)
                                .frame(width: 110, alignment: .leading)
                            Text(row.bssid ?? "<redacted>")
                                .font(.system(.caption, design: .monospaced))
                                .frame(width: 140, alignment: .leading)
                            Text("\(row.rssi) dBm")
                                .frame(width: 64, alignment: .trailing)
                            Text("ch\(row.channel)")
                                .frame(width: 48, alignment: .trailing)
                            if row.bssid?.lowercased() == model.current.lowercased() {
                                Text("● current").foregroundStyle(.green)
                            }
                            Spacer(minLength: 8)
                            Button("Associate") { model.associate(row) }
                                .disabled(row.bssid == nil)
                        }
                        .padding(.vertical, 3)
                        Divider()
                    }
                }
            }
            .frame(minHeight: 200)

            ScrollView {
                Text(model.lines.joined(separator: "\n"))
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(minHeight: 120)
        }
        .padding(16)
        .onAppear {
            NSApplication.shared.activate(ignoringOtherApps: true)
            model.updateAuthorization()
            model.loadAPNames()
        }
    }
}
