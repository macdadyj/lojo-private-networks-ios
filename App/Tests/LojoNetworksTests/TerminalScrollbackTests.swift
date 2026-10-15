import XCTest
@testable import LojoTerminalScroll

final class TerminalScrollbackTests: XCTestCase {
    func testHistoryBufferIsAtLeastTenThousandLines() {
        XCTAssertGreaterThanOrEqual(TerminalScrollback.historyLines, 10_000)
        XCTAssertEqual(TerminalScrollback.historyLines, 10_240)
    }

    func testFloodProducesUniqueNumberedLines() {
        let text = TerminalFlood.lines(12)
        XCTAssertTrue(text.contains("line 00001 grok-build-output"))
        XCTAssertTrue(text.contains("line 00012 grok-build-output"))
        XCTAssertEqual(text.split(separator: "\r\n").count, 12)
    }

    func testEmptyFloodIsEmpty() {
        XCTAssertEqual(TerminalFlood.lines(0), "")
        XCTAssertEqual(TerminalFlood.lines(-3), "")
    }

    func testPositionAtBottomIsOne() {
        XCTAssertEqual(TerminalScrollback.position(linesFromBottom: 0, historyCount: 200, viewportRows: 24), 1, accuracy: 0.0001)
        XCTAssertEqual(TerminalScrollback.yDisp(linesFromBottom: 0, historyCount: 200, viewportRows: 24), 176)
    }

    func testPositionAtTopIsZero() {
        XCTAssertEqual(TerminalScrollback.position(linesFromBottom: 176, historyCount: 200, viewportRows: 24), 0, accuracy: 0.0001)
        XCTAssertEqual(TerminalScrollback.yDisp(linesFromBottom: 176, historyCount: 200, viewportRows: 24), 0)
    }

    func testYDispRoundTrip() {
        for fromBottom in [0, 1, 10, 50, 176] {
            let y = TerminalScrollback.yDisp(linesFromBottom: fromBottom, historyCount: 200, viewportRows: 24)
            XCTAssertEqual(
                TerminalScrollback.linesFromBottom(yDisp: y, historyCount: 200, viewportRows: 24),
                fromBottom
            )
        }
    }

    func testStayFollowingUntilUserPullsAway() {
        XCTAssertTrue(TerminalScrollback.isFollowing(linesFromBottom: 0))
        XCTAssertTrue(TerminalScrollback.isFollowing(linesFromBottom: 2))
        XCTAssertFalse(TerminalScrollback.isFollowing(linesFromBottom: 3))
    }

    func testDragDownUnpinsAndRevealsHistory() {
        var state = TerminalScrollback.State(historyCount: 400, viewportRows: 24)
        TerminalScrollback.applyDrag(&state, translationY: 16 * 10, cellHeight: 16)
        XCTAssertEqual(state.linesFromBottom, 10)
        XCTAssertFalse(state.following)
        XCTAssertTrue(state.showJump)
    }

    func testDragUpWhileReviewingReturnsToFollowing() {
        var state = TerminalScrollback.State(
            following: false, linesFromBottom: 8, historyCount: 400, viewportRows: 24
        )
        TerminalScrollback.applyDrag(&state, translationY: -16 * 8, cellHeight: 16)
        XCTAssertEqual(state.linesFromBottom, 0)
        XCTAssertTrue(state.following)
        XCTAssertFalse(state.showJump)
    }

    func testDragDoesNotPassTheTop() {
        var state = TerminalScrollback.State(historyCount: 40, viewportRows: 24)
        TerminalScrollback.applyDrag(&state, translationY: 16 * 500, cellHeight: 16)
        XCTAssertEqual(state.linesFromBottom, 16)
        XCTAssertFalse(state.following)
    }

    func testTinyDragDoesNothing() {
        var state = TerminalScrollback.State(historyCount: 400, viewportRows: 24)
        TerminalScrollback.applyDrag(&state, translationY: 4, cellHeight: 16)
        XCTAssertTrue(state.following)
        XCTAssertEqual(state.linesFromBottom, 0)
    }

    func testOutputWhileFollowingStaysPinned() {
        var state = TerminalScrollback.State(historyCount: 80, viewportRows: 24)
        TerminalScrollback.outputArrived(&state, historyCount: 400, viewportRows: 24)
        XCTAssertTrue(state.following)
        XCTAssertEqual(state.linesFromBottom, 0)
        XCTAssertEqual(state.historyCount, 400)
    }

