import Foundation
import SwiftUI
import UIKit

enum CaptureStage: Equatable {
    case requesting
    case waiting

    var text: String {
        switch self {
        case .requesting: return "Asking the camera…"
        case .waiting: return "Waiting for the new still…"
        }
    }
}

struct StillImage {
    let image: UIImage
    let capturedAt: String?
}

@MainActor
final class NetworkStore: ObservableObject {
    enum Link: Equatable {
        case connecting
        case connected(GatewayEndpoint)
        case unreachable
        case demo

        var path: ConnectionPath? {
            if case .connected(let ep) = self { return ep.path }
            return nil
        }
    }

    enum RefreshReason { case launch, user, timer, pathChange }

    static let defaultLAN = "http://192.168.7.103:8801"
    static let defaultOverlay = "http://100.96.1.18:8801"
    static let defaultName = "My Private Network"
    private static let offlineLAN = "192.0.2.10"
    private static let offlineOverlay = "198.51.100.10"

    enum PairingState: Equatable {
        case idle
        case working
        case failed(String)
    }

    @Published private(set) var link: Link = .connecting
    @Published private(set) var network: GatewayNetwork?
    @Published private(set) var devices: [Device] = []
    @Published private(set) var events: [NetworkEvent] = []
    @Published private(set) var lastSuccess: Date?
    @Published private(set) var lastError: GatewayError?
    @Published private(set) var lastProbes: [ProbeResult] = []
    @Published private(set) var latencyMs: Int?
    @Published private(set) var isRefreshing = false
    @Published private(set) var captureStage: [String: CaptureStage] = [:]
    @Published private(set) var outputBusy: String?
    @Published private(set) var stills: [String: StillImage] = [:]
    @Published var toast: Toast?
    var autotestStarted = false

    @Published var isDemo: Bool {
        didSet {
            guard oldValue != isDemo else { return }
            defaults.set(isDemo, forKey: Keys.demo)
            resetForModeChange()
        }
    }

    @Published var networkName: String {
        didSet { defaults.set(networkName, forKey: Keys.networkName) }
    }

    @Published var lanAddress: String {
        didSet { defaults.set(lanAddress, forKey: Keys.lan) }
    }

    @Published var overlayAddress: String {
        didSet { defaults.set(overlayAddress, forKey: Keys.overlay) }
    }

    /// The site CA pinned in the Keychain, or nil until this phone is paired with a gateway.
    @Published private(set) var siteCA: SiteCA? {
        didSet {
            guard oldValue != siteCA else { return }
            dataSession.finishTasksAndInvalidate()
            dataSession = GatewayClient.makeSession(timeout: 8, anchor: siteCA)
        }
    }

    /// After pairing, also try plain HTTP on the overlay (protected by the VPN tunnel only) when
    /// HTTPS doesn't answer — for gateways still on the pre-1.4 service.
    @Published var legacyOverVPN: Bool {
        didSet { defaults.set(legacyOverVPN, forKey: Keys.legacyOverVPN) }
    }

    @Published var pendingPairing: PairingOffer?
    @Published private(set) var pairingState: PairingState = .idle

    let launch: LaunchOptions
    private let defaults: UserDefaults
    private var demo = DemoNetwork()
    private var dataSession: URLSession
    private var toastTask: Task<Void, Never>?

    private enum Keys {
        static let demo = "lojo.demo"
        static let networkName = "lojo.networkName"
        static let lan = "lojo.lanAddress"
        static let overlay = "lojo.overlayAddress"
        static let pairedLAN = "lojo.pairedLAN"
        static let pairedOverlay = "lojo.pairedOverlay"
        static let legacyOverVPN = "lojo.legacyOverVPN"
    }

    init(launch: LaunchOptions = .current, defaults: UserDefaults = .standard) {
        self.launch = launch
        self.defaults = defaults
        isDemo = launch.demo ?? defaults.bool(forKey: Keys.demo)
        networkName = defaults.string(forKey: Keys.networkName) ?? Self.defaultName
        lanAddress = defaults.string(forKey: Keys.lan) ?? Self.defaultLAN
        overlayAddress = defaults.string(forKey: Keys.overlay) ?? Self.defaultOverlay
        legacyOverVPN = defaults.object(forKey: Keys.legacyOverVPN) as? Bool ?? true
        if launch.unpair { SiteTrustStore.delete() }
        let ca = SiteTrustStore.load()
        siteCA = ca
        dataSession = GatewayClient.makeSession(timeout: 8, anchor: ca)
        if let forced = launch.demo { defaults.set(forced, forKey: Keys.demo) }
        if let code = launch.pairingCode { pendingPairing = PairingOffer(code: code) }
    }

