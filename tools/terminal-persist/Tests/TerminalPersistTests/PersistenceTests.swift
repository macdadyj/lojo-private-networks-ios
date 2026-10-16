import XCTest
@testable import TerminalPersist

final class PersistenceTests: XCTestCase {
    func testSessionNameIsTmuxSafe() {
        XCTAssertEqual(TmuxCommand.sessionName(forLabel: "santacomputa"), "lojo-santacomputa")
        XCTAssertEqual(TmuxCommand.sessionName(forLabel: "Santa Computa"), "lojo-santa-computa")
        XCTAssertEqual(TmuxCommand.sessionName(forLabel: "Vision Pi"), "lojo-vision-pi")
        XCTAssertEqual(TmuxCommand.sessionName(forLabel: "labMachine"), "lojo-labmachine")
        XCTAssertEqual(TmuxCommand.sessionName(forLabel: "host.name:1"), "lojo-host-name-1")
        XCTAssertEqual(TmuxCommand.sessionName(forLabel: "   "), "lojo-host")
        XCTAssertEqual(TmuxCommand.sessionName(forLabel: "Vision Pi", generation: 2), "lojo-vision-pi-2")
        let hostile = TmuxCommand.sessionName(forLabel: "santa; rm -rf /")
        XCTAssertEqual(hostile, "lojo-santa-rm-rf")
        XCTAssertTrue(TmuxCommand.isSafeName(hostile))
        XCTAssertFalse(hostile.contains("."))
        XCTAssertFalse(hostile.contains(":"))
        XCTAssertFalse(hostile.contains(";"))
        XCTAssertFalse(hostile.contains(" "))
    }

    func testAttachCommandCreatesOrReattachesWithoutInstalling() {
        let attach = TmuxAttach(session: "lojo-santacomputa", columns: 80, rows: 24, mouse: false)
        let script = attach.shellScript
        XCTAssertTrue(script.contains("tmux -L 'lojo' has-session -t 'lojo-santacomputa'"))
        XCTAssertTrue(script.contains("new-session -A -d -s 'lojo-santacomputa' -x 80 -y 24"))
        XCTAssertTrue(script.contains("exec tmux -L 'lojo' attach-session -t 'lojo-santacomputa'"))
        XCTAssertTrue(script.contains("default-terminal 'xterm-256color'"))
        XCTAssertTrue(script.contains("mouse off"))
        XCTAssertTrue(script.contains("status off"))
        XCTAssertTrue(script.contains("history-limit 50000"))
        XCTAssertTrue(script.contains("escape-time 10"))
        XCTAssertFalse(script.contains("apt-get"))
        XCTAssertFalse(script.contains("sudo"))
        XCTAssertTrue(attach.execCommand.hasPrefix("exec /bin/sh -c '"))
        XCTAssertEqual(TmuxCommand.term, "xterm-256color")
        XCTAssertEqual(attach.execCommand.contains("TERM"), false)
    }

    func testMouseOnIsOptIn() {
        let script = TmuxAttach(session: "lojo-demo-host", columns: 40, rows: 12, mouse: true).shellScript
        XCTAssertTrue(script.contains("mouse on"))
        XCTAssertFalse(script.contains("mouse off"))
    }

    func testDimensionsFallBackAndClamp() {
        let small = TmuxAttach(session: "lojo-demo-host", columns: 0, rows: 1, mouse: false)
        XCTAssertEqual(small.columns, 80)
        XCTAssertEqual(small.rows, 24)
        let huge = TmuxAttach(session: "lojo-demo-host", columns: 9_000, rows: 9_000, mouse: false)
        XCTAssertEqual(huge.columns, 500)
        XCTAssertEqual(huge.rows, 500)
    }

    func testQuoteEscapesSingleQuotes() {
        XCTAssertEqual(TmuxCommand.quote("a'b"), "'a'\\''b'")
    }

