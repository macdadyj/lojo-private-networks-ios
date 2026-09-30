import Foundation

enum ConnectionPath: String, Codable, Sendable, CaseIterable {
    case lan
    case overlay

    var title: String {
        switch self {
        case .lan: return "Site Wi‑Fi"
        case .overlay: return "Private overlay"
        }
    }

    var longTitle: String {
        switch self {
        case .lan: return "Site Wi‑Fi (local network)"
        case .overlay: return "Private overlay (VPN)"
        }
    }

    var systemImage: String {
        switch self {
        case .lan: return "wifi"
        case .overlay: return "lock.shield.fill"
        }
    }
}

struct GatewayEndpoint: Sendable, Hashable {
    let path: ConnectionPath
    let baseURL: URL
}

struct GatewayNetwork: Codable, Sendable, Hashable {
    struct Gateway: Codable, Sendable, Hashable {
        var name: String
        var startedAt: String?
        var uptimeSec: Int?
    }

    struct Hub: Codable, Sendable, Hashable {
        var connected: Bool
        var since: String?
        var lastError: String?
        var lastListAt: String?
    }

    struct Counts: Codable, Sendable, Hashable {
        var online: Int
        var offline: Int
        var total: Int
    }

    var ok: Bool
    var version: String?
    var gateway: Gateway
    var hub: Hub
    var devices: Counts
    var arrivedVia: String?
    var seenFrom: String?
    var serverTime: String?
}

struct Device: Codable, Identifiable, Hashable, Sendable {
    struct Camera: Codable, Hashable, Sendable {
        var enabled: Bool
        var hasStill: Bool
        var capturedAt: String?
        var lastError: String?
        var stillURL: String?
    }

    struct Pin: Codable, Hashable, Sendable, Identifiable {
        var pin: String
        var value: Int
        var label: String?

        var id: String { pin }
        var isOn: Bool { value == 1 }
        var title: String { label ?? "Output \(pin)" }
        /// Device agents address outputs by physical 40-pin header position (rpi-gpio's default),
        /// so "11" is header pin 11, which the Pi calls GPIO 17.
        var subtitle: String {
            guard let n = Int(pin), let bcm = Self.headerToBCM[n] else { return "Pin \(pin)" }
            return "Header pin \(n) · GPIO \(bcm)"
        }

        private static let headerToBCM: [Int: Int] = [
            3: 2, 5: 3, 7: 4, 8: 14, 10: 15, 11: 17, 12: 18, 13: 27, 15: 22, 16: 23, 18: 24, 19: 10,
            21: 9, 22: 25, 23: 11, 24: 8, 26: 7, 27: 0, 28: 1, 29: 5, 31: 6, 32: 12, 33: 13, 35: 19,
            36: 16, 37: 26, 38: 20, 40: 21,
        ]
    }

    struct Location: Codable, Hashable, Sendable {
        var lat: Double
        var lon: Double
        var source: String?

        var isApproximate: Bool {
            guard let source else { return false }
            return source.lowercased().contains("ip")
        }

        var sourceText: String {
            switch source?.lowercased() {
            case "gps": return "GPS"
            case "wifi", "mls": return "Wi‑Fi positioning"
            case "ip": return "Approximate (from internet address)"
            case "config", "manual", "fixed": return "Set by owner"
            case .some(let other): return other.capitalized
            case .none: return "Reported by device"
            }
        }
    }

    var key: String
    var socketID: String?
    var name: String
    var site: String
    var online: Bool
    var firstSeenAt: String?
    var onlineSince: String?
    var offlineSince: String?
    var lastUpdateAt: String?
    var camera: Camera
    var gpio: [Pin]
    var location: Location?

    var id: String { key }

    var displayName: String { DeviceNaming.displayName(name.isEmpty ? key : name) }
    var siteName: String { DeviceNaming.siteName(site) }

    var kind: DeviceKind {
        let cam = camera.enabled
        let io = !gpio.isEmpty
        switch (cam, io) {
        case (true, true): return .cameraController
        case (true, false): return .camera
        case (false, true): return .controller
        case (false, false): return .computer
        }
    }

    var lastUpdate: Date? { ISODate.parse(lastUpdateAt) }
    var capturedDate: Date? { ISODate.parse(camera.capturedAt) }
    var statusSince: Date? { ISODate.parse(online ? onlineSince : offlineSince) }
}

enum DeviceKind: Sendable {
    case camera
    case controller
    case cameraController
    case computer

    var systemImage: String {
        switch self {
        case .camera: return "video.fill"
        case .controller: return "switch.2"
        case .cameraController: return "video.badge.checkmark"
        case .computer: return "desktopcomputer"
        }
    }

    var title: String {
        switch self {
        case .camera: return "Camera"
        case .controller: return "Controller"
        case .cameraController: return "Camera + controls"
        case .computer: return "Computer"
        }
    }
}

enum DeviceNaming {
    private static let hiddenSuffixes = ["-CloudRun", "_CloudRun", "CloudRun", "-cloudrun"]

    static func displayName(_ raw: String) -> String {
        var name = raw
        for suffix in hiddenSuffixes where name.hasSuffix(suffix) && name.count > suffix.count {
            name = String(name.dropLast(suffix.count))
            break
        }
        return name
    }

    static func siteName(_ raw: String) -> String {
        guard let first = raw.first else { return "Unassigned site" }
        return first.uppercased() + raw.dropFirst()
    }
}

struct NetworkEvent: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var type: String
    var at: String
    var device: String?
    var site: String?
    var detail: String?
    var pin: String?
    var value: Int?
    var via: String?

    var date: Date { ISODate.parse(at) ?? .distantPast }
    var kind: EventKind { EventKind(rawValue: type) ?? .other }
}

enum EventKind: String, Sendable {
    case deviceOnline = "device.online"
    case deviceOffline = "device.offline"
    case captureRequested = "capture.requested"
    case captureCompleted = "capture.completed"
    case captureFailed = "capture.failed"
    case gpioSet = "gpio.set"
    case hubConnected = "hub.connected"
    case hubDisconnected = "hub.disconnected"
    case other

    enum Category: String, CaseIterable, Identifiable, Sendable {
        case all = "All"
        case devices = "Devices"
        case cameras = "Cameras"
        case controls = "Controls"

        var id: String { rawValue }
    }

    var category: Category {
        switch self {
        case .deviceOnline, .deviceOffline, .hubConnected, .hubDisconnected, .other: return .devices
        case .captureRequested, .captureCompleted, .captureFailed: return .cameras
        case .gpioSet: return .controls
        }
    }
}

enum ISODate {
    private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let plain = Date.ISO8601FormatStyle()

    static func parse(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        if let d = try? fractional.parse(string) { return d }
        return try? plain.parse(string)
    }

    static func string(_ date: Date) -> String {
        fractional.format(date)
    }
}
