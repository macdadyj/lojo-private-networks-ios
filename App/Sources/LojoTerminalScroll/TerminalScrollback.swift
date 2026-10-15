import Foundation

/// Build number shown in Settings. The archive job writes `CURRENT_PROJECT_VERSION`.
public enum AppBuildInfo: Sendable {
    public static func version(short: String?, build: String?) -> (version: String, build: String) {
        let version = (short?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? "1.0"
        let number = (build?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? "1"
        return (version, number)
    }

    public static func summary(short: String?, build: String?) -> String {
        let pair = version(short: short, build: build)
        return "\(pair.version) (\(pair.build))"
    }
}

/// Fake remote output for scrollback tests and the DEBUG preview. Each line is unique and stable.
public enum TerminalFlood: Sendable {
    public static func lines(_ count: Int, prefix: String = "line") -> String {
        guard count > 0 else { return "" }
        return (1...count).map { index in
            String(format: "%@ %05d grok-build-output", prefix, index)
        }.joined(separator: "\r\n") + "\r\n"
    }

    public static func enterAlternateScreen() -> String { "\u{1b}[?1049h" }
    public static func leaveAlternateScreen() -> String { "\u{1b}[?1049l" }
}

/// Scrollback policy for the phone terminal. Pure Foundation so Linux unit tests can run it.
///
/// SwiftTerm's iOS `TerminalView` is a `UIScrollView` that always snaps `contentOffset` to the
/// bottom and defaults to 500 lines of history. This policy is the source of truth for a large
/// buffer, pin-to-bottom while output streams, and translating a swipe into TUI wheel events
/// when the remote program owns the alternate screen.
public enum TerminalScrollback: Sendable {
    /// Lines kept above the live viewport. 10k+ so a Grok Build dump is still there.
    public static let historyLines = 10_240
    /// Stay pinned until the user has pulled this many lines off the bottom.
    public static let unpinLines = 2
    public static let defaultCellHeight = 16.0
    public static let momentumDecay = 0.90
    public static let momentumMinSpeed = 12.0
    public static let pageSwipeRows = 8

    public enum Surface: String, Equatable, Sendable {
        case history
        case alternate
    }

    public enum AlternateAction: Equatable, Sendable {
        /// Xterm mouse wheel: button 4 = up (older), 5 = down (newer).
        case mouseWheel(button: Int, steps: Int)
        /// CSI CUU / CUD. Positive steps are up.
        case arrows(steps: Int)
        case pageUp
        case pageDown
    }

    public struct State: Equatable, Sendable {
        public var following: Bool
        public var linesFromBottom: Int
        public var surface: Surface
        public var historyCount: Int
        public var viewportRows: Int

        public var showJump: Bool { surface == .history && !following }

        public init(
            following: Bool = true,
            linesFromBottom: Int = 0,
            surface: Surface = .history,
            historyCount: Int = 0,
            viewportRows: Int = 24
        ) {
            self.following = following
            self.linesFromBottom = max(0, linesFromBottom)
            self.surface = surface
            self.historyCount = max(0, historyCount)
            self.viewportRows = max(1, viewportRows)
        }

        public var accessibilityValue: String {
            let pin = following ? "following" : "reviewing"
            return "\(pin), \(surface.rawValue), \(historyCount) lines, \(linesFromBottom) from bottom"
        }
    }

    public static func maxDisp(historyCount: Int, viewportRows: Int) -> Int {
        max(0, historyCount - max(1, viewportRows))
    }

    public static func yDisp(linesFromBottom: Int, historyCount: Int, viewportRows: Int) -> Int {
        let ceiling = maxDisp(historyCount: historyCount, viewportRows: viewportRows)
        return max(0, ceiling - max(0, linesFromBottom))
    }

    public static func linesFromBottom(yDisp: Int, historyCount: Int, viewportRows: Int) -> Int {
        let ceiling = maxDisp(historyCount: historyCount, viewportRows: viewportRows)
        return max(0, ceiling - max(0, yDisp))
    }

    /// 0 is the oldest history, 1 is live output.
    public static func position(linesFromBottom: Int, historyCount: Int, viewportRows: Int) -> Double {
        let ceiling = maxDisp(historyCount: historyCount, viewportRows: viewportRows)
        if ceiling == 0 { return 1 }
        return Double(yDisp(linesFromBottom: linesFromBottom, historyCount: historyCount, viewportRows: viewportRows))
            / Double(ceiling)
    }

    public static func isFollowing(linesFromBottom: Int) -> Bool {
        linesFromBottom <= unpinLines
    }

    /// Finger moving down (positive `translationY`) reveals older lines.
    public static func applyDrag(
        _ state: inout State,
        translationY: Double,
        cellHeight: Double
    ) {
        guard state.surface == .history else { return }
        let height = cellHeight > 0 ? cellHeight : defaultCellHeight
        let delta = Int((translationY / height).rounded())
        guard delta != 0 else { return }
        let ceiling = maxDisp(historyCount: state.historyCount, viewportRows: state.viewportRows)
        state.linesFromBottom = min(ceiling, max(0, state.linesFromBottom + delta))
        state.following = isFollowing(linesFromBottom: state.linesFromBottom)
    }

    public static func jumpToLatest(_ state: inout State) {
        state.linesFromBottom = 0
        state.following = true
    }

    /// Keep the user's place when they scrolled up; stay glued to the bottom otherwise.
    public static func outputArrived(_ state: inout State, historyCount: Int, viewportRows: Int) {
        state.historyCount = historyCount
        state.viewportRows = max(1, viewportRows)
        if state.surface == .alternate {
            state.following = true
            state.linesFromBottom = 0
            return
        }
        if state.following {
            state.linesFromBottom = 0
        } else {
            let ceiling = maxDisp(historyCount: state.historyCount, viewportRows: state.viewportRows)
            state.linesFromBottom = min(state.linesFromBottom, ceiling)
            state.following = isFollowing(linesFromBottom: state.linesFromBottom)
        }
    }

    public static func setSurface(_ state: inout State, _ surface: Surface) {
        if state.surface == surface { return }
        state.surface = surface
        if surface == .alternate {
            state.following = true
            state.linesFromBottom = 0
        } else {
            state.following = true
            state.linesFromBottom = 0
        }
    }

    /// Swipe on a TUI: wheel events when the program asked for a mouse, otherwise arrows / page.
    public static func alternateAction(
        translationY: Double,
        cellHeight: Double,
        mouseReporting: Bool,
        viewportRows: Int
    ) -> AlternateAction? {
        let height = cellHeight > 0 ? cellHeight : defaultCellHeight
        let steps = Int((translationY / height).rounded())
        guard steps != 0 else { return nil }
        let page = max(pageSwipeRows, max(1, viewportRows) / 2)
        if abs(steps) >= page {
            return steps > 0 ? .pageUp : .pageDown
        }
        if mouseReporting {
            return .mouseWheel(button: steps > 0 ? 4 : 5, steps: abs(steps))
        }
        return .arrows(steps: steps)
    }

    /// Decaying line deltas for flick momentum. First value is the largest step.
    public static func momentumLineDeltas(velocityY: Double, cellHeight: Double) -> [Int] {
        let height = cellHeight > 0 ? cellHeight : defaultCellHeight
        var speed = velocityY / height
        if abs(speed) < momentumMinSpeed { return [] }
        var deltas: [Int] = []
        while abs(speed) >= momentumMinSpeed && deltas.count < 48 {
            let step = Int(speed.rounded())
            if step != 0 { deltas.append(step) }
            speed *= momentumDecay
        }
        return deltas
    }
}
