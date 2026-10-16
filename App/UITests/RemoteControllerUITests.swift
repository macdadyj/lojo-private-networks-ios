import XCTest

/// Demo taps for iPhone Remote Controller. The two-simulator relay test is RemotePairUITests.
final class RemoteControllerUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    func testRemoteControllerDemoEveryTap() {
        app.launchEnvironment = [
            "LOJO_DEMO": "1",
            "LOJO_SCREEN": "home",
            "LOJO_REMOTE_DEMO": "1",
        ]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Remote"].waitForExistence(timeout: 8))
        app.tabBars.buttons["Remote"].tap()
        XCTAssertTrue(app.staticTexts["Spare iPhone"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Online"].exists)
        XCTAssertTrue(app.staticTexts["iPhone Remote Controller"].exists)

        tap("remote.help")
        let limits = app.descendants(matching: .any).matching(identifier: "remote.help.limits").firstMatch
        XCTAssertTrue(limits.waitForExistence(timeout: 6))
        XCTAssertTrue(limits.label.contains("iMessages"))
        XCTAssertTrue(limits.label.contains("inject taps"))
        XCTAssertTrue(limits.label.contains("Bedtime white noise"))
        XCTAssertTrue(limits.label.contains("Morning off"))
        tap("remote.help.done")

        tap("remote.device.row")
        tap("remote.shortcut.bedtime-white-noise")
        waitPlayback("White Noise")
        tap("remote.stop")
        waitPlayback("Stopped")
        tap("remote.sound.white-noise")
        tap("remote.play")
        waitPlayback("White Noise")
        tap("remote.stop")
        waitPlayback("Stopped")
        tap("remote.volume.up")
        tap("remote.volume.down")
        tap("remote.sleep.15")
        tap("remote.sleep.off")
        tap("remote.schedule")
        tap("remote.schedule.add-overnight")
        tap("remote.schedule.save")
        tap("remote.screen")
        XCTAssertTrue(app.staticTexts["Live screen"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "remote.screen.image").firstMatch.exists)
    }

    private func tap(_ id: String) {
        let any = app.descendants(matching: .any).matching(identifier: id)
        XCTAssertTrue(any.firstMatch.waitForExistence(timeout: 6), "missing \(id)")
        let buttons = app.buttons.matching(identifier: id)
        if buttons.count > 0, buttons.firstMatch.isHittable {
            buttons.firstMatch.tap()
        } else {
            any.firstMatch.tap()
        }
    }

    private func waitPlayback(_ needle: String) {
        let playback = app.descendants(matching: .any).matching(identifier: "remote.playback").firstMatch
        XCTAssertTrue(playback.waitForExistence(timeout: 6))
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline {
            if playback.label.contains(needle) { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        }
        XCTFail("playback was '\(playback.label)', expected \(needle)")
    }
}

/// Controller simulator driven against a spare-phone simulator and the real relay.
final class RemotePairUITests: XCTestCase {
    func testControllerSeesDeviceOverTheRelay() throws {
        let armed = ProcessInfo.processInfo.environment["LOJO_REMOTE_PAIR"] == "1"
            || FileManager.default.fileExists(atPath: "/tmp/lojo-remote-pair")
        try XCTSkipUnless(armed, "The remote-pair CI job starts the relay and the spare iPhone.")

        let app = XCUIApplication()
        app.launchEnvironment = [
            "LOJO_DEMO": "0",
            "LOJO_SCREEN": "remote",
            "LOJO_REMOTE_ROLE": "controller",
            "LOJO_RELAY_URL": "http://127.0.0.1:8791",
            "LOJO_NETWORK_CODE": "ci-remote",
        ]
        app.launch()

        XCTAssertTrue(app.staticTexts["Spare iPhone"].waitForExistence(timeout: 25))
        XCTAssertTrue(app.staticTexts["Online"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Battery 81%"].waitForExistence(timeout: 8))

        let row = app.descendants(matching: .any).matching(identifier: "remote.device.row").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 4))
        row.tap()

        let bedtime = app.descendants(matching: .any).matching(identifier: "remote.shortcut.bedtime-white-noise").firstMatch
        XCTAssertTrue(bedtime.waitForExistence(timeout: 15))
        bedtime.tap()
        wait(app, playback: "White Noise", timeout: 20)
        app.buttons["remote.stop"].tap()
        wait(app, playback: "Stopped", timeout: 20)

        app.buttons["remote.play"].tap()
        wait(app, playback: "White Noise", timeout: 20)
        app.buttons["remote.stop"].tap()
        wait(app, playback: "Stopped", timeout: 20)

        app.buttons["remote.schedule"].tap()
        app.buttons["remote.schedule.add-overnight"].tap()
        app.buttons["remote.schedule.save"].tap()
        wait(app, playback: "White Noise", timeout: 20)

        app.buttons["remote.screen"].tap()
        let image = app.descendants(matching: .any).matching(identifier: "remote.screen.image").firstMatch
        XCTAssertTrue(image.waitForExistence(timeout: 20), "live screen frame did not arrive from the relay")
    }

    private func wait(_ app: XCUIApplication, playback needle: String, timeout: TimeInterval) {
        let playback = app.descendants(matching: .any).matching(identifier: "remote.playback").firstMatch
        XCTAssertTrue(playback.waitForExistence(timeout: 8))
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if playback.label.contains(needle) { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTFail("playback was '\(playback.label)', expected \(needle)")
    }
}
