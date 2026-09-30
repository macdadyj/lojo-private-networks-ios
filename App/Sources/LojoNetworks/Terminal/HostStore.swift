import Foundation
import LojoSSH

/// Saved hosts, the gateway directory cache and known_hosts, all in Application Support/ssh.
/// None of these files hold secrets.
@MainActor
final class HostStore: ObservableObject {
    @Published private(set) var hosts: [SSHHost] = []
    @Published private(set) var directory: DirectorySnapshot?
    @Published private(set) var knownHosts = KnownHosts()

    let directoryURL: URL
    private var hostsURL: URL { directoryURL.appendingPathComponent("hosts.json") }
    private var directoryCacheURL: URL { directoryURL.appendingPathComponent("directory.json") }
    private var knownHostsURL: URL { directoryURL.appendingPathComponent("known_hosts") }

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directoryURL = base.appendingPathComponent("ssh", isDirectory: true)
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        var excluded = URLResourceValues()
        excluded.isExcludedFromBackup = true
        var dir = directoryURL
        try? dir.setResourceValues(excluded)

        if let data = try? Data(contentsOf: hostsURL), let list = try? JSONDecoder().decode([SSHHost].self, from: data) {
            hosts = list
        }
        if let data = try? Data(contentsOf: directoryCacheURL) {
            directory = try? JSONDecoder().decode(DirectorySnapshot.self, from: data)
        }
        if let text = try? String(contentsOf: knownHostsURL, encoding: .utf8) {
            knownHosts = KnownHosts(parsing: text)
        }
    }

    var gateway: SSHHost? { hosts.first(where: \.isGateway) }

    /// Groups in display order: Gateway first, then alphabetical.
    var groups: [(name: String, hosts: [SSHHost])] {
        Dictionary(grouping: hosts, by: \.group)
            .map { ($0.key, $0.value.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }) }
            .sorted { a, b in
                if a.0 == "Gateway" { return true }
                if b.0 == "Gateway" { return false }
                return a.0.localizedCaseInsensitiveCompare(b.0) == .orderedAscending
            }
    }

    var policy: OverlayPolicy {
        let routes = directory?.routes.compactMap(IPv4Range.init(cidr:)) ?? []
        return OverlayPolicy(routes: routes.isEmpty ? OverlayPolicy.defaultRoutes : routes)
    }

    /// The gateway the app already talks to is the first SSH host.
    func seedGateway(overlayGatewayURL: String, port: Int?) {
        guard let host = URL(string: overlayGatewayURL)?.host, OverlayPolicy().allows(address: host) else { return }
        if var gw = gateway {
            if let port, gw.port != port {
                gw.port = port
                upsert(gw)
            }
            return
        }
        upsert(SSHHost(label: "Site gateway", address: host, port: port ?? 22, username: "jon", group: "Gateway", isGateway: true))
    }

    func upsert(_ host: SSHHost) {
        if let i = hosts.firstIndex(where: { $0.id == host.id }) {
            hosts[i] = host
        } else {
            hosts.append(host)
        }
        persistHosts()
    }

    func delete(_ host: SSHHost) {
        hosts.removeAll { $0.id == host.id }
        persistHosts()
    }

    func isSaved(_ entry: DirectoryEntry) -> Bool {
        hosts.contains { $0.address == entry.address && $0.port == entry.port }
    }

    @discardableResult
    func save(_ entry: DirectoryEntry) -> SSHHost {
        if let existing = hosts.first(where: { $0.address == entry.address && $0.port == entry.port }) { return existing }
        let host = SSHHost(
            label: entry.name, address: entry.address, port: entry.port,
            username: entry.user ?? (entry.name.lowercased().contains("pi") || entry.name.lowercased().contains("vision") ? "pi" : "jon"),
            group: entry.group
        )
        upsert(host)
        return host
    }

    func setDirectory(_ snapshot: DirectorySnapshot, raw: Data) {
        directory = snapshot
        try? raw.write(to: directoryCacheURL, options: .atomic)
    }

    // MARK: known_hosts

    func trust(_ key: HostKeyInfo, for host: SSHHost, address: String) {
        knownHosts.trust(address: address, port: host.port, key: key)
        persistKnownHosts()
    }

    func forgetHostKey(for host: SSHHost) {
        knownHosts.forget(address: host.address, port: host.port)
        persistKnownHosts()
    }

    func savedHostKeys(for host: SSHHost) -> [KnownHosts.Entry] {
        knownHosts.entries(address: host.address, port: host.port)
    }

    private func persistHosts() {
        if let data = try? JSONEncoder().encode(hosts) { try? data.write(to: hostsURL, options: .atomic) }
    }

    private func persistKnownHosts() {
        try? knownHosts.serialized().write(to: knownHostsURL, atomically: true, encoding: .utf8)
    }
}
