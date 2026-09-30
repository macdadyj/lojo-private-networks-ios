import Foundation

/// A URL-loading failure with the exact system code, so the UI can say precisely what went wrong.
struct TransportFailure: Sendable, Hashable {
    let code: Int
    let posix: Int32?
    let pathNote: String?

    var urlCode: URLError.Code { URLError.Code(rawValue: code) }

    var isATSBlock: Bool { urlCode == .appTransportSecurityRequiresSecureConnection }

    /// e.g. "NSURLErrorTimedOut (-1001)"
    var codeName: String {
        let name: String
        switch urlCode {
        case .timedOut: name = "NSURLErrorTimedOut"
        case .cannotConnectToHost: name = "NSURLErrorCannotConnectToHost"
        case .cannotFindHost: name = "NSURLErrorCannotFindHost"
        case .dnsLookupFailed: name = "NSURLErrorDNSLookupFailed"
        case .notConnectedToInternet: name = "NSURLErrorNotConnectedToInternet"
        case .networkConnectionLost: name = "NSURLErrorNetworkConnectionLost"
        case .appTransportSecurityRequiresSecureConnection: name = "NSURLErrorAppTransportSecurityRequiresSecureConnection"
        case .secureConnectionFailed: name = "NSURLErrorSecureConnectionFailed"
        case .serverCertificateUntrusted: name = "NSURLErrorServerCertificateUntrusted"
        case .badServerResponse: name = "NSURLErrorBadServerResponse"
        case .dataNotAllowed: name = "NSURLErrorDataNotAllowed"
        case .internationalRoamingOff: name = "NSURLErrorInternationalRoamingOff"
        case .badURL: name = "NSURLErrorBadURL"
        case .unsupportedURL: name = "NSURLErrorUnsupportedURL"
        case .cancelled: name = "NSURLErrorCancelled"
        default: name = "NSURLError"
        }
        return "\(name) (\(code))"
    }

    var meaning: String {
        switch urlCode {
        case .timedOut: return "No answer before the timeout. The address isn't reachable on the path this phone is using."
        case .cannotConnectToHost: return "The address was reached but nothing accepted the connection on that port (refused or no route)."
        case .cannotFindHost, .dnsLookupFailed: return "The gateway name couldn't be resolved. Private names only resolve with the LOJO VPN on."
        case .notConnectedToInternet: return "iOS says there's no usable network path to that address."
        case .networkConnectionLost: return "The connection dropped mid-request, often while switching Wi‑Fi or VPN."
        case .appTransportSecurityRequiresSecureConnection: return "iOS App Transport Security blocked plain HTTP to this address before any packet was sent."
        case .secureConnectionFailed, .serverCertificateUntrusted: return "A secure (HTTPS) connection couldn't be set up."
        case .badServerResponse: return "Something answered, but not like a LOJO gateway."
        case .dataNotAllowed, .internationalRoamingOff: return "Cellular data is off or restricted for this app."
        case .badURL, .unsupportedURL: return "The gateway address isn't a valid http:// address."
        default: return "The request failed."
        }
    }

    var posixText: String? {
        guard let posix else { return nil }
        let name: String
        switch posix {
        case 50: name = "ENETDOWN"
        case 51: name = "ENETUNREACH"
        case 54: name = "ECONNRESET"
        case 60: name = "ETIMEDOUT"
        case 61: name = "ECONNREFUSED"
        case 64: name = "EHOSTDOWN"
        case 65: name = "EHOSTUNREACH"
        default: name = "errno"
        }
        return "\(name) (\(posix))"
    }

    init(code: Int, posix: Int32? = nil, pathNote: String? = nil) {
        self.code = code
        self.posix = posix
        self.pathNote = pathNote
    }

    init(_ error: URLError) {
        let ns = error as NSError
        var posix: Int32?
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            let domain = underlying.userInfo["_kCFStreamErrorDomainKey"] as? Int
            let streamCode = underlying.userInfo["_kCFStreamErrorCodeKey"] as? Int
            if domain == 1, let streamCode { posix = Int32(streamCode) }
            else if underlying.domain == NSPOSIXErrorDomain { posix = Int32(underlying.code) }
        }
        let path = ns.userInfo["_NSURLErrorNWPathKey"].map { String(describing: $0) }
        self.init(code: error.errorCode, posix: posix, pathNote: path)
    }
}

enum GatewayError: LocalizedError, Sendable {
    case http(status: Int, message: String?)
    case badResponse
    case transport(TransportFailure)
    case localNetworkDenied

    var errorDescription: String? {
        switch self {
        case .http(let status, let message):
            if let message, !message.isEmpty { return Self.friendly(serverMessage: message) }
            return "The gateway answered with HTTP \(status)."
        case .badResponse:
            return "Something answered, but not like a LOJO gateway."
        case .transport(let failure):
            return failure.meaning
        case .localNetworkDenied:
            return "iOS is blocking this app from the local network (Local Network permission is off)."
        }
    }

    /// Short technical tag for diagnostics and toasts, e.g. "NSURLErrorTimedOut (-1001)".
    var technical: String {
        switch self {
        case .http(let status, _): return "HTTP \(status)"
        case .badResponse: return "Unreadable reply"
        case .transport(let f):
            if let p = f.posixText { return "\(f.codeName) · \(p)" }
            return f.codeName
        case .localNetworkDenied: return "Local network prohibited"
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
            return .transport(TransportFailure(e))
        }
        return .badResponse
    }
}

struct ProbeResult: Sendable {
    let endpoint: GatewayEndpoint
    let network: GatewayNetwork?
    let latencyMs: Int?
    let error: GatewayError?
    var elapsedMs: Int? = nil

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

    static func probe(_ endpoint: GatewayEndpoint, timeout: TimeInterval = 5) async -> ProbeResult {
        let client = GatewayClient(endpoint: endpoint, session: makeSession(timeout: timeout))
        let start = Date()
        do {
            let net = try await client.network()
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            return ProbeResult(endpoint: endpoint, network: net, latencyMs: ms, error: nil, elapsedMs: ms)
        } catch {
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            return ProbeResult(endpoint: endpoint, network: nil, latencyMs: nil, error: GatewayError.wrap(error), elapsedMs: ms)
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
