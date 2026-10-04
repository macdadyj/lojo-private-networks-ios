import Foundation

/// Host-side tmux commands for a Terminal tab. The phone never installs software: the install
/// line is only shown, and every command is built here so it can be checked without a connection.
public enum TmuxCommand {
    /// Private tmux server. The default server is left alone, including its options.
    public static let socketName = "lojo"
    public static let term = "xterm-256color"
    public static let probeCommand = "command -v tmux"
    /// Shown in the app. Nothing in the app runs this.
    public static let installCommand = "sudo apt-get install --no-install-recommends tmux"
    public static let reconnectingTitle = "Reconnecting…"
    public static let missingNotice = "tmux isn't installed on this host, so this shell ends if the connection drops."
    public static let unknownNotice = "Couldn't check for tmux on this host. This shell ends if the connection drops."
    public static let keptOnHostStatus = "Connected · kept on host"

    /// `lojo-` plus a tmux-safe slug of the host label. Generation 2 and up adds `-2`, `-3`, …
    /// so a second tab is its own session and a reopened tab reattaches to generation 1.
    public static func sessionName(forLabel label: String, generation: Int = 1) -> String {
        var slug = ""
        var dash = false
        for scalar in label.lowercased().unicodeScalars {
            let ch = Character(scalar)
            if ch.isASCII, ch.isLetter || ch.isNumber {
                slug.append(ch)
                dash = false
            } else if !dash, !slug.isEmpty {
                slug.append("-")
                dash = true
            }
        }
        while slug.last == "-" { slug.removeLast() }
        if slug.isEmpty { slug = "host" }
        if slug.count > 48 {
            slug = String(slug.prefix(48))
            while slug.last == "-" { slug.removeLast() }
        }
        let name = generation > 1 ? "lojo-\(slug)-\(generation)" : "lojo-\(slug)"
        return isSafeName(name) ? name : "lojo-host"
    }

    /// Letters, digits, hyphen, underscore. tmux rejects `.` and `:`, and a shell metacharacter
    /// must never reach the host.
    public static func isSafeName(_ name: String) -> Bool {
        guard (1...80).contains(name.count), let first = name.first, first.isASCII, first.isLetter || first.isNumber else {
            return false
        }
        return name.allSatisfy { ch in
            ch.isASCII && (ch.isLetter || ch.isNumber || ch == "-" || ch == "_")
        }
    }

    public static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func clampDimension(_ value: Int, fallback: Int) -> Int {
        let resolved = value >= 2 ? value : fallback
        return min(max(resolved, 2), 500)
    }

    public static func probeFound(status: Int?, output: Data) -> Bool {
        guard status == 0 else { return false }
        return output.contains { byte in
            byte != 0x0a && byte != 0x0d && byte != 0x20 && byte != 0x09
        }
    }

    /// tmux exits non-zero with no stdout when its server isn't running. stderr is not collected.
    public static func listIsEmpty(status: Int?, output: Data) -> Bool {
        if status == 0 { return false }
        return output.allSatisfy { $0 == 0x0a || $0 == 0x0d || $0 == 0x20 || $0 == 0x09 }
    }

    public static func listCommand(socket: String = socketName) -> String {
        let format = "#{session_name}\\t#{session_attached}\\t#{session_windows}\\t#{session_created}"
        return "tmux -L \(quote(socket)) list-sessions -F \(quote(format))"
    }

    public static func killCommand(session: String, socket: String = socketName) -> String? {
        guard isSafeName(session), isSafeName(socket) else { return nil }
        return "tmux -L \(quote(socket)) kill-session -t \(quote(session))"
    }

    public static func parseSessionList(_ text: String) -> [TmuxRemoteSession] {
        var rows: [TmuxRemoteSession] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 3 else { continue }
            let name = fields[0]
            guard isSafeName(name) else { continue }
            rows.append(TmuxRemoteSession(
                name: name,
                attached: Int(fields[1]) ?? 0,
                windows: Int(fields[2]) ?? 0,
                created: fields.count > 3 ? fields[3] : ""
            ))
        }
        return rows
    }

    /// Sample rows for the session-list screenshot hook. No real host names.
    public static let previewSessions: [TmuxRemoteSession] = [
        TmuxRemoteSession(name: "lojo-demo-host", attached: 0, windows: 1, created: "0"),
        TmuxRemoteSession(name: "lojo-demo-host-2", attached: 1, windows: 1, created: "0"),
    ]
}

/// What `tmux list-sessions` reported for one session on the `lojo` socket.
public struct TmuxRemoteSession: Equatable, Sendable, Identifiable {
    public var name: String
    public var attached: Int
    public var windows: Int
    public var created: String

    public var id: String { name }