    func testKillAndListCommands() {
        XCTAssertEqual(
            TmuxCommand.killCommand(session: "lojo-santacomputa"),
            "tmux -L 'lojo' kill-session -t 'lojo-santacomputa'"
        )
        XCTAssertNil(TmuxCommand.killCommand(session: "lojo-santa;touch /tmp/x"))
        XCTAssertNil(TmuxCommand.killCommand(session: "$(id)"))
        XCTAssertNil(TmuxCommand.killCommand(session: ""))
        XCTAssertNil(TmuxCommand.killCommand(session: "-rf"))
        let list = TmuxCommand.listCommand()
        XCTAssertTrue(list.hasPrefix("tmux -L 'lojo' list-sessions -F '"))
        XCTAssertTrue(list.contains("#{session_name}\\t#{session_attached}"))
        XCTAssertEqual(TmuxCommand.probeCommand, "command -v tmux")
        XCTAssertEqual(TmuxCommand.installCommand, "sudo apt-get install --no-install-recommends tmux")
        XCTAssertFalse(TmuxCommand.listCommand().contains("apt-get"))
        XCTAssertEqual(TmuxCommand.reconnectingTitle, "Reconnecting…")
    }

    func testParseSessionListSkipsUnsafeNames() {
        let text = """
        lojo-demo-host\t0\t1\t100
        lojo-demo-host-2\t2\t3\t200
        bad name\t1\t1\t0
        lojo-x;rm\t0\t1\t0

        not-a-row
        """
        let rows = TmuxCommand.parseSessionList(text)
        XCTAssertEqual(rows.map(\.name), ["lojo-demo-host", "lojo-demo-host-2"])
        XCTAssertEqual(rows[0].detail, "1 window · detached")
        XCTAssertEqual(rows[1].detail, "3 windows · 2 clients attached")
        XCTAssertEqual(rows[0].id, "lojo-demo-host")
    }

    func testProbeAndEmptyList() {
        XCTAssertTrue(TmuxCommand.probeFound(status: 0, output: Data("/usr/bin/tmux\n".utf8)))
        XCTAssertFalse(TmuxCommand.probeFound(status: 1, output: Data("/usr/bin/tmux\n".utf8)))
        XCTAssertFalse(TmuxCommand.probeFound(status: 0, output: Data("\n".utf8)))
        XCTAssertTrue(TmuxCommand.listIsEmpty(status: 1, output: Data()))
        XCTAssertFalse(TmuxCommand.listIsEmpty(status: 0, output: Data()))
        XCTAssertFalse(TmuxCommand.listIsEmpty(status: 1, output: Data("lojo-demo-host\n".utf8)))
    }

    func testHostSettingsDefaultOnWhenMissing() throws {
        let missing = try JSONDecoder().decode(HostSessionSettings.self, from: Data("{}".utf8))
        XCTAssertTrue(missing.keepSessionsAlive)
        XCTAssertFalse(missing.tmuxMouse)
        let set = try JSONDecoder().decode(
            HostSessionSettings.self,
            from: Data("{\"keepSessionsAlive\":false,\"tmuxMouse\":true,\"label\":\"ignored\"}".utf8)
        )
        XCTAssertFalse(set.keepSessionsAlive)
        XCTAssertTrue(set.tmuxMouse)
    }

    func testBackgroundDoesNotCloseTheSocket() {
        for var machine in [
            SessionLinkMachine(),
            liveMachine(),
            backedOffMachine(),
            waitingMachine(),
        ] {
            let effects = machine.handle(.sceneBackground)
            XCTAssertFalse(effects.contains(.closeSocket), "\(machine.state)")
            XCTAssertFalse(effects.contains(.openSocket), "\(machine.state)")
            XCTAssertEqual(effects, [.beginBackgroundTask])
            XCTAssertEqual(machine.handle(.sceneBackground), [])
        }
    }