    func testOutputWhileReviewingKeepsPlace() {
        var state = TerminalScrollback.State(
            following: false, linesFromBottom: 30, historyCount: 200, viewportRows: 24
        )
        TerminalScrollback.outputArrived(&state, historyCount: 260, viewportRows: 24)
        XCTAssertFalse(state.following)
        XCTAssertEqual(state.linesFromBottom, 30)
        XCTAssertTrue(state.showJump)
    }

    func testJumpToLatestClearsReview() {
        var state = TerminalScrollback.State(
            following: false, linesFromBottom: 40, historyCount: 300, viewportRows: 24
        )
        TerminalScrollback.jumpToLatest(&state)
        XCTAssertTrue(state.following)
        XCTAssertEqual(state.linesFromBottom, 0)
        XCTAssertFalse(state.showJump)
    }

    func testAlternateScreenHidesJumpAndIgnoresHistoryDrag() {
        var state = TerminalScrollback.State(
            following: false, linesFromBottom: 20, historyCount: 300, viewportRows: 24
        )
        TerminalScrollback.setSurface(&state, .alternate)
        XCTAssertEqual(state.surface, .alternate)
        XCTAssertTrue(state.following)
        XCTAssertFalse(state.showJump)
        TerminalScrollback.applyDrag(&state, translationY: 80, cellHeight: 16)
        XCTAssertEqual(state.linesFromBottom, 0)
        XCTAssertEqual(state.surface, .alternate)
    }

    func testLeavingAlternateScreenFollowsAgain() {
        var state = TerminalScrollback.State(surface: .alternate, historyCount: 300, viewportRows: 24)
        TerminalScrollback.setSurface(&state, .history)
        XCTAssertEqual(state.surface, .history)
        XCTAssertTrue(state.following)
        XCTAssertFalse(state.showJump)
    }

    func testAlternateSwipeSendsMouseWheelWhenReporting() {
        let up = TerminalScrollback.alternateAction(
            translationY: 16 * 3, cellHeight: 16, mouseReporting: true, viewportRows: 24
        )
        XCTAssertEqual(up, .mouseWheel(button: 4, steps: 3))
        let down = TerminalScrollback.alternateAction(
            translationY: -16 * 2, cellHeight: 16, mouseReporting: true, viewportRows: 24
        )
        XCTAssertEqual(down, .mouseWheel(button: 5, steps: 2))
    }

    func testAlternateSwipeSendsArrowsWithoutMouse() {
        let up = TerminalScrollback.alternateAction(
            translationY: 16 * 3, cellHeight: 16, mouseReporting: false, viewportRows: 24
        )
        XCTAssertEqual(up, .arrows(steps: 3))
    }

    func testLargeAlternateSwipePages() {
        XCTAssertEqual(
            TerminalScrollback.alternateAction(
                translationY: 16 * 20, cellHeight: 16, mouseReporting: true, viewportRows: 24
            ),
            .pageUp
        )
        XCTAssertEqual(
            TerminalScrollback.alternateAction(
                translationY: -16 * 20, cellHeight: 16, mouseReporting: false, viewportRows: 24
            ),
            .pageDown
        )
    }

    func testMomentumDecaysAndStops() {
        let deltas = TerminalScrollback.momentumLineDeltas(velocityY: 800, cellHeight: 16)
        XCTAssertFalse(deltas.isEmpty)
        XCTAssertGreaterThan(deltas[0], 0)
        for index in 1..<deltas.count {
            XCTAssertLessThanOrEqual(abs(deltas[index]), abs(deltas[index - 1]))
        }
        XCTAssertTrue(TerminalScrollback.momentumLineDeltas(velocityY: 10, cellHeight: 16).isEmpty)
    }

    func testAccessibilityNamesFollowingAndReviewing() {
        var state = TerminalScrollback.State(historyCount: 80, viewportRows: 24)
        XCTAssertTrue(state.accessibilityValue.contains("following"))
        state.following = false
        state.linesFromBottom = 12
        XCTAssertTrue(state.accessibilityValue.contains("reviewing"))
        XCTAssertTrue(state.accessibilityValue.contains("12 from bottom"))
    }

    func testBuildInfoFallsBackAndFormats() {
        XCTAssertEqual(AppBuildInfo.version(short: "1.2", build: "47").build, "47")
        XCTAssertEqual(AppBuildInfo.version(short: nil, build: nil).version, "1.0")
        XCTAssertEqual(AppBuildInfo.version(short: "  ", build: "").build, "1")
        XCTAssertEqual(AppBuildInfo.summary(short: "1.2", build: "47"), "1.2 (47)")
    }
}
