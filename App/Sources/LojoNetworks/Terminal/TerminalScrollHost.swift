import LojoTerminalScroll
import SwiftTerm
import SwiftUI
import UIKit

/// Owns pin-to-bottom, flick momentum, and alternate-screen wheel translation for one `TerminalView`.
@MainActor
final class TerminalScrollController: NSObject, ObservableObject {
    @Published private(set) var state = TerminalScrollback.State()
    /// DEBUG / UI-test hook: last swipe action sent into a TUI.
    @Published private(set) var lastAlternateAction: TerminalScrollback.AlternateAction?

    private weak var terminalView: TerminalView?
    private var pan: UIPanGestureRecognizer?
    private var momentumTask: Task<Void, Never>?
    private var newlineCount = 0
    private var lastTranslation: CGFloat = 0
    private var dragRemainder = 0.0
    private var alternateRemainder = 0.0

    override init() {
        super.init()
    }

    var showJump: Bool { state.showJump }
    var following: Bool { state.following }

    func attach(_ view: TerminalView) {
        if terminalView === view, pan != nil { return }
        detach()
        terminalView = view
        view.isScrollEnabled = false
        view.showsVerticalScrollIndicator = false
        view.showsHorizontalScrollIndicator = false
        view.bounces = false
        view.alwaysBounceVertical = false
        view.getTerminal().changeHistorySize(TerminalScrollback.historyLines)
        let gesture = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        gesture.maximumNumberOfTouches = 1
        gesture.cancelsTouchesInView = true
        gesture.delegate = Proxy.shared
        view.addGestureRecognizer(gesture)
        pan = gesture
        syncMetrics()
    }

    func detach() {
        momentumTask?.cancel()
        momentumTask = nil
        if let view = terminalView, let pan {
            view.removeGestureRecognizer(pan)
        }
        pan = nil
        terminalView = nil
    }

    func noteOutput(_ bytes: ArraySlice<UInt8>) {
        newlineCount += bytes.reduce(0) { $1 == 10 ? $0 + 1 : $0 }
        syncSurface()
        syncMetrics()
        TerminalScrollback.outputArrived(
            &state,
            historyCount: state.historyCount,
            viewportRows: state.viewportRows
        )
        applyToView()
        objectWillChange.send()
    }

    func jumpToLatest() {
        momentumTask?.cancel()
        dragRemainder = 0
        TerminalScrollback.jumpToLatest(&state)
        applyToView()
        objectWillChange.send()
    }

    func previewReady(lines: Int, alternate: Bool) {
        newlineCount = max(newlineCount, lines)
        if alternate {
            TerminalScrollback.setSurface(&state, .alternate)
        } else {
            TerminalScrollback.setSurface(&state, .history)
            TerminalScrollback.jumpToLatest(&state)
        }
        syncMetrics()
        applyToView()
        objectWillChange.send()
    }

    private func syncSurface() {
        guard let term = terminalView?.getTerminal() else { return }
        let surface: TerminalScrollback.Surface = term.isCurrentBufferAlternate ? .alternate : .history
        if state.surface != surface {
            TerminalScrollback.setSurface(&state, surface)
        }
    }

    private func syncMetrics() {
        guard let view = terminalView else { return }
        let term = view.getTerminal()
        let rows = max(1, term.rows)
        state.viewportRows = rows
        state.historyCount = TerminalScrollback.historyCount(newlines: newlineCount, viewportRows: rows)
    }

    private func cellHeight() -> CGFloat {
        guard let view = terminalView else { return TerminalScrollback.defaultCellHeight }
        let rows = max(1, view.getTerminal().rows)
        let height = view.bounds.height / CGFloat(rows)
        return height > 4 ? height : TerminalScrollback.defaultCellHeight
    }

    private func applyToView() {
        guard let view = terminalView else { return }
        if state.surface == .alternate { return }
        if state.following {
            view.scroll(toPosition: 1)
        } else {
            view.scroll(
                toPosition: TerminalScrollback.position(
                    linesFromBottom: state.linesFromBottom,
                    historyCount: state.historyCount,
                    viewportRows: state.viewportRows
                )
            )
        }
    }