    // MARK: - derived

    var displayNetworkName: String { isDemo ? demo.name : networkName }

    var isStale: Bool { link == .unreachable && lastSuccess != nil }

    var hubConnected: Bool { network?.hub.connected ?? false }

    var localNetworkBlocked: Bool {
        if link == .unreachable, case .localNetworkDenied? = lastError { return true }
        return false
    }

    var onlineCount: Int { devices.filter(\.online).count }
    var offlineCount: Int { devices.count - onlineCount }
    var cameraCount: Int { devices.filter { $0.camera.enabled }.count }
    var outputCount: Int { devices.reduce(0) { $0 + $1.gpio.count } }

    /// Why actions are unavailable right now, or nil if they can be sent.
    func actionBlocker(for device: Device) -> String? {
        if isDemo { return device.online ? nil : "\(device.displayName) is offline." }
        switch link {
        case .connected:
            if !hubConnected { return "The site gateway has lost the cloud hub." }
            if !device.online || device.socketID == nil { return "\(device.displayName) is offline." }
            return nil
        case .connecting: return "Connecting to your network…"
        case .unreachable, .demo: return "Your network isn't reachable from this phone right now."
        }
    }

    func device(key: String) -> Device? { devices.first { $0.key == key } }

    func events(for device: Device, limit: Int = 6) -> [NetworkEvent] {
        Array(events.filter { $0.device == device.key }.prefix(limit))
    }

    func lastChange(for device: Device, pin: String) -> NetworkEvent? {
        events.first { $0.device == device.key && $0.kind == .gpioSet && $0.pin == pin }
    }

    var isPaired: Bool { siteCA != nil }

    /// How the connection in use is protected; nil while nothing is connected.
    var protection: GatewayEndpoint.Protection? {
        switch link {
        case .connected(let ep): return ep.protection
        case .demo: return .tls
        case .connecting, .unreachable: return nil
        }
    }

    /// Endpoints in order of preference. When paired, HTTPS (pinned) comes first on both paths;
    /// the labelled legacy fallback is plain HTTP on the overlay only, never on site Wi‑Fi.
    func endpoints() -> [GatewayEndpoint] {
        let scheme = isPaired ? "https://" : "http://"
        let lan = launch.simulateOffline ? scheme + Self.offlineLAN : (launch.lanOverride ?? lanAddress)
        let overlay = launch.simulateOffline ? scheme + Self.offlineOverlay : (launch.overlayOverride ?? overlayAddress)
        var out: [GatewayEndpoint] = []
        if let url = GatewayAddress.normalize(lan) { out.append(GatewayEndpoint(path: .lan, baseURL: url)) }
        if let url = GatewayAddress.normalize(overlay) {
            out.append(GatewayEndpoint(path: .overlay, baseURL: url))
            if url.scheme == "https", legacyOverVPN, let legacy = GatewayAddress.legacy(url) {
                out.append(GatewayEndpoint(path: .overlay, baseURL: legacy))
            }
        }
        return out
    }

    /// One line per path explaining the last failure, e.g. "Private overlay: NSURLErrorTimedOut (-1001)".
    var failureSummary: String? {
        guard link == .unreachable, !lastProbes.isEmpty else { return nil }
        return lastProbes.compactMap { p in
            p.error.map { "\(p.endpoint.path.title): \($0.technical)" }
        }.joined(separator: "\n")
    }

