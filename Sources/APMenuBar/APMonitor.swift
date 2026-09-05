import AppKit
import CoreWLAN
import Foundation
import ServiceManagement

@MainActor
final class APMonitor: NSObject, ObservableObject {
    static let shared = APMonitor()

    enum State: Equatable {
        case starting
        case offWiFi
        case connected(String)
        case unresolved(mac: String)
        case needsCredential(account: String)
        case failure(String)
    }

    @Published private(set) var state: State = .starting
    @Published private(set) var lastUpdate: Date?
    @Published private(set) var clientMAC: String?
    @Published private(set) var ssid: String?
    /// Whether CoreWLAN roam events actually reach us without Location access.
    @Published private(set) var roamEventsSeen = false
    @Published private(set) var config: Config = .load()

    /// Set while a force re-roam is in flight, cleared when it settles.
    @Published private(set) var isReroaming = false
    @Published private(set) var reroamError: String?

    var menuIsOpen = false {
        didSet { if menuIsOpen && !oldValue { refreshNow() } }
    }

    /// Every AP on the site, MAC -> display name.
    @Published private(set) var apNames: [String: String] = [:]
    /// MAC of the AP this Mac is currently associated with.
    @Published private(set) var currentAPMac: String?

    private var client: UniFiClient
    private var pollTask: Task<Void, Never>?
    private var apNamesFetched: Date?
    private var lastChange: Date?
    private var displayAsleep = false

    override init() {
        let config = Config.load()
        self.config = config
        self.client = UniFiClient(config: config)
        super.init()
    }

    // MARK: - Presentation

    /// What sits in the menu bar. Deliberately just the name.
    var title: String {
        switch state {
        case .starting: return "…"
        case .offWiFi: return "—"
        case .connected(let name): return name
        case .unresolved: return "?"
        case .needsCredential, .failure: return "!"
        }
    }

