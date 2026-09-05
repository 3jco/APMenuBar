import AppKit
import SwiftUI

@main
struct APMenuBarApp: App {
    @StateObject private var monitor = APMonitor.shared

    init() {
        Task { @MainActor in
            APMonitor.shared.start()
            guard !APMonitor.shared.config.isConfigured else { return }
            // Nothing works until it's configured, so open Settings unprompted
            // instead of leaving a stranger staring at "Set up".
            // Wait for the menu bar label to publish the openSettings action.
            for _ in 0..<25 {
                if SettingsWindowPresenter.shared.presentSettings() {
                    Log.write("first-run: opened settings")
                    return
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
            Log.write("first-run: settings action never became available")
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(monitor: monitor)
        } label: {
            MenuBarLabel(monitor: monitor)
        }
        Settings {
            SettingsView(monitor: monitor)
        }
    }
}

/// The menu bar label. Also the earliest live View in the app, so it is where
/// SwiftUI's openSettings action gets captured for use from non-View code.
struct MenuBarLabel: View {
    @ObservedObject var monitor: APMonitor
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HStack(spacing: 4) {
            if monitor.config.showMenuBarIcon, let icon = MenuBarIcon.image {
                Image(nsImage: icon)
            }
            Text(monitor.title)
        }
        .task { SettingsWindowPresenter.shared.openSettingsAction = { openSettings() } }
    }
}

/// The app icon scaled for the menu bar. Taken from the running app's icon, so
/// swapping the artwork via make-icon.sh updates this too.
enum MenuBarIcon {
    static let image: NSImage? = {
        // Prefer the bundled icns: applicationIconImage can be unset for an
        // LSUIElement app depending on when it is read.
        let bundled = Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
            .flatMap { NSImage(contentsOf: $0) }
        guard let source = bundled ?? NSApp.applicationIconImage else {
            Log.write("menu bar icon: no source image found")
            return nil
        }
        Log.write("menu bar icon: loaded from \(bundled != nil ? "bundle icns" : "app icon")")
        let size = NSSize(width: 16, height: 16)
        let scaled = NSImage(size: size)
        scaled.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        source.draw(in: NSRect(origin: .zero, size: size),
                    from: .zero, operation: .sourceOver, fraction: 1.0)
        scaled.unlockFocus()
        // Keep the artwork's colours instead of letting the menu bar tint it.
        scaled.isTemplate = false
        return scaled
    }()
}

/// An LSUIElement app is .accessory, and an .accessory app's windows do not
/// reliably become key — clicks inside them go nowhere. Switch to .regular
/// while Settings is open, then back once it closes.
@MainActor
final class SettingsWindowPresenter {
    static let shared = SettingsWindowPresenter()
    private var closeObservers: [NSObjectProtocol] = []

    /// Captured from a live View. NSApp.sendAction("showSettingsWindow:") reports
    /// success but creates no window, so this is the only reliable route from
    /// non-View code such as first-run setup.
    var openSettingsAction: (() -> Void)?

    func present(_ openSettings: () -> Void) {
        show { openSettings() }
    }

    /// The standard About panel: name, version, icon and copyright come from
    /// Info.plist, so the credits only carry what those don't say.
    /// Opens Settings from outside a View, where the SwiftUI action isn't available.
    /// Opens Settings from outside a View. Returns false if the action isn't
    /// available yet, so callers can wait rather than silently doing nothing.
    @discardableResult
    func presentSettings() -> Bool {
        guard let openSettingsAction else { return false }
        show { openSettingsAction() }
        return true
    }

    func presentAbout() {
        show {
            NSApp.orderFrontStandardAboutPanel(options: [.credits: Self.credits])
        }
    }

    private func show(_ open: () -> Void) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        open()

        // SwiftUI creates the window asynchronously and the action returns before
        // it exists, so poll briefly rather than checking once and giving up.
        focusPresentedWindow(attemptsLeft: 20)
    }