    /// One plain sentence for the Home health card when nothing answers.
    func unreachableReason(phone: PhoneInterfaces = .current()) -> String {
        if localNetworkBlocked { return "Local Network access is off for this app." }
        let atsBlocked = lastProbes.contains { p in
            if case .transport(let f)? = p.error { return f.isATSBlock }
            return false
        }
        if atsBlocked { return "iOS blocked the connection. Update LOJO Networks." }
        if let tls = lastProbes.lazy.compactMap({ $0.error?.tlsFailure }).first {
            switch tls.kind {
            case .pinMismatch, .pairingMismatch: return "The gateway's certificate doesn't match this phone's pairing."
            case .hostnameMismatch: return "The gateway's certificate doesn't cover this address."
            case .expired: return "The gateway's certificate has expired."
            case .notPaired: return "This phone isn't paired with the gateway yet."
            case .untrusted, .handshake: return "The secure connection to the gateway failed."
            }
        }
        if phone.hasVPN { return "Your VPN is on, but the site gateway didn't answer through it." }
        if phone.hasWiFi { return "This Wi‑Fi isn't your site network, and the LOJO VPN is off." }
        if phone.cellularActive { return "On cellular data without the LOJO VPN." }
        return "This phone has no network connection."
    }

    func resetAddresses() {
        if isPaired {
            lanAddress = defaults.string(forKey: Keys.pairedLAN) ?? lanAddress
            overlayAddress = defaults.string(forKey: Keys.pairedOverlay) ?? overlayAddress
        } else {
            lanAddress = Self.defaultLAN
            overlayAddress = Self.defaultOverlay
        }
        link = .connecting
    }

    // MARK: - pairing

    /// Tries every address in the pairing code at once and pins the CA from the first gateway
    /// whose certificate chain contains exactly the CA the code names.
    @discardableResult
    func pair(_ offer: PairingOffer) async -> Bool {
        pairingState = .working
        let candidates = [
            offer.lan.map { GatewayEndpoint(path: .lan, baseURL: $0) },
            offer.overlay.map { GatewayEndpoint(path: .overlay, baseURL: $0) },
        ].compactMap { $0 }
        let results = await withTaskGroup(of: (Int, Result<(SiteCA, GatewayNetwork), GatewayError>).self) { group in
            for (i, ep) in candidates.enumerated() {
                group.addTask { (i, await GatewayClient.pair(ep, caSHA256: offer.caSHA256)) }
            }
            var out: [(Int, Result<(SiteCA, GatewayNetwork), GatewayError>)] = []
            for await r in group { out.append(r) }
            return out.sorted { $0.0 < $1.0 }.map(\.1)
        }
        var errors: [(ConnectionPath, GatewayError)] = []
        for (ep, result) in zip(candidates, results) {
            switch result {
            case .success(let (ca, net)):
                do {
                    try SiteTrustStore.save(ca)
                } catch {
                    pairingState = .failed("The certificate couldn't be saved in the Keychain [OSStatus \((error as NSError).code)].")
                    Haptics.error()
                    return false
                }
                if let lan = offer.lan?.absoluteString {
                    lanAddress = lan
                    defaults.set(lan, forKey: Keys.pairedLAN)
                }
                if let ov = offer.overlay?.absoluteString {
                    overlayAddress = ov
                    defaults.set(ov, forKey: Keys.pairedOverlay)
                }
                if networkName == Self.defaultName { networkName = offer.name }
                siteCA = ca
                pendingPairing = nil
                pairingState = .idle
                lastProbes = []
                link = .connecting
                show(Toast(style: .success, message: "Paired with \(net.gateway.name) over \(ep.path.title). Traffic is now encrypted."))
                Haptics.success()
                await refreshAfterTrustChange()
                return true
            case .failure(let e):
                errors.append((ep.path, e))
            }
        }
        let best = errors.first { $0.1.tlsFailure != nil } ?? errors.first
        pairingState = .failed(best.map { "\($0.0.title): \($0.1.errorDescription ?? "Failed.") [\($0.1.technical)]" }
                               ?? "The pairing code has no gateway address.")
        Haptics.error()
        return false
    }

    /// Removes the pinned CA and goes back to the gateway's legacy HTTP addresses.
    func forgetPairing() {
        SiteTrustStore.delete()
        siteCA = nil
        defaults.removeObject(forKey: Keys.pairedLAN)
        defaults.removeObject(forKey: Keys.pairedOverlay)
        func legacy(_ address: String, fallback: String) -> String {
            guard let url = GatewayAddress.normalize(address), url.scheme == "https" else { return address }
            return GatewayAddress.legacy(url)?.absoluteString ?? fallback
        }
        lanAddress = legacy(lanAddress, fallback: Self.defaultLAN)
        overlayAddress = legacy(overlayAddress, fallback: Self.defaultOverlay)
        lastProbes = []
        link = .connecting
        show(Toast(style: .warning, message: "Pairing removed. The app now uses unencrypted HTTP on site Wi‑Fi."))
        Task { await refreshAfterTrustChange() }
    }

