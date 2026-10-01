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

    /// LOJO's own routed subnets plus whatever the gateway reports; a stale or partial device list
    /// must not make a connector-routed LAN unreachable.
    var policy: OverlayPolicy {
        var routes = OverlayPolicy.defaultRoutes
        for route in directory?.routes.compactMap(IPv4Range.init(cidr:)) ?? [] where !routes.contains(route) {
            routes.append(route)
        }
        return OverlayPolicy(routes: routes)
    }

    private static let seedVersionKey = "lojo.ssh.seededDefaults"
    private static let seedVersion = 1

    /// The gateway the app already talks to is the first SSH host. Once per seed version, the known
    /// LOJO devices are added and saved hosts at those addresses get their default user and port
    /// (builds before version 1 saved the gateway on 22 and guessed users).
    func seedDefaults(overlayGatewayURL: String, gatewayPort: Int?) {
        if gateway == nil, let address = URL(string: overlayGatewayURL)?.host, OverlayPolicy().allows(address: address) {
            let known = HostDefaults.match(address: address)
            upsert(SSHHost(
                label: known?.label ?? "Site gateway", address: address, port: known?.port ?? 22,
                username: known?.username ?? "jon", group: "Gateway", isGateway: true
            ))
        }
        let defaults = UserDefaults.standard
        if defaults.integer(forKey: Self.seedVersionKey) < Self.seedVersion {
            for known in HostDefaults.known {
                let matches = hosts.indices.filter { hosts[$0].address == known.address }
                if matches.isEmpty {
                    guard gateway?.address != known.address else { continue }
                    hosts.append(SSHHost(label: known.label, address: known.address, port: known.port, username: known.username, group: known.group))
                }
                for i in matches {
                    hosts[i].port = known.port
                    hosts[i].username = known.username
                    if hosts[i].label == "Site gateway" { hosts[i].label = known.label }
                }
            }
            persistHosts()
            defaults.set(Self.seedVersion, forKey: Self.seedVersionKey)
        }
        if let gatewayPort, var gw = gateway, gw.port != gatewayPort {
            gw.port = gatewayPort
            upsert(gw)
        }
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

    func saved(_ entry: DirectoryEntry) -> SSHHost? {
        let port = HostDefaults.port(for: entry)
        return hosts.first { $0.address == entry.address && ($0.port == port || $0.port == entry.port) }
    }

    func isSaved(_ entry: DirectoryEntry) -> Bool {
        saved(entry) != nil
    }

    @discardableResult
    func save(_ entry: DirectoryEntry) -> SSHHost {
        if let existing = saved(entry) { return existing }
        let host = SSHHost(
            label: entry.name, address: entry.address, port: HostDefaults.port(for: entry),
            username: HostDefaults.username(for: entry), group: entry.group
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
