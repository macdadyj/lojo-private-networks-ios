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
        XCTAssertEqual(TerminalScrollback.unpinLines, 0)
        XCTAssertTrue(TerminalScrollback.isFollowing(linesFromBottom: 0))
        XCTAssertFalse(TerminalScrollback.isFollowing(linesFromBottom: 1))
    }

    func testDragDownUnpinsAndRevealsHistory() {
        var state = TerminalScrollback.State(historyCount: 400, viewportRows: 24)
        drag(&state, 16 * 10)
        XCTAssertEqual(state.linesFromBottom, 10)
        XCTAssertFalse(state.following)
        XCTAssertTrue(state.showJump)
    }

    func testDragUpWhileReviewingReturnsToFollowing() {
        var state = TerminalScrollback.State(
            following: false, linesFromBottom: 8, historyCount: 400, viewportRows: 24
        )
        drag(&state, -16 * 8)
        XCTAssertEqual(state.linesFromBottom, 0)
        XCTAssertTrue(state.following)
        XCTAssertFalse(state.showJump)
    }

    func testDragDoesNotPassTheTop() {
        var state = TerminalScrollback.State(historyCount: 40, viewportRows: 24)
        drag(&state, 16 * 500)
        XCTAssertEqual(state.linesFromBottom, 16)
        XCTAssertFalse(state.following)
    }

    func testSubCellDragIsRememberedUntilItMakesALine() {
        var state = TerminalScrollback.State(historyCount: 400, viewportRows: 24)
        var remainder = 0.0
        TerminalScrollback.applyDrag(&state, translationY: 4, cellHeight: 16, remainder: &remainder)
        XCTAssertTrue(state.following)
        XCTAssertEqual(state.linesFromBottom, 0)
        XCTAssertEqual(remainder, 0.25, accuracy: 0.0001)
        TerminalScrollback.applyDrag(&state, translationY: 4, cellHeight: 16, remainder: &remainder)
        TerminalScrollback.applyDrag(&state, translationY: 4, cellHeight: 16, remainder: &remainder)
        TerminalScrollback.applyDrag(&state, translationY: 4, cellHeight: 16, remainder: &remainder)
        XCTAssertEqual(state.linesFromBottom, 1)
        XCTAssertFalse(state.following)
        XCTAssertEqual(remainder, 0, accuracy: 0.0001)
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
        drag(&state, 80)
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
        XCTAssertEqual(alternate(16 * 3, mouse: true), .mouseWheel(button: 4, steps: 3))
        XCTAssertEqual(alternate(-16 * 2, mouse: true), .mouseWheel(button: 5, steps: 2))
    }

    func testAlternateSwipeSendsArrowsWithoutMouse() {
        XCTAssertEqual(alternate(16 * 3, mouse: false), .arrows(steps: 3))
    }

    func testLargeAlternateSwipePages() {
        XCTAssertEqual(alternate(16 * 20, mouse: true), .pageUp)
        XCTAssertEqual(alternate(-16 * 20, mouse: false), .pageDown)
    }

    func testAlternateSubCellSwipesAccumulate() {
        var remainder = 0.0
        XCTAssertNil(alternate(8, mouse: true, remainder: &remainder))
        XCTAssertEqual(remainder, 0.5, accuracy: 0.0001)
        XCTAssertEqual(
            alternate(8, mouse: true, remainder: &remainder),
            .mouseWheel(button: 4, steps: 1)
        )
        XCTAssertEqual(remainder, 0, accuracy: 0.0001)
    }

    func testZeroSwipeDoesNotInventAWheelEvent() {
        var remainder = 0.0
        XCTAssertNil(alternate(0, mouse: true, remainder: &remainder))
        XCTAssertEqual(remainder, 0, accuracy: 0.0001)
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
        XCTAssertEqual(AppBuildInfo.summary(short: " 1.3\n", build: " 12 "), "1.3 (12)")
    }

    func testHistoryCountCapsAtTheBuffer() {
        XCTAssertEqual(TerminalScrollback.historyCount(newlines: 0, viewportRows: 24), 24)
        XCTAssertEqual(TerminalScrollback.historyCount(newlines: 100, viewportRows: 24), 124)
        XCTAssertEqual(
            TerminalScrollback.historyCount(newlines: 50_000, viewportRows: 24),
            TerminalScrollback.historyLines + 24
        )
        XCTAssertEqual(TerminalScrollback.historyCount(newlines: -4, viewportRows: 0), 1)
    }

    func testTenThousandLineFloodKeepsTheFirstAndLastLine() {
        let count = 10_000
        let text = TerminalFlood.lines(count)
        XCTAssertTrue(text.hasSuffix("\r\n"))
        let rows = text.split(separator: "\r\n", omittingEmptySubsequences: true)
        XCTAssertEqual(rows.count, count)
        XCTAssertEqual(String(rows[0]), "line 00001 grok-build-output")
        XCTAssertEqual(String(rows[count - 1]), "line 10000 grok-build-output")
        XCTAssertEqual(Set(rows).count, count)
    }

    func testOutputRepairsAStaleFollowingFlag() {
        var state = TerminalScrollback.State(
            following: false, linesFromBottom: 0, historyCount: 80, viewportRows: 24
        )
        TerminalScrollback.outputArrived(&state, historyCount: 90, viewportRows: 24)
        XCTAssertTrue(state.following)
        XCTAssertEqual(state.linesFromBottom, 0)
    }

    func testSameSurfaceDoesNotThrowAwayAReview() {
        var state = TerminalScrollback.State(
            following: false, linesFromBottom: 9, historyCount: 200, viewportRows: 24
        )
        TerminalScrollback.setSurface(&state, .history)
        XCTAssertEqual(state.linesFromBottom, 9)
        XCTAssertFalse(state.following)
    }

    func testApplyLinesIsANoOpOnTheAlternateScreen() {
        var state = TerminalScrollback.State(surface: .alternate, historyCount: 200, viewportRows: 24)
        TerminalScrollback.applyLines(&state, 6)
        XCTAssertEqual(state.linesFromBottom, 0)
        XCTAssertEqual(state.surface, .alternate)
    }

    func testNegativeMomentumPointsUpTheBuffer() {
        let deltas = TerminalScrollback.momentumLineDeltas(velocityY: -800, cellHeight: 16)
        XCTAssertFalse(deltas.isEmpty)
        XCTAssertLessThan(deltas[0], 0)
    }

    func testJumpTitleCountsLines() {
        XCTAssertEqual(TerminalScrollback.jumpTitle(linesFromBottom: 0), "Jump to latest")
        XCTAssertEqual(TerminalScrollback.jumpTitle(linesFromBottom: 1), "Jump to latest · 1 line")
        XCTAssertEqual(TerminalScrollback.jumpTitle(linesFromBottom: 42), "Jump to latest · 42 lines")
        XCTAssertEqual(TerminalScrollback.jumpTitle(linesFromBottom: -3), "Jump to latest")
    }

    func testShortBufferHasNoScrollRoom() {
        XCTAssertEqual(TerminalScrollback.maxDisp(historyCount: 10, viewportRows: 24), 0)
        XCTAssertEqual(TerminalScrollback.position(linesFromBottom: 0, historyCount: 10, viewportRows: 24), 1, accuracy: 0.0001)
        var state = TerminalScrollback.State(historyCount: 10, viewportRows: 24)
        drag(&state, 200)
        XCTAssertTrue(state.following)
        XCTAssertFalse(state.showJump)
    }

    func testBadCellHeightUsesTheDefault() {
        var remainder = 0.0
        let lines = TerminalScrollback.consumeLines(translationY: 32, cellHeight: 0, remainder: &remainder)
        XCTAssertEqual(lines, Int((32 / TerminalScrollback.defaultCellHeight).rounded(.towardZero)))
    }

    private func drag(_ state: inout TerminalScrollback.State, _ translationY: Double) {
        var remainder = 0.0
        TerminalScrollback.applyDrag(&state, translationY: translationY, cellHeight: 16, remainder: &remainder)
    }

    private func alternate(
        _ translationY: Double,
        mouse: Bool,
        remainder: inout Double
    ) -> TerminalScrollback.AlternateAction? {
        TerminalScrollback.alternateAction(
            translationY: translationY,
            cellHeight: 16,
            mouseReporting: mouse,
            viewportRows: 24,
            remainder: &remainder
        )
    }

    private func alternate(_ translationY: Double, mouse: Bool) -> TerminalScrollback.AlternateAction? {
        var remainder = 0.0
        return alternate(translationY, mouse: mouse, remainder: &remainder)
    }
}
