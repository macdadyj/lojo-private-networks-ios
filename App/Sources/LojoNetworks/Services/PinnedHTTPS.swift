import Foundation
import Network
import Security

/// HTTPS on Network.framework. The verify block is the whole trust decision: the connection is
/// accepted only after the explicit pin (chain fingerprint, SecKey signature, name, and dates).
/// `SecTrustEvaluateWithError` does not get to abort the handshake on its own, which is what
/// turned a valid private CA into `errSSLFatalAlert (-9802)` with no recorded reason.
enum PinnedHTTPS {
    private static let maxBytes = 12 * 1024 * 1024

    static func send(_ request: URLRequest, timeout: TimeInterval, pinning: PinningDelegate) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url, url.scheme == "https", let host = url.host, !host.isEmpty,
              let port = NWEndpoint.Port(rawValue: UInt16(GatewayAddress.port(of: url))) else {
            throw URLError(.badURL)
        }
        let payload = PlainHTTP.message(request, host: host, port: port.rawValue)
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        let box = Box()
        let queue = DispatchQueue(label: "lojo.pinnedhttps")
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
            let decision = pinning.evaluatePeer(trust: sec_trust_copy_ref(trust).takeRetainedValue(), url: url)
            box.store(decision)
            // Complete off this queue. Completing inline can deadlock the handshake queue.
            DispatchQueue.global(qos: .userInitiated).async {
                complete(decision.accepted)
            }
        }, queue)

        let params = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.connectionTimeout = max(1, Int(timeout))
        }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: port, using: params)

        let raw = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            @Sendable func finish(_ result: Result<Data, Error>) {
                guard box.claim() else { return }
                conn.cancel()
                cont.resume(with: result)
            }
            @Sendable func receive() {
                conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { chunk, _, complete, error in
                    if let chunk { box.data.append(chunk) }
                    if box.data.count > maxBytes { return finish(.failure(URLError(.dataLengthExceedsMaximum))) }
                    if let error { return finish(.failure(transport(error, box: box))) }
                    if complete { return finish(.success(box.data)) }
                    receive()
                }
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    conn.send(content: payload, completion: .contentProcessed { error in
                        if let error { finish(.failure(transport(error, box: box))) } else { receive() }
                    })
                case .waiting:
                    if conn.currentPath?.unsatisfiedReason == .localNetworkDenied {
                        finish(.failure(GatewayError.localNetworkDenied))
                    }
                case .failed(let error):
                    finish(.failure(transport(error, box: box)))
                case .setup, .preparing, .cancelled:
                    break
                @unknown default:
                    break
                }
            }
            conn.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                finish(.failure(transportTimeout(box: box)))
            }
        }
        return try PlainHTTP.parse(raw, url: url)
    }

    private static func transport(_ error: NWError, box: Box) -> Error {
        let decision = box.current()
        if let failure = decision?.failure { return GatewayError.tls(failure) }
        if decision?.accepted == true {
            let detail = "The pin matched and the leaf signature verified, but the connection still failed (\(text(error))). \(decision?.report ?? "")"
            return GatewayError.tls(TLSFailure(kind: .handshake(code: -9802), detail: detail))
        }
        return GatewayError.tls(TLSFailure(
            kind: .handshake(code: -9802),
            detail: "The TLS verify block did not run. \(text(error))"
        ))
    }

    private static func transportTimeout(box: Box) -> Error {
        let decision = box.current()
        if let failure = decision?.failure { return GatewayError.tls(failure) }
        if decision?.accepted == true {
            return GatewayError.tls(TLSFailure(kind: .handshake(code: -9802), detail: "The pin was accepted, then the request timed out. \(decision?.report ?? "")"))
        }
        return URLError(.timedOut)
    }

    private static func text(_ error: NWError) -> String {
        switch error {
        case .posix(let code):
            return "POSIX \(code.rawValue)"
        case .tls(let status):
            return "OSStatus \(status)"
        case .dns(let code):
            return "DNS \(code)"
        @unknown default:
            return String(describing: error)
        }
    }

    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var done = false
        var data = Data()
        private var decision: PinningDelegate.PeerDecision?
        func claim() -> Bool { lock.withLock { if done { return false }; done = true; return true } }
        func store(_ decision: PinningDelegate.PeerDecision) { lock.withLock { self.decision = decision } }
        func current() -> PinningDelegate.PeerDecision? { lock.withLock { decision } }
    }
}