    /// Access points sorted for display, with the current one flagged.
    var accessPoints: [(mac: String, name: String, isCurrent: Bool)] {
        apNames
            .map { (mac: $0.key, name: $0.value, isCurrent: $0.key == currentAPMac) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var detail: String {
        switch state {
        case .starting:
            return "Contacting controller…"
        case .offWiFi:
            return "Wi-Fi is off or not associated"
        case .connected:
            return ssid.map { "on \($0)" } ?? "Connected"
        case .unresolved(let mac):
            return "Controller doesn't know \(mac)"
        case .needsCredential(let account):
            return "No keychain password for \(account)"
        case .failure(let message):
            return message
        }
    }

    // MARK: - Lifecycle

    func start() {
        Log.write("start()")
        guard pollTask == nil else { return }
        observeSystemEvents()
        startRoamEvents()

        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.tick()
                let interval = self.pollInterval
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// Drops the Wi-Fi link so macOS re-selects an AP.
    ///
    /// The roaming spike showed that `associate(to:)` cannot target a specific
    /// BSSID — macOS ignores it and picks for itself — but a plain disassociate
    /// does reliably break a sticky association. Doing it client-side needs no
    /// controller write role and no Location access.
    func forceReroam() {
        guard !isReroaming else { return }
        guard let interface = CWWiFiClient.shared().interface() else {
            reroamError = "No Wi-Fi interface"
            return
        }
        isReroaming = true
        reroamError = nil
        Task { @MainActor in
            defer { isReroaming = false }
            interface.disassociate()
            Log.write("disassociated — waiting for macOS to re-select")
            lastChange = Date()
            // Rejoin plus controller propagation takes a few seconds.
            try? await Task.sleep(for: .seconds(6))
            await tick()
            if case .connected(let name) = state {
                Log.write("re-roam settled on \(name)")
            }
        }
    }

    /// Display-only preference, so it takes effect immediately rather than
    /// waiting for Apply like the connection settings do.
    func setShowMenuBarIcon(_ show: Bool) {
        var updated = config
        updated.showMenuBarIcon = show
        config = updated
        updated.save()
    }

    func refreshNow() {
        Task { await tick() }
    }

    func apply(_ newConfig: Config) {
        config = newConfig
        newConfig.save()
        client = UniFiClient(config: newConfig)
        apNames = [:]
        apNamesFetched = nil
        state = .starting
        refreshNow()
    }

    private var pollInterval: Duration {
        if displayAsleep { return .seconds(60) }
        if menuIsOpen { return .seconds(5) }
        // Failures right after launch are often the Local Network grant settling;
        // retry sooner so a transient error isn't visible for half a minute.
        if case .failure = state { return .seconds(10) }
        // Stay responsive for a minute after a roam, then settle down.
        if let lastChange, Date().timeIntervalSince(lastChange) < 60 { return .seconds(5) }
        return .seconds(30)
    }

    // MARK: - The actual check

    private func tick() async {
        guard !displayAsleep || menuIsOpen else { return }

        let interfaceName = WiFi.interfaceName
        guard WiFi.isRunning(interfaceName) else {
            clientMAC = nil
            ssid = nil
            currentAPMac = nil
            state = .offWiFi
            return
        }
        guard let mac = WiFi.linkAddress(of: interfaceName) else {
            state = .failure("No Wi-Fi interface found")
            return
        }
        clientMAC = mac

        do {
            guard let association = try await client.association(forClient: mac) else {
                ssid = nil
                currentAPMac = nil
                state = .unresolved(mac: mac)
                lastUpdate = Date()
                return
            }
            ssid = association.ssid

            let apMac = association.apMac.lowercased()
            if apNames[apMac] == nil || namesAreStale {
                apNames = try await client.accessPointNames()
                apNamesFetched = Date()
            }

            currentAPMac = apMac
            let name = apNames[apMac] ?? apMac
            if case .connected(let previous) = state, previous != name {
                lastChange = Date()
            }
            state = .connected(name)

            // Trust-on-first-use: remember whatever certificate we just accepted.
            if config.fingerprint.isEmpty, let seen = client.observedFingerprint {
                var updated = config
                updated.fingerprint = seen
                config = updated
                updated.save()
            }
        } catch UniFiError.noCredential(let account) {
            // Distinct from a network failure: nothing about the controller is
            // wrong, so don't send anyone debugging the network.
            Log.write("no keychain entry for \(account)")
            state = .needsCredential(account: account)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            Log.write("check failed: \(message) — \(error)")
            state = .failure(message)
        }
        lastUpdate = Date()
        if state != loggedState {
            loggedState = state
            Log.write("state = \(state)")
        }
    }

    private var loggedState: State = .starting

    private var namesAreStale: Bool {
        guard let apNamesFetched else { return true }
        return Date().timeIntervalSince(apNamesFetched) > 3600
    }

    // MARK: - Wake / sleep

    private func observeSystemEvents() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didWakeNotification,
                           object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshNow() }
        }
        center.addObserver(forName: NSWorkspace.screensDidSleepNotification,
                           object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.displayAsleep = true }
        }
        center.addObserver(forName: NSWorkspace.screensDidWakeNotification,
                           object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.displayAsleep = false
                self?.refreshNow()
            }
        }
    }

    // MARK: - Roam events
    //
    // Subscribing to the BSSID-change *event* does not read the BSSID value, so
    // it should not require Location authorization. If it works we get instant
    // roam detection; if it never fires we simply fall back to polling.
    private func startRoamEvents() {
        let wifi = CWWiFiClient.shared()
        wifi.delegate = self
        do {
            try wifi.startMonitoringEvent(with: .bssidDidChange)
            try wifi.startMonitoringEvent(with: .linkDidChange)
        } catch {
            Log.write("CoreWLAN event monitoring unavailable: \(error)")
        }
    }

    fileprivate func roamDetected() {
        roamEventsSeen = true
        lastChange = Date()
        refreshNow()
    }

    // MARK: - Login item

    var launchAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Log.write("login item change failed: \(error)")
        }
        objectWillChange.send()
    }
}

extension APMonitor: CWEventDelegate {
    nonisolated func bssidDidChangeForWiFiInterface(withName interfaceName: String) {
        Task { @MainActor in self.roamDetected() }
    }

    nonisolated func linkDidChangeForWiFiInterface(withName interfaceName: String) {
        Task { @MainActor in self.roamDetected() }
    }
}