    private func focusPresentedWindow(attemptsLeft: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            // The status item is a visible window too, but can never become key.
            if let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeKey }) {
                window.makeKeyAndOrderFront(nil)
                self.watchForClose(of: window)
                return
            }
            if attemptsLeft > 1 {
                self.focusPresentedWindow(attemptsLeft: attemptsLeft - 1)
            } else {
                Log.write("no presentable window appeared; windows = "
                    + (NSApp.windows.isEmpty ? "<none>" : NSApp.windows.map {
                        "\($0.title.isEmpty ? "<untitled>" : $0.title)"
                        + "(\(type(of: $0)) visible=\($0.isVisible) "
                        + "key=\($0.canBecomeKey))"
                      }.joined(separator: ", ")))
            }
        }
    }

    private func watchForClose(of window: NSWindow) {
        let observer = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { _ in
            Task { @MainActor in
                // Settings and About can be open at once; stay .regular until the
                // last one closes, or the survivor loses focus.
                let othersOpen = NSApp.windows.contains {
                    $0 != window && $0.isVisible && $0.canBecomeKey
                }
                if !othersOpen { NSApp.setActivationPolicy(.accessory) }
            }
        }
        closeObservers.append(observer)
    }

    private static let credits: NSAttributedString = {
        let centred = NSMutableParagraphStyle()
        centred.alignment = .center

        let credits = NSMutableAttributedString(
            string: "Shows which UniFi access point this Mac is connected to.\n\n",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: centred,
            ])
        credits.append(NSAttributedString(
            string: "3jco.com",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .link: URL(string: "https://3jco.com") as Any,
                .paragraphStyle: centred,
            ]))
        return credits
    }()
}

struct MenuContent: View {
    @ObservedObject var monitor: APMonitor
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Text(headline)
        Text(monitor.detail)
        if let mac = monitor.clientMAC {
            Text("This Mac: \(mac)")
        }

        if case .needsCredential(let account) = monitor.state {
            Button("Copy keychain setup command") {
                let command = "security add-generic-password -a \(account) "
                    + "-s \(Config.keychainService) -U -w"
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            }
        }

        if !monitor.accessPoints.isEmpty {
            Divider()
            ForEach(monitor.accessPoints, id: \.mac) { accessPoint in
                Text(row(for: accessPoint))
            }
        }

        Divider()

        if let error = monitor.reroamError {
            Text("Re-roam failed: \(error)")
        }
        Button(monitor.isReroaming ? "Re-roaming…" : "Force re-roam") {
            monitor.forceReroam()
        }
        .disabled(monitor.isReroaming || monitor.clientMAC == nil)

        Button("Refresh now") { monitor.refreshNow() }
        Button("Settings…") {
            SettingsWindowPresenter.shared.present { openSettings() }
        }
        Toggle("Launch at login", isOn: Binding(
            get: { monitor.launchAtLogin },
            set: { monitor.setLaunchAtLogin($0) }
        ))

        Divider()

        Button("About APMenuBar") {
            SettingsWindowPresenter.shared.presentAbout()
        }
        Button("Quit") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    /// Menus can't right-align content, so pad to the widest name to line the
    /// checkmarks up as closely as a proportional font allows.
    private func row(for accessPoint: (mac: String, name: String, isCurrent: Bool)) -> String {
        let width = monitor.accessPoints.map(\.name.count).max() ?? 0
        let padded = accessPoint.name.padding(toLength: max(width, accessPoint.name.count),
                                              withPad: " ", startingAt: 0)
        return "\(padded)   \(accessPoint.isCurrent ? "✓" : " ")"
    }

    private var headline: String {
        switch monitor.state {
        case .connected(let name): return name
        case .starting: return "Starting…"
        case .offWiFi: return "Not on Wi-Fi"
        case .unresolved: return "Unknown AP"
        case .needsSetup: return "Not configured"
        case .needsCredential: return "No password in keychain"
        case .failure: return "Controller unreachable"
        }
    }
}

struct SettingsView: View {
    /// Result of a manual connection test, which is deliberately separate from
    /// the live monitor so trying settings out never disturbs the menu bar.
    private enum TestState {
        case idle
        case running
        case succeeded(String)
        case failed(String)
    }

    @ObservedObject var monitor: APMonitor