    public init(name: String, attached: Int, windows: Int, created: String) {
        self.name = name
        self.attached = attached
        self.windows = windows
        self.created = created
    }

    public var detail: String {
        let windowsText = windows == 1 ? "1 window" : "\(windows) windows"
        let attachedText: String
        switch attached {
        case 0: attachedText = "detached"
        case 1: attachedText = "1 client attached"
        default: attachedText = "\(attached) clients attached"
        }
        return "\(windowsText) · \(attachedText)"
    }
}

/// Create-or-attach. Equivalent to `tmux new-session -A -s <name>`: the session is created the
/// first time and reattached after that, so a dropped SSH connection does not kill the shell.
public struct TmuxAttach: Equatable, Sendable {
    public var socket: String
    public var session: String
    public var columns: Int
    public var rows: Int
    public var mouse: Bool
    public var historyLimit: Int
    public var term: String

    public init(
        socket: String = TmuxCommand.socketName,
        session: String,
        columns: Int,
        rows: Int,
        mouse: Bool,
        historyLimit: Int = 50_000,
        term: String = TmuxCommand.term
    ) {
        self.socket = socket
        self.session = session
        self.columns = TmuxCommand.clampDimension(columns, fallback: 80)
        self.rows = TmuxCommand.clampDimension(rows, fallback: 24)
        self.mouse = mouse
        self.historyLimit = min(max(historyLimit, 1_000), 200_000)
        self.term = term
    }

    /// Shell script run under `exec /bin/sh -c`. Options that an older tmux rejects are skipped.
    /// Mouse defaults off so scrolling and copy stay in the phone's terminal. The status line is
    /// off so a full-screen TUI gets every row. `default-terminal` is xterm-256color.
    public var shellScript: String {
        let sock = TmuxCommand.quote(socket)
        let name = TmuxCommand.quote(session)
        let term = TmuxCommand.quote(term)
        let mouseFlag = mouse ? "on" : "off"
        return """
        tmux -L \(sock) has-session -t \(name) 2>/dev/null || tmux -L \(sock) new-session -A -d -s \(name) -x \(columns) -y \(rows) || exit 1
        tmux -L \(sock) set-option -t \(name) history-limit \(historyLimit) 2>/dev/null || true
        tmux -L \(sock) set-option -t \(name) mouse \(mouseFlag) 2>/dev/null || true
        tmux -L \(sock) set-option -t \(name) status off 2>/dev/null || true
        tmux -L \(sock) set-option -g default-terminal \(term) 2>/dev/null || true
        tmux -L \(sock) set-option -g escape-time 10 2>/dev/null || true
        tmux -L \(sock) set-option -g focus-events on 2>/dev/null || true
        tmux -L \(sock) set-option -g window-size latest 2>/dev/null || true
        exec tmux -L \(sock) attach-session -t \(name)
        """
    }

    public var execCommand: String {
        "exec /bin/sh -c \(TmuxCommand.quote(shellScript))"
    }
}

/// Per-host persistence flags. Missing keys keep the defaults, so a hosts file written before
/// this setting still decodes and keeps sessions alive.
public struct HostSessionSettings: Codable, Equatable, Sendable {
    public var keepSessionsAlive: Bool
    public var tmuxMouse: Bool

    public init(keepSessionsAlive: Bool = true, tmuxMouse: Bool = false) {
        self.keepSessionsAlive = keepSessionsAlive
        self.tmuxMouse = tmuxMouse
    }

    private enum CodingKeys: String, CodingKey {
        case keepSessionsAlive
        case tmuxMouse
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        keepSessionsAlive = try container.decodeIfPresent(Bool.self, forKey: .keepSessionsAlive) ?? true
        tmuxMouse = try container.decodeIfPresent(Bool.self, forKey: .tmuxMouse) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(keepSessionsAlive, forKey: .keepSessionsAlive)
        try container.encode(tmuxMouse, forKey: .tmuxMouse)
    }
}

/// Keystrokes typed while the socket is down. Drained once the same session is attached again.
public struct TerminalInputBuffer: Equatable, Sendable {
    public static let limit = 256 * 1024
    private var bytes: [UInt8] = []
    public private(set) var dropped = 0

    public init() {}

    public var isEmpty: Bool { bytes.isEmpty }
    public var count: Int { bytes.count }

    public mutating func append(_ data: [UInt8]) {
        guard !data.isEmpty else { return }
        bytes.append(contentsOf: data)
        if bytes.count > Self.limit {
            let extra = bytes.count - Self.limit
            bytes.removeFirst(extra)
            dropped += extra
        }
    }

    public mutating func drain() -> [UInt8] {
        let out = bytes
        bytes.removeAll(keepingCapacity: false)
        return out
    }

    public mutating func clear() {
        bytes.removeAll(keepingCapacity: false)
    }
}
