import XCTest

/// Simulator taps. TestFlight waits for this class. Jon does not have to be the tester.
final class LojoNetworksUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    func testSettingsShowsBuildNumberAndEveryTap() {
        launch([
            "LOJO_DEMO": "1",
            "LOJO_SCREEN": "settings",
        ])
        XCTAssertTrue(
            app.staticTexts["Build"].waitForExistence(timeout: 8)
                || element("settings.build").waitForExistence(timeout: 2)
        )
        XCTAssertTrue(app.staticTexts["Version"].exists)

        tap("settings.demo")
        tap("settings.demo")
        tap("settings.theme")
        if app.buttons["Light"].waitForExistence(timeout: 2) {
            app.buttons["Light"].tap()
        } else if app.staticTexts["Light"].exists {
            app.staticTexts["Light"].tap()
        }
        tapIfEnabled("settings.test.lan")
        tapIfEnabled("settings.test.overlay")
        tap("settings.reset")
        tap("settings.welcome")
    }

    func testHomeTabsAndSettingsGear() {
        launch([
            "LOJO_DEMO": "1",
            "LOJO_SCREEN": "home",
        ])
        XCTAssertTrue(app.tabBars.buttons["Network"].waitForExistence(timeout: 8))
        app.tabBars.buttons["Activity"].tap()
        app.tabBars.buttons["Map"].tap()
        app.tabBars.buttons["Connection"].tap()
        app.tabBars.buttons["Terminal"].tap()
        app.tabBars.buttons["Network"].tap()
        tap("home.settings")
        XCTAssertTrue(element("settings.build").waitForExistence(timeout: 6))
        tap("settings.done")
    }

    func testTerminalHomeEveryTap() {
        launch([
            "LOJO_DEMO": "1",
            "LOJO_SCREEN": "terminal",
            "LOJO_SSH_PREVIEW": "1",
        ])
        XCTAssertTrue(element("terminal.home.settings").waitForExistence(timeout: 8))
        tap("terminal.home.keys")
        if app.navigationBars.buttons.element(boundBy: 0).waitForExistence(timeout: 4) {
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
        tap("terminal.home.settings")
        XCTAssertTrue(element("terminal.settings.font").waitForExistence(timeout: 6))
        tap("terminal.settings.font")
        tap("terminal.settings.theme.solarizedDark")
        tap("terminal.settings.theme.lojoDark")
        tap("terminal.settings.redact")
        tap("terminal.settings.redact")
        tap("terminal.settings.done")
        tap("terminal.home.add")
        XCTAssertTrue(element("host.editor.cancel").waitForExistence(timeout: 6))
        tap("host.editor.cancel")
    }

    func testScrollbackFloodUnpinsAndJumpReturnsToLatest() {
        launch([
            "LOJO_DEMO": "1",
            "LOJO_SCREEN": "terminal",
            "LOJO_SSH_SCREEN": "scrollback",
            "LOJO_SSH_PREVIEW": "1",
            "LOJO_SSH_FLOOD": "2000",
        ])
        let state = element("terminal.scroll.state")
        XCTAssertTrue(state.waitForExistence(timeout: 12), "scrollback preview did not appear")
        wait(state, contains: "following", timeout: 8)

        let surface = element("terminal.surface")
        XCTAssertTrue(surface.waitForExistence(timeout: 4))
        // Finger down reveals older lines and unpins from live output.
        surface.swipeDown(velocity: .fast)
        surface.swipeDown(velocity: .fast)
        wait(state, contains: "reviewing", timeout: 6)
        XCTAssertTrue(element("terminal.jump").waitForExistence(timeout: 4))

        let jump = element("terminal.jump")
        XCTAssertTrue(jump.waitForExistence(timeout: 4))
        let behind = (jump.value as? String) ?? ""
        XCTAssertTrue(behind.contains("lines behind"), "jump value was '\(behind)'")

        tap("terminal.jump")
        wait(state, contains: "following", timeout: 6)
        XCTAssertFalse(element("terminal.jump").exists)
    }

    func testDraggingBackToTheBottomPinsAgain() {
        launch([
            "LOJO_DEMO": "1",
            "LOJO_SCREEN": "terminal",
            "LOJO_SSH_SCREEN": "scrollback",
            "LOJO_SSH_PREVIEW": "1",
            "LOJO_SSH_FLOOD": "400",
        ])
        let state = element("terminal.scroll.state")
        XCTAssertTrue(state.waitForExistence(timeout: 12))
        let surface = element("terminal.surface")
        XCTAssertTrue(surface.waitForExistence(timeout: 4))
        surface.swipeDown(velocity: .fast)
        wait(state, contains: "reviewing", timeout: 6)
        surface.swipeUp(velocity: .fast)
        surface.swipeUp(velocity: .fast)
        surface.swipeUp(velocity: .fast)
        wait(state, contains: "following", timeout: 6)
        XCTAssertFalse(element("terminal.jump").exists)
    }

    func testSessionChromeEveryTapDuringFlood() {
        launch([
            "LOJO_DEMO": "1",
            "LOJO_SCREEN": "terminal",
            "LOJO_SSH_SCREEN": "scrollback",
            "LOJO_SSH_PREVIEW": "1",
            "LOJO_SSH_FLOOD": "800",
        ])
        XCTAssertTrue(element("terminal.scroll.state").waitForExistence(timeout: 12))
        tap("terminal.sessions")
        if element("tmux.sessions.done").waitForExistence(timeout: 4) {
            tap("tmux.sessions.done")
        } else {
            app.swipeDown(velocity: .fast)
        }
        tap("terminal.paste")
        tap("terminal.copy")
        tap("terminal.smaller")
        tap("terminal.larger")
        tap("terminal.keyboard")
        tap("terminal.keyboard")
        tap("terminal.new")
        XCTAssertTrue(element("terminal.home.add").waitForExistence(timeout: 6) || app.navigationBars["Terminal"].waitForExistence(timeout: 6))
    }

    func testAlternateScreenHasNoJumpChip() {
        launch([
            "LOJO_DEMO": "1",
            "LOJO_SCREEN": "terminal",
            "LOJO_SSH_SCREEN": "alternate",
            "LOJO_SSH_PREVIEW": "1",
            "LOJO_SSH_FLOOD": "40",
        ])
        let state = element("terminal.scroll.state")
        XCTAssertTrue(state.waitForExistence(timeout: 12))
        wait(state, contains: "alternate", timeout: 6)
        let surface = element("terminal.surface")
        XCTAssertTrue(surface.waitForExistence(timeout: 4))
        surface.swipeDown(velocity: .fast)
        surface.swipeUp(velocity: .fast)
        XCTAssertFalse(element("terminal.jump").exists)
        tap("terminal.back")
    }

    // MARK: - helpers

    private func launch(_ environment: [String: String]) {
        app.launchEnvironment = environment
        app.launch()
    }

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id]
    }

    private func tap(_ id: String) {
        let el = element(id)
        XCTAssertTrue(el.waitForExistence(timeout: 6), "missing \(id)")
        el.tap()
    }

    private func tapIfEnabled(_ id: String) {
        let el = element(id)
        guard el.waitForExistence(timeout: 3), el.isEnabled else { return }
        el.tap()
    }

    private func wait(_ el: XCUIElement, contains needle: String, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let value = (el.value as? String) ?? el.label
            if value.contains(needle) { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        }
        let value = (el.value as? String) ?? el.label
        XCTFail("\(el.identifier) was '\(value)', expected to contain '\(needle)'")
    }
}
