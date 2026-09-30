import Foundation

/// A self-contained sample network so the app can be explored without any hardware.
/// Timestamps are generated relative to launch so the data always looks current.
struct DemoNetwork {
    let name = "Juniper Mesa Ranch"
    private(set) var devices: [Device]
    private(set) var events: [NetworkEvent]
    private var seq: Int
    private let startedAt: Date

    init(now: Date = Date()) {
        startedAt = now.addingTimeInterval(-6 * 86_400)
        func ago(_ minutes: Double) -> String { ISODate.string(now.addingTimeInterval(-minutes * 60)) }

        devices = [
            Device(
                key: "north-gate", socketID: "demo-north-gate", name: "North Gate", site: "north pasture",
                online: true, firstSeenAt: ago(60 * 24 * 41), onlineSince: ago(60 * 51), offlineSince: nil,
                lastUpdateAt: ago(1.5),
                camera: .init(enabled: true, hasStill: true, capturedAt: ago(6), lastError: nil, stillURL: nil),
                gpio: [.init(pin: "11", value: 0, label: "Gate latch")],
                location: .init(lat: 34.9412, lon: -106.0621, source: "gps")
            ),
            Device(
                key: "hay-barn-cam", socketID: "demo-hay-barn", name: "Hay Barn Cam", site: "headquarters",
                online: true, firstSeenAt: ago(60 * 24 * 88), onlineSince: ago(60 * 24 * 5), offlineSince: nil,
                lastUpdateAt: ago(2),
                camera: .init(enabled: true, hasStill: true, capturedAt: ago(2), lastError: nil, stillURL: nil),
                gpio: [],
                location: .init(lat: 34.9335, lon: -106.0512, source: "gps")
            ),
            Device(
                key: "tank-3", socketID: "demo-tank-3", name: "Tank 3 Controller", site: "east pasture",
                online: true, firstSeenAt: ago(60 * 24 * 63), onlineSince: ago(60 * 5), offlineSince: nil,
                lastUpdateAt: ago(0.7),
                camera: .init(enabled: false, hasStill: false, capturedAt: nil, lastError: nil, stillURL: nil),
                gpio: [
                    .init(pin: "15", value: 1, label: "Fill valve"),
                    .init(pin: "16", value: 0, label: "Float alarm light"),
                ],
                location: .init(lat: 34.9268, lon: -106.0705, source: "gps")
            ),
            Device(
                key: "corral-cam", socketID: "demo-corral", name: "Corral Cam", site: "headquarters",
                online: true, firstSeenAt: ago(60 * 24 * 88), onlineSince: ago(60 * 24 * 2), offlineSince: nil,
                lastUpdateAt: ago(4),
                camera: .init(enabled: true, hasStill: true, capturedAt: ago(38), lastError: nil, stillURL: nil),
                gpio: [],
                location: .init(lat: 34.9361, lon: -106.0556, source: "gps")
            ),
            Device(
                key: "south-well", socketID: nil, name: "South Well Pump", site: "south section",
                online: false, firstSeenAt: ago(60 * 24 * 120), onlineSince: nil, offlineSince: ago(192),
                lastUpdateAt: ago(193),
                camera: .init(enabled: false, hasStill: false, capturedAt: nil, lastError: nil, stillURL: nil),
                gpio: [.init(pin: "13", value: 0, label: "Pump contactor")],
                location: .init(lat: 34.9121, lon: -106.0480, source: "gps")
            ),
            Device(
                key: "office-pc", socketID: "demo-office", name: "Office Workstation", site: "headquarters",
                online: true, firstSeenAt: ago(60 * 24 * 150), onlineSince: ago(60 * 26), offlineSince: nil,
                lastUpdateAt: ago(9),
                camera: .init(enabled: false, hasStill: false, capturedAt: nil, lastError: nil, stillURL: nil),
                gpio: [],
                location: nil
            ),
        ]

        var list: [NetworkEvent] = []
        var n = 0
        func add(_ minutes: Double, _ type: EventKind, _ device: String? = nil, pin: String? = nil,
                 value: Int? = nil, via: String? = nil, detail: String? = nil) {
            n += 1
            list.append(NetworkEvent(id: "demo-\(n)", type: type.rawValue, at: ago(minutes), device: device,
                                     site: nil, detail: detail, pin: pin, value: value, via: via))
        }
        add(60 * 24 * 2 + 30, .deviceOnline, "corral-cam")
        add(60 * 24 * 1 + 190, .hubDisconnected, detail: "transport close")
        add(60 * 24 * 1 + 189, .hubConnected)
        add(60 * 26, .deviceOnline, "office-pc")
        add(60 * 13 + 12, .gpioSet, "north-gate", pin: "11", value: 1, via: "overlay")
        add(60 * 12 + 47, .gpioSet, "north-gate", pin: "11", value: 0, via: "overlay")
        add(60 * 9, .captureRequested, "north-gate", via: "lan")
        add(60 * 9 - 0.1, .captureCompleted, "north-gate")
        add(60 * 5 + 2, .deviceOffline, "tank-3", detail: "left the hub")
        add(60 * 5, .deviceOnline, "tank-3")
        add(60 * 3 + 40, .gpioSet, "south-well", pin: "13", value: 0, via: "overlay")
        add(192, .deviceOffline, "south-well", detail: "left the hub")
        add(41, .captureRequested, "corral-cam", via: "overlay")
        add(40.6, .captureFailed, "corral-cam", detail: "camera busy — device in use")
        add(38.5, .captureRequested, "corral-cam", via: "overlay")
        add(38, .captureCompleted, "corral-cam")
        add(14, .gpioSet, "tank-3", pin: "15", value: 1, via: "lan")
        add(6.2, .captureRequested, "north-gate", via: "lan")
        add(6, .captureCompleted, "north-gate")
        add(2.2, .captureRequested, "hay-barn-cam", via: "overlay")
        add(2, .captureCompleted, "hay-barn-cam")
        events = list.sorted { $0.date > $1.date }
        seq = n
    }