    @State private var host = ""
    @State private var port = ""
    @State private var site = ""
    @State private var username = ""
    @State private var password = ""
    @State private var test: TestState = .idle

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    Text("Controller")
                    TextField("unifi.local or 192.168.1.1", text: $host)
                }
                GridRow {
                    Text("Port")
                    TextField("8443", text: $port)
                }
                GridRow {
                    Text("Site ID")
                    TextField("default", text: $site)
                }
                GridRow {
                    Text("Username")
                    TextField("read-only admin", text: $username)
                }
                GridRow {
                    Text("Password")
                    SecureField(passwordPlaceholder, text: $password)
                }
            }
            .textFieldStyle(.roundedBorder)
            .onChange(of: editedConfig) { test = .idle }

            Toggle("Show icon in the menu bar", isOn: Binding(
                get: { monitor.config.showMenuBarIcon },
                set: { monitor.setShowMenuBarIcon($0) }
            ))

            Text("The password is stored in your login keychain, never in the "
                 + "app's settings. Use a local, read-only admin on the controller.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            HStack(spacing: 8) {
                Circle()
                    .fill(indicatorColor)
                    .frame(width: 8, height: 8)
                Text(statusLine)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 12)

                Button("Test") { runTest() }
                    .disabled(isTesting)
                Button("Apply") { apply() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear(perform: load)
    }

    // MARK: - Status

    private var statusLine: String {
        switch test {
        case .running: return "Testing…"
        case .succeeded(let message): return message
        case .failed(let message): return message
        case .idle:
            if case .connected(let name) = monitor.state { return "Connected — \(name)" }
            return monitor.detail
        }
    }

    private var indicatorColor: Color {
        switch test {
        case .running: return .yellow
        case .succeeded: return .green
        case .failed: return .red
        case .idle:
            switch monitor.state {
            case .connected: return .green
            case .starting: return .yellow
            case .offWiFi, .unresolved, .needsSetup: return .orange
            case .needsCredential, .failure: return .red
            }
        }
    }

    private var passwordPlaceholder: String {
        let account = username.trimmingCharacters(in: .whitespaces)
        guard !account.isEmpty, Keychain.hasPassword(account: account) else {
            return "required"
        }
        return "stored — type to replace"
    }

    private var isTesting: Bool {
        if case .running = test { return true }
        return false
    }

    // MARK: - Actions

    private var editedConfig: Config {
        var config = monitor.config
        config.host = host.trimmingCharacters(in: .whitespaces)
        config.port = Int(port) ?? 8443
        config.site = site.trimmingCharacters(in: .whitespaces)
        config.username = username.trimmingCharacters(in: .whitespaces)
        return config
    }

    private func load() {
        let config = monitor.config
        host = config.host
        port = String(config.port)
        site = config.site
        username = config.username
        test = .idle
    }

    /// Tries the entered settings without saving them or touching the monitor.
    private func runTest() {
        let config = editedConfig
        let typed = password.isEmpty ? nil : password
        test = .running
        Task { @MainActor in
            // Test what's on screen, including a password not yet saved.
            let client = UniFiClient(config: config, passwordOverride: typed)
            do {
                try await client.login()
                let names = try await client.accessPointNames()
                let interfaceName = WiFi.interfaceName
                if let mac = WiFi.linkAddress(of: interfaceName),
                   let association = try await client.association(forClient: mac) {
                    let name = names[association.apMac.lowercased()] ?? association.apMac
                    test = .succeeded("OK — this Mac is on \(name), \(names.count) APs on site")
                } else {
                    test = .succeeded("Logged in, \(names.count) APs — but this Mac isn't listed")
                }
            } catch {
                let message = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                test = .failed(message)
            }
        }
    }

    /// Saves, restarts the monitor with the new settings, and closes the window.
    private func apply() {
        let config = editedConfig
        if !password.isEmpty {
            Keychain.setPassword(password, account: config.username)
            password = ""
        }
        Log.write("settings applied: \(config.username)@\(config.host):\(config.port) site=\(config.site)")
        monitor.apply(config)
        closeWindow()
    }

    private func closeWindow() {
        let window = NSApp.keyWindow
            ?? NSApp.windows.first { $0.isVisible && $0.canBecomeKey }
        window?.performClose(nil)
    }
}
