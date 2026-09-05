// Spike: can macOS be made to associate with a *specific* BSSID?
//
//   swift spike/roam.swift list          - scan and show every BSSID in range
//   swift spike/roam.swift current       - what we're on now
//   swift spike/roam.swift to <BSSID>    - try to associate with that AP
//
// Scanning and reading BSSIDs require Location authorization attributed to the
// app running this (Terminal, iTerm, ...). If BSSIDs come back <redacted>, grant
// that app Location access in System Settings > Privacy & Security > Location.
//
// Wi-Fi password: $WIFI_PASS, else the spike tries nil (macOS may reuse the
// system keychain entry for a known network).

import CoreWLAN
import Foundation

let args = CommandLine.arguments
let command = args.count > 1 ? args[1] : "list"

guard let interface = CWWiFiClient.shared().interface() else {
    print("no Wi-Fi interface"); exit(1)
}

func describe(_ network: CWNetwork) -> String {
    let ssid = network.ssid ?? "-"
    let bssid = network.bssid ?? "<redacted>"
    let channel = network.wlanChannel?.channelNumber ?? 0
    let band = network.wlanChannel?.channelBand == .band5GHz ? "5GHz"
        : network.wlanChannel?.channelBand == .band2GHz ? "2.4GHz" : "?"
    return String(format: "  %-18@ %-20@ %4d dBm  ch%-4d %@",
                  ssid as NSString, bssid as NSString,
                  network.rssiValue, channel, band as NSString)
}

func scan() -> [CWNetwork] {
    do {
        let found = try interface.scanForNetworks(withSSID: nil)
        return found.sorted { $0.rssiValue > $1.rssiValue }
    } catch {
        print("scan failed: \(error.localizedDescription)")
        print("(this is usually missing Location authorization)")
        return []
    }
}

func printCurrent() {
    let ssid = interface.ssid() ?? "<redacted or not associated>"
    let bssid = interface.bssid() ?? "<redacted or not associated>"
    print("interface : \(interface.interfaceName ?? "?")")
    print("ssid      : \(ssid)")
    print("bssid     : \(bssid)")
    print("rssi      : \(interface.rssiValue()) dBm")
}

switch command {
case "current":
    printCurrent()

case "list":
    printCurrent()
    print("\nscanning…")
    let networks = scan()
    print("\(networks.count) networks:")
    for network in networks { print(describe(network)) }
    let readable = networks.filter { $0.bssid != nil && !($0.bssid!.isEmpty) }.count
    print("\nBSSIDs readable: \(readable)/\(networks.count)")
    if readable == 0 {
        print("=> Location authorization is missing; BSSID targeting is impossible without it.")
    }

case "to":
    guard args.count > 2 else { print("usage: to <BSSID>"); exit(1) }
    let wanted = args[2].lowercased()
    printCurrent()
    print("\nscanning for \(wanted)…")
    let networks = scan()
    guard let target = networks.first(where: { $0.bssid?.lowercased() == wanted }) else {
        print("BSSID \(wanted) not visible. In range right now:")
        for network in networks where network.bssid != nil { print(describe(network)) }
        exit(1)
    }
    print("found: \(describe(target))")

    let password = ProcessInfo.processInfo.environment["WIFI_PASS"]
    do {
        try interface.associate(to: target, password: password)
        print("associate() returned without error")
    } catch {
        print("associate() failed: \(error.localizedDescription)")
        exit(1)
    }

    // The real question isn't whether the call succeeds, but where we land.
    for attempt in 1...10 {
        Thread.sleep(forTimeInterval: 1.5)
        let now = interface.bssid()?.lowercased() ?? "<redacted>"
        print("  t+\(attempt): bssid = \(now)")
        if now == wanted {
            print("\n>>> LANDED ON THE REQUESTED AP")
            exit(0)
        }
    }
    print("\n>>> did NOT land on \(wanted) - macOS chose its own AP")

default:
    print("unknown command \(command)")
}