    var network: GatewayNetwork {
        let online = devices.filter(\.online).count
        return GatewayNetwork(
            ok: true,
            version: "demo",
            gateway: .init(name: "mesa-gateway", startedAt: ISODate.string(startedAt),
                           uptimeSec: Int(Date().timeIntervalSince(startedAt))),
            hub: .init(connected: true, since: ISODate.string(startedAt), lastError: nil, lastListAt: nil),
            devices: .init(online: online, offline: devices.count - online, total: devices.count),
            arrivedVia: "overlay",
            serverTime: ISODate.string(Date()),
            site: .init(name: name)
        )
    }

    mutating func tick(now: Date = Date()) {
        for i in devices.indices where devices[i].online {
            devices[i].lastUpdateAt = ISODate.string(now.addingTimeInterval(-Double.random(in: 5...90)))
        }
    }

    mutating func capture(key: String, now: Date = Date()) {
        guard let i = devices.firstIndex(where: { $0.key == key }) else { return }
        devices[i].camera.capturedAt = ISODate.string(now)
        devices[i].camera.hasStill = true
        devices[i].camera.lastError = nil
        append(.captureRequested, device: key, at: now.addingTimeInterval(-2), via: "overlay")
        append(.captureCompleted, device: key, at: now)
    }

    mutating func setPin(key: String, pin: String, value: Int, now: Date = Date()) {
        guard let i = devices.firstIndex(where: { $0.key == key }),
              let j = devices[i].gpio.firstIndex(where: { $0.pin == pin }) else { return }
        devices[i].gpio[j].value = value
        append(.gpioSet, device: key, at: now, pin: pin, value: value, via: "overlay")
    }

    private mutating func append(_ type: EventKind, device: String, at: Date, pin: String? = nil,
                                 value: Int? = nil, via: String? = nil) {
        seq += 1
        let ev = NetworkEvent(id: "demo-\(seq)", type: type.rawValue, at: ISODate.string(at), device: device,
                              site: nil, detail: nil, pin: pin, value: value, via: via)
        events.insert(ev, at: 0)
    }
}