    /// A refresh already in flight is still using the old endpoints, so wait it out first.
    private func refreshAfterTrustChange() async {
        while isRefreshing { try? await Task.sleep(for: .milliseconds(100)) }
        link = .connecting
        await refresh(.user)
    }

    func dismissPairing() {
        pendingPairing = nil
        pairingState = .idle
    }

    // MARK: - refresh

    func refresh(_ reason: RefreshReason) async {
        if isDemo {
            demo.tick()
            applyDemo()
            if reason == .user { Haptics.light() }
            return
        }
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        // Timer refreshes stick with a working path; a network change or manual refresh re-probes
        // both so the phone moves back to site Wi‑Fi (or over to the overlay) as soon as it can.
        // A legacy connection isn't sticky while HTTPS is configured, so it upgrades as soon as it can.
        let sticky = reason == .timer || reason == .launch
        if sticky, case .connected(let ep) = link, ep.secure || !endpoints().contains(where: \.secure),
           await load(from: ep) {
            return
        }
        if lastSuccess == nil { link = .connecting }

        let results = await probeAll()
        lastProbes = results
        if let hit = results.first(where: \.reachable) {
            latencyMs = hit.latencyMs
            if await load(from: hit.endpoint) {
                if reason == .user { Haptics.light() }
                return
            }
        } else {
            lastError = results.compactMap(\.error).first
        }
        let wasReachable = link != .unreachable && link != .connecting
        link = .unreachable
        if reason == .user || wasReachable { Haptics.warning() }
    }

    func probeAll() async -> [ProbeResult] {
        let eps = endpoints()
        let anchor = siteCA
        return await withTaskGroup(of: (Int, ProbeResult).self) { group in
            for (i, ep) in eps.enumerated() {
                group.addTask { (i, await GatewayClient.probe(ep, anchor: anchor)) }
            }
            var out: [(Int, ProbeResult)] = []
            for await r in group { out.append(r) }
            return out.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    private func client(_ ep: GatewayEndpoint) -> GatewayClient {
        GatewayClient(endpoint: ep, session: dataSession)
    }

    private func load(from ep: GatewayEndpoint) async -> Bool {
        let c = client(ep)
        let start = Date()
        do {
            async let n = c.network()
            async let d = c.devices()
            async let e = c.events()
            let (net, devs, evs) = try await (n, d, e)
            network = net
            devices = devs
            events = evs
            latencyMs = Int(Date().timeIntervalSince(start) * 1000)
            lastSuccess = Date()
            lastError = nil
            link = .connected(ep)
            await loadStills(client: c)
            return true
        } catch {
            lastError = GatewayError.wrap(error, url: ep.baseURL)
            return false
        }
    }

    private func loadStills(client c: GatewayClient) async {
        let wanted = devices.compactMap { d -> (String, String, String?)? in
            guard d.camera.hasStill, let path = d.camera.stillURL else { return nil }
            if let have = stills[d.key], have.capturedAt == d.camera.capturedAt { return nil }
            return (d.key, path, d.camera.capturedAt)
        }
        guard !wanted.isEmpty else { return }
        let fetched = await withTaskGroup(of: (String, String?, Data?).self) { group in
            for (key, path, at) in wanted {
                group.addTask { (key, at, try? await c.still(path: path)) }
            }
            var out: [(String, String?, Data?)] = []
            for await r in group { out.append(r) }
            return out
        }
        for (key, at, data) in fetched {
            if let data, let img = UIImage(data: data) {
                stills[key] = StillImage(image: img, capturedAt: at)
            }
        }
    }

    // MARK: - actions

    func capture(_ device: Device) async {
        guard captureStage[device.key] == nil else { return }
        if let blocker = actionBlocker(for: device) {
            show(Toast(style: .warning, message: blocker))
            Haptics.warning()
            return
        }
        Haptics.light()
        if isDemo {
            captureStage[device.key] = .requesting
            try? await Task.sleep(for: .milliseconds(700))
            captureStage[device.key] = .waiting
            try? await Task.sleep(for: .milliseconds(1500))
            demo.capture(key: device.key)
            applyDemo()
            captureStage[device.key] = nil
            show(Toast(style: .success, message: "New still from \(device.displayName)."))
            Haptics.success()
            return
        }
        guard case .connected(let ep) = link, let sid = device.socketID else { return }
        let c = client(ep)
        captureStage[device.key] = .requesting
        let previousAt = device.camera.capturedAt
        let previousErr = device.camera.lastError
        do {
            try await c.requestCapture(socketID: sid)
        } catch {
            captureStage[device.key] = nil
            show(Toast(style: .error, message: Self.failureText(error, fallback: "Capture failed.")))
            Haptics.error()
            return
        }
        captureStage[device.key] = .waiting
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(1200))
            guard let fresh = try? await c.devices() else { continue }
            devices = fresh
            guard let updated = fresh.first(where: { $0.key == device.key }) else { continue }
            if updated.camera.hasStill, updated.camera.capturedAt != previousAt {
                await loadStills(client: c)
                captureStage[device.key] = nil
                events = (try? await c.events()) ?? events
                show(Toast(style: .success, message: "New still from \(device.displayName)."))
                Haptics.success()
                return
            }
            if let err = updated.camera.lastError, err != previousErr {
                captureStage[device.key] = nil
                show(Toast(style: .error, message: "The camera reported: \(err)"))
                Haptics.error()
                return
            }
        }
        captureStage[device.key] = nil
        events = (try? await c.events()) ?? events
        show(Toast(style: .warning, message: "\(device.displayName) didn't send a still within 20 seconds. It may be busy or on a slow link."))
        Haptics.warning()
    }

