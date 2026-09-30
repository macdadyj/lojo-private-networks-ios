import Foundation
import Network

/// Minimal HTTP/1.1 client for the labelled legacy fallback (gateways that aren't paired, or plain
/// HTTP over the VPN). It runs on the Network framework, which App Transport Security doesn't
/// govern, so the app ships with no ATS exceptions and URLSession only ever speaks HTTPS.
/// Failures are reported as the URLError codes URLSession would use, so diagnostics read the same.
enum PlainHTTP {
    private static let maxBytes = 12 * 1024 * 1024

    static func send(_ request: URLRequest, timeout: TimeInterval) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url, url.scheme == "http", let host = url.host,
              let port = NWEndpoint.Port(rawValue: UInt16(url.port ?? 80)) else {
            throw URLError(.badURL)
        }
        var target = url.path.isEmpty ? "/" : url.path
        if let q = url.query { target += "?" + q }
        var head = "\(request.httpMethod ?? "GET") \(target) HTTP/1.1\r\n"
        head += "Host: \(host):\(port.rawValue)\r\nConnection: close\r\nAccept: */*\r\nUser-Agent: LOJONetworks\r\n"
        for (k, v) in request.allHTTPHeaderFields ?? [:] { head += "\(k): \(v)\r\n" }
        let body = request.httpBody ?? Data()
        if !body.isEmpty || request.httpMethod == "POST" { head += "Content-Length: \(body.count)\r\n" }
        head += "\r\n"
        let payload = Data(head.utf8) + body

        let raw = try await exchange(host: host, port: port, payload: payload, timeout: timeout)
        return try parse(raw, url: url)
    }

    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var done = false
        var data = Data()
        func claim() -> Bool { lock.withLock { if done { return false }; done = true; return true } }
    }

    private static func exchange(host: String, port: NWEndpoint.Port, payload: Data, timeout: TimeInterval) async throws -> Data {
        let params = NWParameters.tcp
        if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.connectionTimeout = max(1, Int(timeout))
        }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: port, using: params)
        let queue = DispatchQueue(label: "lojo.plainhttp")
        let box = Box()

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            @Sendable func finish(_ result: Result<Data, Error>) {
                guard box.claim() else { return }
                conn.cancel()
                cont.resume(with: result)
            }
            @Sendable func receive() {
                conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { chunk, _, complete, error in
                    if let chunk { box.data.append(chunk) }
                    if box.data.count > maxBytes { return finish(.failure(URLError(.dataLengthExceedsMaximum))) }
                    if let error { return finish(.failure(urlError(error))) }
                    if complete { return finish(.success(box.data)) }
                    receive()
                }
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    conn.send(content: payload, completion: .contentProcessed { error in
                        if let error { finish(.failure(urlError(error))) } else { receive() }
                    })
                case .waiting(let error):
                    if conn.currentPath?.unsatisfiedReason == .localNetworkDenied {
                        finish(.failure(GatewayError.localNetworkDenied))
                    } else {
                        finish(.failure(urlError(error)))
                    }
                case .failed(let error):
                    finish(.failure(urlError(error)))
                default:
                    break
                }
            }
            conn.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { finish(.failure(URLError(.timedOut))) }
        }
    }

    private static func urlError(_ error: NWError) -> URLError {
        switch error {
        case .posix(let code):
            let underlying = NSError(domain: NSPOSIXErrorDomain, code: Int(code.rawValue))
            let info: [String: Any] = [NSUnderlyingErrorKey: underlying]
            switch code {
            case .ETIMEDOUT: return URLError(.timedOut, userInfo: info)
            case .ECONNRESET, .EPIPE: return URLError(.networkConnectionLost, userInfo: info)
            case .ENETDOWN: return URLError(.notConnectedToInternet, userInfo: info)
            default: return URLError(.cannotConnectToHost, userInfo: info)
            }
        case .dns: return URLError(.cannotFindHost)
        default: return URLError(.cannotConnectToHost)
        }
    }

    private static func parse(_ raw: Data, url: URL) throws -> (Data, HTTPURLResponse) {
        let sep = Data("\r\n\r\n".utf8)
        guard let range = raw.range(of: sep),
              let headText = String(data: raw[..<range.lowerBound], encoding: .utf8) else {
            throw URLError(.badServerResponse)
        }
        var lines = headText.components(separatedBy: "\r\n")
        let status = lines.removeFirst().split(separator: " ")
        guard status.count >= 2, status[0].hasPrefix("HTTP/"), let code = Int(status[1]) else {
            throw URLError(.badServerResponse)
        }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[String(line[..<colon])] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        var body = Data(raw[range.upperBound...])
        let chunked = headers.first { $0.key.lowercased() == "transfer-encoding" }?.value.lowercased().contains("chunked") == true
        if chunked { body = try dechunk(body) }
        guard let response = HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: headers) else {
            throw URLError(.badServerResponse)
        }
        return (body, response)
    }

    private static func dechunk(_ data: Data) throws -> Data {
        var out = Data()
        var i = data.startIndex
        let crlf = Data("\r\n".utf8)
        while i < data.endIndex {
            guard let lineEnd = data.range(of: crlf, in: i..<data.endIndex),
                  let sizeText = String(data: data[i..<lineEnd.lowerBound], encoding: .ascii),
                  let size = Int(sizeText.split(separator: ";")[0].trimmingCharacters(in: .whitespaces), radix: 16)
            else { throw URLError(.cannotDecodeRawData) }
            if size == 0 { break }
            let start = lineEnd.upperBound
            let end = data.index(start, offsetBy: size, limitedBy: data.endIndex) ?? data.endIndex
            out.append(data[start..<end])
            i = data.index(end, offsetBy: 2, limitedBy: data.endIndex) ?? data.endIndex
        }
        return out
    }
}
