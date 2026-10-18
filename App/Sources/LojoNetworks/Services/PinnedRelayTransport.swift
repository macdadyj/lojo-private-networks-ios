import Foundation
import LojoRemote

/// HTTPS for iPhone Remote Controller on a paired gateway.
///
/// This is the same Network.framework verify block `/v1/network` uses. A plain `URLSession`
/// evaluates the private site CA with the system trust store and aborts the handshake
/// (`errSSLFatalAlert`), which the gateway logs as `ECONNRESET` and never as HTTP.
struct PinnedRelayTransport: RelayTransport {
    let pinning: PinningDelegate
    let timeout: TimeInterval

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            if request.url?.scheme == "http" {
                return try await PlainHTTP.send(request, timeout: timeout)
            }
            return try await PinnedHTTPS.send(request, timeout: timeout, pinning: pinning)
        } catch {
            throw GatewayError.wrap(error, url: request.url)
        }
    }
}

struct RemoteAttemptFailure: Error, Sendable {
    var summary: String
}

enum RemoteDiagnostics {
    static func text(_ error: Error) -> String {
        if let failure = error as? RemoteAttemptFailure { return failure.summary }
        if let gateway = error as? GatewayError {
            let meaning = gateway.errorDescription ?? ""
            if meaning.isEmpty { return gateway.technical }
            return "\(gateway.technical). \(meaning)"
        }
        if let relay = error as? RelayError {
            switch relay {
            case .badResponse:
                return "Unreadable reply"
            case .status(let code, let body):
                let trimmed = body.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { return "HTTP \(code)" }
                return "HTTP \(code) \(trimmed)"
            }
        }
        if let urlError = error as? URLError {
            let failure = TransportFailure(urlError)
            return "\(failure.codeName). \(failure.meaning)"
        }
        let ns = error as NSError
        return "\(ns.domain) \(ns.code) \(ns.localizedDescription)"
    }

    static func summary(attempts: [(url: URL, error: Error)]) -> String {
        attempts.map { url, error in
            "\(url.absoluteString) — \(text(error))"
        }.joined(separator: "\n")
    }
}