    func setOutput(_ device: Device, pin: Device.Pin, on: Bool) async {
        let busyKey = device.key + ":" + pin.pin
        guard outputBusy == nil else { return }
        if let blocker = actionBlocker(for: device) {
            show(Toast(style: .warning, message: blocker))
            Haptics.warning()
            return
        }
        Haptics.rigid()
        outputBusy = busyKey
        defer { outputBusy = nil }
        let value = on ? 1 : 0
        if isDemo {
            try? await Task.sleep(for: .milliseconds(850))
            demo.setPin(key: device.key, pin: pin.pin, value: value)
            applyDemo()
            show(Toast(style: .success, message: "\(pin.title) is now \(on ? "ON" : "OFF")."))
            Haptics.success()
            return
        }
        guard case .connected(let ep) = link, let sid = device.socketID else { return }
        let c = client(ep)
        do {
            try await c.setOutput(socketID: sid, pin: pin.pin, value: value)
            if let i = devices.firstIndex(where: { $0.key == device.key }),
               let j = devices[i].gpio.firstIndex(where: { $0.pin == pin.pin }) {
                devices[i].gpio[j].value = value
            }
            events = (try? await c.events()) ?? events
            show(Toast(style: .success, message: "\(pin.title) on \(device.displayName) is now \(on ? "ON" : "OFF")."))
            Haptics.success()
        } catch {
            show(Toast(style: .error, message: Self.failureText(error, fallback: "The command didn't go through.")))
            Haptics.error()
        }
    }

    private static func failureText(_ error: Error, fallback: String) -> String {
        let e = GatewayError.wrap(error)
        return "\(e.errorDescription ?? fallback) [\(e.technical)]"
    }

    func show(_ toast: Toast) {
        self.toast = toast
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3.5))
            guard !Task.isCancelled, self?.toast?.id == toast.id else { return }
            self?.toast = nil
        }
    }

    // MARK: - demo

    private func applyDemo() {
        network = demo.network
        devices = demo.devices
        events = demo.events
        link = .demo
        latencyMs = 38
        lastSuccess = Date()
        lastError = nil
    }

    private func resetForModeChange() {
        network = nil
        devices = []
        events = []
        stills = [:]
        lastSuccess = nil
        lastError = nil
        captureStage = [:]
        link = isDemo ? .demo : .connecting
        if isDemo {
            demo = DemoNetwork()
            applyDemo()
        } else {
            Task { await refresh(.launch) }
        }
    }
}