    func testForegroundProbesALiveSocketAndReattachesImmediately() {
        var live = liveMachine()
        _ = live.handle(.sceneBackground)
        XCTAssertEqual(live.handle(.sceneForeground), [.endBackgroundTask, .probeSocket])
        XCTAssertEqual(live.state, .live)

        var waiting = backedOffMachine()
        _ = waiting.handle(.sceneBackground)
        let resumed = waiting.handle(.sceneForeground)
        XCTAssertEqual(waiting.state, .connecting)
        XCTAssertEqual(resumed, [.endBackgroundTask, .cancelWait, .openSocket])
        XCTAssertEqual(waiting.handle(.waitElapsed), [])
    }

    func testInFlightConnectIsNotRestartedByAPathFlap() {
        var dialing = SessionLinkMachine()
        XCTAssertEqual(dialing.handle(.networkChanged), [])
        XCTAssertEqual(dialing.state, .connecting)
        XCTAssertEqual(dialing.attempt, 0)
    }

    func testReconnectLineKeepsTheRealError() {
        XCTAssertEqual(
            SessionLinkMachine.reconnectLine(attempt: 1, delay: 0, error: nil),
            "Reconnecting (try 1)"
        )
        XCTAssertEqual(
            SessionLinkMachine.reconnectLine(attempt: 1, delay: 0, error: "Can’t connect: timed out"),
            "Reconnecting (try 1). Can’t connect: timed out"
        )
        XCTAssertEqual(
            SessionLinkMachine.reconnectLine(attempt: 2, delay: 2, error: "  "),
            "Reconnecting in 2 s (try 2)"
        )
    }

    func testNetworkChangeProbesOrRetriesWithoutDroppingInput() {
        var live = liveMachine()
        XCTAssertEqual(live.handle(.networkChanged), [.probeSocket])
        XCTAssertEqual(live.state, .live)

        var waiting = backedOffMachine()
        XCTAssertEqual(waiting.handle(.networkChanged), [.cancelWait, .openSocket])
        XCTAssertEqual(waiting.state, .connecting)
    }

    func testBackoffIsExponentialThenStops() {
        var machine = liveMachine()
        var delays: [Int] = []
        var effects = machine.handle(.socketClosed)
        while true {
            guard case .backoff(_, let delay) = machine.state else { break }
            delays.append(delay)
            XCTAssertTrue(effects.contains(.scheduleWait(delay)))
            XCTAssertTrue(effects.contains(.closeSocket))
            XCTAssertFalse(effects.contains(.flushInput))
            XCTAssertEqual(machine.handle(.waitElapsed), [.openSocket])
            XCTAssertEqual(machine.state, .connecting)
            effects = machine.handle(.connectFailed(retryable: true))
        }
        XCTAssertEqual(delays, [1, 2, 4, 8, 16, 30, 30, 30, 30, 30, 30])
        XCTAssertEqual(machine.state, .failed(retryable: true))
        XCTAssertFalse(effects.contains(.openSocket))
        _ = machine.handle(.sceneBackground)
        let again = machine.handle(.sceneForeground)
        XCTAssertEqual(machine.state, .connecting)
        XCTAssertTrue(again.contains(.openSocket))
    }

    func testTwoMissedPingsDropAndOneDoesNot() {
        var machine = liveMachine()
        XCTAssertEqual(machine.handle(.pingMissed), [])
        XCTAssertEqual(machine.state, .live)
        _ = machine.handle(.pingSucceeded)
        XCTAssertEqual(machine.handle(.pingMissed), [])
        let dropped = machine.handle(.pingMissed)
        XCTAssertEqual(machine.state, .backoff(attempt: 1, delaySeconds: 1))
        XCTAssertTrue(dropped.contains(.closeSocket))
    }

    func testCleanExitAndAuthFailureDoNotReconnect() {
        var ended = liveMachine()
        let clean = ended.handle(.cleanExit)
        XCTAssertEqual(ended.state, .ended)
        XCTAssertFalse(clean.contains(.openSocket))
        XCTAssertFalse(clean.contains(.scheduleWait(1)))

        var denied = SessionLinkMachine()
        let failed = denied.handle(.connectFailed(retryable: false))
        XCTAssertEqual(denied.state, .failed(retryable: false))
        XCTAssertFalse(failed.contains { if case .scheduleWait = $0 { return true }; return false })
        XCTAssertFalse(denied.handle(.sceneForeground).contains(.openSocket))
        XCTAssertEqual(denied.handle(.userReconnect), [.cancelWait, .closeSocket, .openSocket])
        XCTAssertEqual(denied.state, .connecting)
    }

