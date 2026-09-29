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
    private static let offlineLAN = "http://192.0.2.10:8801"
    private static let offlineOverlay = "http://198.51.100.10:8801"

    @Published private(set) var link: Link = .connecting
    @Published private(set) var network: GatewayNetwork?
    @Published private(set) var devices: [Device] = []
    @Published private(set) var events: [NetworkEvent] = []
    @Published private(set) var lastSuccess: Date?
    @Published private(set) var lastError: GatewayError?
    @Published private(set) var latencyMs: Int?
    @Published private(set) var isRefreshing = false
    @Published private(set) var captureStage: [String: CaptureStage] = [:]
    @Published private(set) var outputBusy: String?
    @Published private(set) var stills: [String: StillImage] = [:]
    @Published var toast: Toast?

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

    let launch: LaunchOptions
    private let defaults: UserDefaults
    private var demo = DemoNetwork()
    private let dataSession = GatewayClient.makeSession(timeout: 8)
    private var toastTask: Task<Void, Never>?

    private enum Keys {
        static let demo = "lojo.demo"
        static let networkName = "lojo.networkName"
        static let lan = "lojo.lanAddress"
        static let overlay = "lojo.overlayAddress"
    }

    init(launch: LaunchOptions = .current, defaults: UserDefaults = .standard) {
        self.launch = launch
        self.defaults = defaults
        isDemo = launch.demo ?? defaults.bool(forKey: Keys.demo)
        networkName = defaults.string(forKey: Keys.networkName) ?? "My Private Network"
        lanAddress = defaults.string(forKey: Keys.lan) ?? Self.defaultLAN
        overlayAddress = defaults.string(forKey: Keys.overlay) ?? Self.defaultOverlay
        if let forced = launch.demo { defaults.set(forced, forKey: Keys.demo) }
    }

    // MARK: - derived

    var displayNetworkName: String { isDemo ? demo.name : networkName }

    var isStale: Bool { link == .unreachable && lastSuccess != nil }

    var hubConnected: Bool { network?.hub.connected ?? false }

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

    func endpoints() -> [GatewayEndpoint] {
        let lan = launch.simulateOffline ? Self.offlineLAN : lanAddress
        let overlay = launch.simulateOffline ? Self.offlineOverlay : overlayAddress
        return [
            URL(string: lan).map { GatewayEndpoint(path: .lan, baseURL: $0) },
            URL(string: overlay).map { GatewayEndpoint(path: .overlay, baseURL: $0) },
        ].compactMap { $0 }
    }

    func resetAddresses() {
        lanAddress = Self.defaultLAN
        overlayAddress = Self.defaultOverlay
        link = .connecting
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

        if case .connected(let ep) = link, await load(from: ep) {
            if reason == .user { Haptics.light() }
            return
        }
        if lastSuccess == nil { link = .connecting }

        let results = await probeAll()
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
        return await withTaskGroup(of: (Int, ProbeResult).self) { group in
            for (i, ep) in eps.enumerated() {
                group.addTask { (i, await GatewayClient.probe(ep)) }
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
            lastError = GatewayError.wrap(error)
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
            show(Toast(style: .error, message: GatewayError.wrap(error).errorDescription ?? "Capture failed."))
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
            show(Toast(style: .error, message: GatewayError.wrap(error).errorDescription ?? "The command didn't go through."))
            Haptics.error()
        }
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
