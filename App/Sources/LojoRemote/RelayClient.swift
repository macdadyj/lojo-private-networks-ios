import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum RelayEndpoint {
    public static func url(from text: String) -> URL? {
        var raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { return nil }
        if !raw.contains("://") { raw = "http://" + raw }
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host != nil else { return nil }
        return url
    }

    public static func isLoopback(_ host: String) -> Bool {
        let name = host.lowercased()
        return name == "localhost" || name == "127.0.0.1" || name == "::1" || name == "[::1]"
    }
}

public enum ScreenRelay {
    public static let localPort: UInt16 = 47221
    public static var inboxURL: URL { URL(string: "http://127.0.0.1:\(localPort)/frame")! }
}

public protocol RelayTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionRelayTransport: RelayTransport {
    public init() {}

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw RelayError.badResponse }
        return (data, http)
    }
}

public enum RelayError: Error, Equatable, Sendable {
    case badResponse
    case status(Int, String)
}

public struct RelayClient: Sendable {
    public var baseURL: URL
    public var networkCode: String
    public var transport: any RelayTransport

    public init(baseURL: URL, networkCode: String, transport: any RelayTransport = URLSessionRelayTransport()) {
        self.baseURL = baseURL
        self.networkCode = networkCode
        self.transport = transport
    }

    public func register(_ body: RegisterBody) async throws -> RemotePhone {
        let response: RegisterEnvelope = try await send("POST", path: "v1/phones", json: body)
        return response.phone
    }

    public func list() async throws -> [RemotePhone] {
        let response: PhoneListEnvelope = try await send("GET", path: "v1/phones", json: Optional<String>.none)
        return response.phones
    }

    public func heartbeat(_ body: HeartbeatBody, phoneID: String) async throws -> HeartbeatResponse {
        try await send("POST", path: "v1/phones/\(phoneID)/heartbeat", json: body)
    }

    public func command(_ body: CommandBody, phoneID: String) async throws -> RemoteCommand {
        let response: CommandEnvelope = try await send("POST", path: "v1/phones/\(phoneID)/commands", json: body)
        return response.command
    }

    public func schedules(phoneID: String) async throws -> ScheduleEnvelope {
        try await send("GET", path: "v1/phones/\(phoneID)/schedules", json: Optional<String>.none)
    }

    public func saveSchedules(_ schedules: [SoundSchedule], phoneID: String) async throws -> ScheduleEnvelope {
        try await send("PUT", path: "v1/phones/\(phoneID)/schedules", json: ScheduleWrite(schedules: schedules))
    }

    public func postFrame(_ jpeg: Data, phoneID: String) async throws {
        var request = base("POST", path: "v1/phones/\(phoneID)/screen")
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        request.httpBody = jpeg
        let (_, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw RelayError.status(response.statusCode, "frame was not accepted")
        }
    }

    public func latestFrame(phoneID: String) async throws -> Data? {
        let request = base("GET", path: "v1/phones/\(phoneID)/screen")
        let (data, response) = try await transport.send(request)
        if response.statusCode == 204 || data.isEmpty { return nil }
        guard (200..<300).contains(response.statusCode) else {
            throw RelayError.status(response.statusCode, "frame was not available")
        }
        return data
    }

    private func send<Body: Encodable, Response: Decodable>(
        _ method: String,
        path: String,
        json body: Body?
    ) async throws -> Response {
        var request = base(method, path: path)
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw RelayError.status(response.statusCode, text)
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw RelayError.badResponse
        }
    }

    private func base(_ method: String, path: String) -> URLRequest {
        let root = baseURL.absoluteString.hasSuffix("/") ? String(baseURL.absoluteString.dropLast()) : baseURL.absoluteString
        let url = URL(string: root + "/" + path) ?? baseURL
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(networkCode, forHTTPHeaderField: "X-Lojo-Network")
        request.timeoutInterval = 8
        return request
    }
}

