import Foundation

enum GatewayError: LocalizedError, Sendable {
    case http(status: Int, message: String?)
    case badResponse
    case transport(URLError.Code)
    case localNetworkDenied

    var errorDescription: String? {
        switch self {
        case .http(let status, let message):
            if let message, !message.isEmpty { return Self.friendly(serverMessage: message) }
            return "The gateway answered with an error (\(status))."
        case .badResponse:
            return "The gateway sent a reply the app couldn't read."
        case .transport(let code):
            return Self.describe(code)
        case .localNetworkDenied:
            return "iOS is blocking this app from the local network."
        }
    }

    static func describe(_ code: URLError.Code) -> String {
        switch code {
        case .timedOut: return "No answer — the request timed out."
        case .cannotConnectToHost: return "The gateway address answered but refused the connection."
        case .cannotFindHost, .dnsLookupFailed: return "The gateway address couldn't be found."
        case .notConnectedToInternet: return "This phone has no network connection."
        case .networkConnectionLost: return "The connection dropped mid-request."
        case .internationalRoamingOff, .dataNotAllowed: return "Cellular data isn't available."
        case .secureConnectionFailed: return "A secure connection couldn't be set up."
        default: return "The network request failed."
        }
    }

    private static func friendly(serverMessage: String) -> String {
        switch serverMessage {
        case "unknown device": return "That device isn't on the network right now."
        case "webcam disabled on device": return "This device's camera is turned off."
        case "cloud hub not connected": return "The site gateway has lost the cloud hub. Try again shortly."
        case "no still": return "No still is available yet."
        default: return serverMessage.prefix(1).uppercased() + serverMessage.dropFirst()
        }
    }

    static func wrap(_ error: Error) -> GatewayError {
        if let e = error as? GatewayError { return e }
        if let e = error as? URLError {
            // iOS reports a declined Local Network permission as an unsatisfied path, not a distinct code.
            let path = String(describing: e.userInfo["_NSURLErrorNWPathKey"] ?? "")
            if path.localizedCaseInsensitiveContains("local network prohibited") { return .localNetworkDenied }
            return .transport(e.code)
        }
        return .badResponse
    }
}

struct ProbeResult: Sendable {
    let endpoint: GatewayEndpoint
    let network: GatewayNetwork?
    let latencyMs: Int?
    let error: GatewayError?

    var reachable: Bool { network != nil }
}

struct GatewayClient: Sendable {
    let endpoint: GatewayEndpoint
    let session: URLSession

    static func makeSession(timeout: TimeInterval) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout * 2
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }

    private struct DevicesEnvelope: Decodable {
        var ok: Bool
        var devices: [Device]
    }

    private struct EventsEnvelope: Decodable {
        var ok: Bool
        var events: [NetworkEvent]
    }

    private struct ActionReply: Decodable {
        var ok: Bool
        var error: String?
    }

    func network() async throws -> GatewayNetwork {
        try await get("v1/network")
    }

    func devices() async throws -> [Device] {
        let env: DevicesEnvelope = try await get("v1/devices")
        return env.devices
    }

    func events(limit: Int = 150) async throws -> [NetworkEvent] {
        let env: EventsEnvelope = try await get("v1/events?limit=\(limit)")
        return env.events
    }

    func still(path: String) async throws -> Data {
        guard let url = URL(string: path, relativeTo: endpoint.baseURL) else { throw GatewayError.badResponse }
        let (data, response) = try await send(URLRequest(url: url))
        guard response.statusCode == 200, !data.isEmpty else {
            throw GatewayError.http(status: response.statusCode, message: nil)
        }
        return data
    }

    func requestCapture(socketID: String) async throws {
        try await post("devices/\(escape(socketID))/capture", body: nil)
    }

    func setOutput(socketID: String, pin: String, value: Int) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["pin": pin, "value": value])
        try await post("devices/\(escape(socketID))/gpio", body: body)
    }

    static func probe(_ endpoint: GatewayEndpoint, timeout: TimeInterval = 3) async -> ProbeResult {
        let client = GatewayClient(endpoint: endpoint, session: makeSession(timeout: timeout))
        let start = Date()
        do {
            let net = try await client.network()
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            return ProbeResult(endpoint: endpoint, network: net, latencyMs: ms, error: nil)
        } catch {
            return ProbeResult(endpoint: endpoint, network: nil, latencyMs: nil, error: GatewayError.wrap(error))
        }
    }

    // MARK: - plumbing

    private func escape(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? s
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        guard let url = URL(string: path, relativeTo: endpoint.baseURL) else { throw GatewayError.badResponse }
        let (data, response) = try await send(URLRequest(url: url))
        guard response.statusCode == 200 else {
            let reply = try? JSONDecoder().decode(ActionReply.self, from: data)
            throw GatewayError.http(status: response.statusCode, message: reply?.error)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw GatewayError.badResponse
        }
    }

    private func post(_ path: String, body: Data?) async throws {
        guard let url = URL(string: path, relativeTo: endpoint.baseURL) else { throw GatewayError.badResponse }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await send(req)
        let reply = try? JSONDecoder().decode(ActionReply.self, from: data)
        guard response.statusCode == 200, reply?.ok == true else {
            throw GatewayError.http(status: response.statusCode, message: reply?.error)
        }
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw GatewayError.badResponse }
            return (data, http)
        } catch {
            throw GatewayError.wrap(error)
        }
    }
}