    func testPathLossWaitsAndResumeAttaches() {
        var machine = liveMachine()
        XCTAssertEqual(machine.handle(.pathUnavailable), [.cancelWait, .closeSocket])
        XCTAssertEqual(machine.state, .waitingForPath)
        XCTAssertEqual(machine.handle(.pathAvailable), [.openSocket])
        XCTAssertEqual(machine.state, .connecting)
        XCTAssertEqual(machine.handle(.connectSucceeded), [.flushInput])
        XCTAssertEqual(machine.state, .live)
        XCTAssertEqual(machine.attempt, 0)
    }

    func testTypedInputSurvivesTheDropUntilReattach() {
        var buffer = TerminalInputBuffer()
        var machine = liveMachine()
        buffer.append(Array("echo kept".utf8))
        let dropped = machine.handle(.socketClosed)
        XCTAssertFalse(dropped.contains(.flushInput))
        buffer.append(Array("\r".utf8))
        _ = machine.handle(.sceneBackground)
        buffer.append(Array("still".utf8))
        _ = machine.handle(.sceneForeground)
        XCTAssertEqual(machine.state, .connecting)
        XCTAssertFalse(machine.handle(.connectSucceeded).contains(.closeSocket))
        XCTAssertEqual(String(decoding: buffer.drain(), as: UTF8.self), "echo kept\rstill")
        XCTAssertTrue(buffer.isEmpty)
    }

    func testInputBufferDropsOnlyTheOldestPastTheCap() {
        var buffer = TerminalInputBuffer()
        buffer.append(Array(repeating: 1, count: 10))
        buffer.append(Array(repeating: 2, count: TerminalInputBuffer.limit))
        XCTAssertEqual(buffer.count, TerminalInputBuffer.limit)
        XCTAssertEqual(buffer.dropped, 10)
        XCTAssertEqual(buffer.drain().first, 2)
    }

    func testUserCloseIsTheEnd() {
        var machine = liveMachine()
        let effects = machine.handle(.userClose)
        XCTAssertEqual(machine.state, .ended)
        XCTAssertEqual(effects, [.cancelWait, .closeSocket])
        XCTAssertEqual(machine.handle(.socketClosed), [])
        XCTAssertFalse(machine.handle(.sceneForeground).contains(.openSocket))
    }

    func testBackgroundTimeIsOnlyHeldByALiveSession() {
        var ended = liveMachine()
        _ = ended.handle(.cleanExit)
        XCTAssertEqual(ended.handle(.sceneBackground), [])
        XCTAssertEqual(ended.handle(.sceneForeground), [])

        var denied = SessionLinkMachine()
        _ = denied.handle(.connectFailed(retryable: false))
        XCTAssertEqual(denied.handle(.sceneBackground), [])
        XCTAssertFalse(denied.handle(.sceneForeground).contains(.endBackgroundTask))

        var held = liveMachine()
        XCTAssertEqual(held.handle(.sceneBackground), [.beginBackgroundTask])
        let closed = held.handle(.userClose)
        XCTAssertEqual(held.state, .ended)
        XCTAssertEqual(closed, [.cancelWait, .closeSocket, .endBackgroundTask])
        XCTAssertEqual(held.handle(.sceneForeground), [])
    }

    private func liveMachine() -> SessionLinkMachine {
        var machine = SessionLinkMachine()
        XCTAssertEqual(machine.handle(.connectSucceeded), [.flushInput])
        return machine
    }

    private func backedOffMachine() -> SessionLinkMachine {
        var machine = liveMachine()
        _ = machine.handle(.socketClosed)
        return machine
    }

    private func waitingMachine() -> SessionLinkMachine {
        var machine = liveMachine()
        _ = machine.handle(.pathUnavailable)
        return machine
    }
}