    private func applyHistoryDelta(_ translationY: CGFloat) {
        TerminalScrollback.applyDrag(
            &state,
            translationY: Double(translationY),
            cellHeight: Double(cellHeight()),
            remainder: &dragRemainder
        )
        applyToView()
        objectWillChange.send()
    }

    private func applyHistoryLines(_ lines: Int) {
        TerminalScrollback.applyLines(&state, lines)
        applyToView()
        objectWillChange.send()
    }

    private func sendAlternate(_ translationY: CGFloat) {
        guard let view = terminalView else { return }
        let term = view.getTerminal()
        let mouseReporting: Bool
        switch term.mouseMode {
        case .off: mouseReporting = false
        case .x10, .vt200, .buttonEventTracking, .anyEvent: mouseReporting = true
        }
        guard let action = TerminalScrollback.alternateAction(
            translationY: Double(translationY),
            cellHeight: Double(cellHeight()),
            mouseReporting: mouseReporting,
            viewportRows: term.rows,
            remainder: &alternateRemainder
        ) else { return }
        lastAlternateAction = action
        switch action {
        case .mouseWheel(let button, let steps):
            let flags = term.encodeButton(button: button, release: false, shift: false, meta: false, control: false)
            let x = max(0, term.cols / 2)
            let y = max(0, term.rows / 2)
            for _ in 0..<steps {
                term.sendEvent(buttonFlags: flags, x: x, y: y)
            }
        case .arrows(let steps):
            let up = term.applicationCursor ? EscapeSequences.moveUpApp : EscapeSequences.moveUpNormal
            let down = term.applicationCursor ? EscapeSequences.moveDownApp : EscapeSequences.moveDownNormal
            let seq = steps > 0 ? up : down
            for _ in 0..<abs(steps) { view.send(seq) }
        case .pageUp:
            view.pageUp()
        case .pageDown:
            view.pageDown()
        }
        objectWillChange.send()
    }

    @objc
    private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let view = terminalView else { return }
        syncSurface()
        switch gesture.state {
        case .began:
            momentumTask?.cancel()
            lastTranslation = 0
            dragRemainder = 0
            alternateRemainder = 0
        case .changed:
            let y = gesture.translation(in: view).y
            let delta = y - lastTranslation
            lastTranslation = y
            if state.surface == .alternate {
                sendAlternate(delta)
            } else {
                applyHistoryDelta(delta)
            }
        case .ended, .cancelled:
            let velocity = gesture.velocity(in: view).y
            if state.surface == .alternate {
                // One last wheel burst from the flick, then stop. TUIs own their own inertia.
                if abs(velocity) > 400 {
                    sendAlternate(velocity > 0 ? cellHeight() * 3 : -cellHeight() * 3)
                }
                return
            }
            runMomentum(velocityY: velocity)
        default:
            break
        }
    }

    private func runMomentum(velocityY: CGFloat) {
        let deltas = TerminalScrollback.momentumLineDeltas(
            velocityY: Double(velocityY),
            cellHeight: Double(cellHeight())
        )
        guard !deltas.isEmpty else { return }
        momentumTask?.cancel()
        momentumTask = Task { [weak self] in
            for delta in deltas {
                try? await Task.sleep(for: .milliseconds(16))
                guard let self, !Task.isCancelled else { return }
                self.applyHistoryLines(delta)
                if self.state.following { break }
            }
        }
    }
}

/// Lets our vertical pan win over SwiftTerm's mouse/selection pans.
private final class Proxy: NSObject, UIGestureRecognizerDelegate {
    static let shared = Proxy()

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer, let view = pan.view else { return true }
        let velocity = pan.velocity(in: view)
        return abs(velocity.y) > abs(velocity.x) * 1.15
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        otherGestureRecognizer is UIPanGestureRecognizer
    }
}

/// Jump-to-live-output chip. Hidden while pinned or on a TUI alternate screen.
struct JumpToLatestButton: View {
    let linesFromBottom: Int
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.light()
            action()
        } label: {
            Label(TerminalScrollback.jumpTitle(linesFromBottom: linesFromBottom), systemImage: "arrow.down.to.line")
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Capsule().fill(.thinMaterial))
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.18), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("terminal.jump")
        .accessibilityLabel("Jump to latest")
        .accessibilityValue("\(max(0, linesFromBottom)) lines behind")
    }
}
