import CoreWLAN
import Darwin
import Foundation

enum WiFi {
    /// The Wi-Fi interface name (usually en0). Reading this is not privacy-gated;
    /// only the BSSID/SSID *values* require Location authorization.
    static var interfaceName: String {
        CWWiFiClient.shared().interface()?.interfaceName ?? "en0"
    }

    /// Current on-air link-layer address of `iface`.
    ///
    /// This is deliberately read fresh on every poll: with Private Wi-Fi Address
    /// enabled the MAC the controller sees is randomized, and macOS can rotate it.
    /// The hardware address from `networksetup` would not match the controller.
    static func linkAddress(of iface: String) -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return nil }
        defer { freeifaddrs(head) }

        var cursor = head
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard String(cString: entry.pointee.ifa_name) == iface,
                  let sa = entry.pointee.ifa_addr,
                  sa.pointee.sa_family == UInt8(AF_LINK)
            else { continue }

            let dl = UnsafeRawPointer(sa).assumingMemoryBound(to: sockaddr_dl.self).pointee
            let nameLen = Int(dl.sdl_nlen)
            guard dl.sdl_alen == 6,
                  nameLen + 6 <= MemoryLayout.size(ofValue: dl.sdl_data)
            else { continue }

            var mac: [UInt8] = []
            withUnsafeBytes(of: dl.sdl_data) { raw in
                for i in 0..<6 { mac.append(raw[nameLen + i]) }
            }
            return mac.map { String(format: "%02x", $0) }.joined(separator: ":")
        }
        return nil
    }

    /// True when the interface is up and associated.
    static func isRunning(_ iface: String) -> Bool {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return false }
        defer { freeifaddrs(head) }

        var cursor = head
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard String(cString: entry.pointee.ifa_name) == iface,
                  let sa = entry.pointee.ifa_addr,
                  sa.pointee.sa_family == UInt8(AF_LINK)
            else { continue }
            let flags = Int32(entry.pointee.ifa_flags)
            return (flags & IFF_UP) != 0 && (flags & IFF_RUNNING) != 0
        }
        return false
    }
}