public struct RegisterBody: Encodable, Sendable {
    public var id: String
    public var name: String
    public var batteryPercent: Int?
    public var charging: Bool
    public var schedules: [SoundSchedule]
    public var shortcuts: [NamedShortcut]

    public init(
        id: String,
        name: String,
        batteryPercent: Int?,
        charging: Bool,
        schedules: [SoundSchedule],
        shortcuts: [NamedShortcut] = []
    ) {
        self.id = id
        self.name = name
        self.batteryPercent = batteryPercent
        self.charging = charging
        self.schedules = schedules
        self.shortcuts = shortcuts
    }
}

public struct HeartbeatBody: Encodable, Sendable {
    public var batteryPercent: Int?
    public var charging: Bool
    public var playback: PlaybackSnapshot
    public var music: [MusicTrack]
    public var shortcuts: [NamedShortcut]?
    public var lastError: String?
    public var ack: [String]

    public init(
        batteryPercent: Int?,
        charging: Bool,
        playback: PlaybackSnapshot,
        music: [MusicTrack],
        shortcuts: [NamedShortcut]? = nil,
        lastError: String?,
        ack: [String]
    ) {
        self.batteryPercent = batteryPercent
        self.charging = charging
        self.playback = playback
        self.music = music
        self.shortcuts = shortcuts
        self.lastError = lastError
        self.ack = ack
    }
}

public struct HeartbeatResponse: Decodable, Sendable {
    public var commands: [RemoteCommand]
    public var schedules: [SoundSchedule]
    public var scheduleRevision: Int
}

public struct CommandBody: Encodable, Sendable {
    public var kind: RemoteCommand.Kind
    public var soundID: String?
    public var volume: Double?
    public var sleepMinutes: Int?
    public var shortcutName: String?

    public init(
        kind: RemoteCommand.Kind,
        soundID: String? = nil,
        volume: Double? = nil,
        sleepMinutes: Int? = nil,
        shortcutName: String? = nil
    ) {
        self.kind = kind
        self.soundID = soundID
        self.volume = volume
        self.sleepMinutes = sleepMinutes
        self.shortcutName = shortcutName
    }
}

public struct ScheduleEnvelope: Decodable, Sendable {
    public var schedules: [SoundSchedule]
    public var scheduleRevision: Int
}

private struct RegisterEnvelope: Decodable {
    var phone: RemotePhone
}

private struct PhoneListEnvelope: Decodable {
    var phones: [RemotePhone]
}

private struct CommandEnvelope: Decodable {
    var command: RemoteCommand
}

private struct ScheduleWrite: Encodable {
    var schedules: [SoundSchedule]
}

public enum FrameInboxParse: Equatable, Sendable {
    case needMore
    case frame(Data)
    case reject
}

public enum FrameInboxParser {
    public static let maxBytes = 1_500_000

    public static func parse(_ raw: Data) -> FrameInboxParse {
        let separator = Data("\r\n\r\n".utf8)
        guard let range = raw.range(of: separator) else { return .needMore }
        guard let head = String(data: raw[..<range.lowerBound], encoding: .utf8) else { return .reject }
        let lines = head.components(separatedBy: "\r\n")
        guard let request = lines.first else { return .reject }
        let parts = request.split(separator: " ")
        guard parts.count >= 2, parts[0] == "POST", parts[1] == "/frame" else { return .reject }
        var length: Int?
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if name == "content-length" { length = Int(value) }
        }
        guard let length, (0...maxBytes).contains(length) else { return .reject }
        let body = raw[range.upperBound...]
        guard body.count >= length else { return .needMore }
        return .frame(Data(body.prefix(length)))
    }
}

public struct ScreenFramePoster: Sendable {
    public var url: URL
    public init(url: URL = ScreenRelay.inboxURL) { self.url = url }

    public func post(_ jpeg: Data) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        request.httpBody = jpeg
        request.timeoutInterval = 2
        request.setValue("close", forHTTPHeaderField: "Connection")
        let task = URLSession.shared.dataTask(with: request)
        task.resume()
    }
}
