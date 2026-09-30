import Foundation

struct RanchDevice: Identifiable, Hashable, Codable {
    var socketID: String
    var name: String
    var site: String
    var webcamEnabled: Bool
    var lastCaptureError: String?
    var capturedAt: String?
    var hasStill: Bool
    var lastSeenAt: String?
    var stillURL: String?
    var gpioPins: [String: Int]
    var gpio: Bool?

    var id: String { socketID }

    var sortedPins: [String] {
        gpioPins.keys.sorted { (Int($0) ?? 0) < (Int($1) ?? 0) }
    }

    var displayName: String {
        name.isEmpty ? socketID : name
    }

    var stillPath: String? {
        stillURL
    }
}

struct DevicesResponse: Codable {
    var ok: Bool
    var gpio: Bool?
    var devices: [RanchDevice]
}

struct HealthResponse: Codable {
    var ok: Bool
    var service: String?
    var gpio: Bool?
    var pubnodeConnected: Bool?
    var devices: Int?
}

struct CaptureResponse: Codable {
    var ok: Bool
    var error: String?
    var requested: String?
}

enum RanchEndpoint: String, CaseIterable, Identifiable {
    case lan = "http://192.168.7.103:8801"
    case overlay = "http://100.96.1.18:8801"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .lan: return "Home LAN"
        case .overlay: return "Connexa"
        }
    }
}
