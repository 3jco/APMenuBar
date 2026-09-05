import Foundation

/// Minimal file logger. Agent apps have no console, and NSLog output is awkward
/// to retrieve from the unified log, so mirror diagnostics to a file.
enum Log {
    static let path = "/tmp/apmenubar.log"

    static func write(_ message: String) {
        NSLog("APMenuBar: %@", message)
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = FileHandle(forWritingAtPath: path) {
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}
