import Foundation
import LojoRemote

/// Talks to the site gateway the phone already paired, or to an explicit relay
/// from a launch override or the hidden Settings override.
@MainActor
final class RemoteSiteAccess {
    let launch: LaunchOptions
    let site: NetworkStore
    private var pinnedDelegate: (String, PinningDelegate)?
    /// The address that answered the last request.
    private(set) var lastURL: URL?
    /// Every address the last failed request tried, with the error from each.
    private(set) var lastFailure: String?

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
        let pinning = pinningDelegate(ca)
        let onSite = onSiteWiFi()
        return orderedEndpoints(onSite: onSite).map { endpoint in
            let timeout: TimeInterval = endpoint.path == .lan && !onSite ? 2 : 8
            let transport = PinnedRelayTransport(pinning: pinning, timeout: timeout)
            return RelayClient(baseURL: endpoint.baseURL, networkCode: ca.sha256, transport: transport)
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
        guard !list.isEmpty else {
            lastURL = nil
            lastFailure = missingMessage()
            throw RemoteAttemptFailure(summary: missingMessage())
        }
        var attempts: [(URL, Error)] = []
        var identityFailed = false
        for client in list {
            if identityFailed, client.baseURL.scheme != "https" { continue }
            do {
                let value = try await work(client)
                lastURL = client.baseURL
                lastFailure = nil
                return value
            } catch {
                attempts.append((client.baseURL, error))
                if Self.rejectsIdentity(error) { identityFailed = true }
            }
        }
        let summary = RemoteDiagnostics.summary(attempts: attempts)
        lastURL = attempts.last?.0
        lastFailure = summary
        throw RemoteAttemptFailure(summary: summary)
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

    /// On site Wi‑Fi, LAN then the overlay. Off site, the overlay first so a dead LAN route
    /// cannot hide the VPN address. A stale "connected" LAN path does not jump the queue.
    private func orderedEndpoints(onSite: Bool) -> [GatewayEndpoint] {
        let all = site.endpoints()
        let lan = all.first { $0.path == .lan }
        let overlay = all.first { $0.path == .overlay && $0.secure } ?? all.first { $0.path == .overlay }
        let connected: String?
        if case .connected(let endpoint) = site.link { connected = endpoint.baseURL.absoluteString }
        else { connected = nil }
        let urls = RemotePathOrder.order(
            lanURL: lan?.baseURL.absoluteString,
            overlayURL: overlay?.baseURL.absoluteString,
            connectedURL: connected,
            onSiteWiFi: onSite
        )
        var ordered: [GatewayEndpoint] = []
        for url in urls {
            guard let endpoint = all.first(where: { $0.baseURL.absoluteString == url }) else { continue }
            ordered.append(endpoint)
        }
        for endpoint in all where !ordered.contains(endpoint) {
            ordered.append(endpoint)
        }
        return ordered
    }

    private func onSiteWiFi() -> Bool {
        let lanHost = site.endpoints().first { $0.path == .lan }?.baseURL.host
        return RemotePathOrder.onSiteWiFi(lanHost: lanHost, wifiIPv4: PhoneInterfaces.current().wifiIPv4)
    }

    private func pinningDelegate(_ ca: SiteCA) -> PinningDelegate {
        if let existing = pinnedDelegate, existing.0 == ca.sha256 { return existing.1 }
        let created = PinningDelegate(anchor: ca)
        pinnedDelegate = (ca.sha256, created)
        return created
    }

    private static func rejectsIdentity(_ error: Error) -> Bool {
        guard let gateway = error as? GatewayError else { return false }
        return gateway.tlsFailure?.rejectsIdentity == true
    }
}
