import Foundation
import LojoRemote

/// Talks to the site gateway the phone already paired, or to an explicit relay
/// from a launch override or the hidden Settings override.
@MainActor
final class RemoteSiteAccess {
    let launch: LaunchOptions
    let site: NetworkStore
    private var pinned: (String, URLSession)?

    init(launch: LaunchOptions, site: NetworkStore) {
        self.launch = launch
        self.site = site
    }

    var usesPairedGateway: Bool { explicitRelay() == nil && site.isPaired }

    func clients() -> [RelayClient] {
        if let explicit = explicitRelay() {
            return [RelayClient(baseURL: explicit.url, networkCode: explicit.code, transport: AdaptiveRelayTransport())]
        }
        guard let ca = site.siteCA else { return [] }
        let transport = pinnedTransport(ca)
        return orderedEndpoints().map {
            RelayClient(baseURL: $0.baseURL, networkCode: ca.sha256, transport: transport)
        }
    }

    func missingMessage() -> String {
        if site.isPaired {
            return "Can't reach the site gateway."
        }
        return "Pair this phone with your site gateway. The other phone has to be paired to the same site."
    }

    func first<T>(_ work: (RelayClient) async throws -> T) async throws -> T {
        let list = clients()
        guard !list.isEmpty else { throw RelayError.badResponse }
        var last: Error = RelayError.badResponse
        for client in list {
            do { return try await work(client) }
            catch { last = error }
        }
        throw last
    }

    private func explicitRelay() -> (url: URL, code: String)? {
        if let text = launch.relayURLText, let url = RelayEndpoint.url(from: text) {
            let code = launch.networkCode ?? ""
            if !code.isEmpty { return (url, code) }
        }
        let savedURL = UserDefaults.standard.string(forKey: RemotePreferences.urlKey) ?? ""
        let savedCode = UserDefaults.standard.string(forKey: RemotePreferences.codeKey) ?? ""
        if let url = RelayEndpoint.url(from: savedURL), !savedCode.isEmpty {
            return (url, savedCode)
        }
        return nil
    }

    /// The path that is already up, then LAN, then the private overlay.
    private func orderedEndpoints() -> [GatewayEndpoint] {
        let all = site.endpoints()
        switch site.link {
        case .connected(let current):
            return [current] + all.filter { $0 != current }
        case .connecting, .unreachable, .demo:
            return all
        }
    }

    private func pinnedTransport(_ ca: SiteCA) -> RelayTransport {
        if pinned?.0 != ca.sha256 {
            pinned = (ca.sha256, GatewayClient.makeSession(timeout: 8, anchor: ca))
        }
        return PinnedRelayTransport(session: pinned!.1)
    }
}

struct PinnedRelayTransport: RelayTransport {
    let session: URLSession

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw RelayError.badResponse }
        return (data, http)
    }
}
