import XCTest
@testable import LojoRemote

final class RemoteLogicTests: XCTestCase {
    func testHelpNamesTheIOSLimits() {
        let text = RemoteHelpCopy.limits
        XCTAssertTrue(text.contains("iPhone Remote Controller"))
        XCTAssertTrue(text.contains("iMessages"))
        XCTAssertTrue(text.contains("Home Screen icons"))
        XCTAssertTrue(text.contains("inject taps"))
        XCTAssertTrue(text.contains("Bedtime white noise"))
        XCTAssertTrue(text.contains("Morning off"))
        XCTAssertTrue(text.contains("force-quit"))
        XCTAssertTrue(RemoteHelpCopy.limitsShort.contains("iMessages"))
    }

    func testSampleAutomationsAreBedtimeOnAndMorningOff() {
        XCTAssertEqual(SampleAutomations.all.map(\.name), ["Bedtime white noise", "Morning off"])
        XCTAssertEqual(SampleAutomations.bedtime.action, .play(soundID: BundledSound.whiteNoise.rawValue))
        XCTAssertEqual(SampleAutomations.morning.action, .stop)
        XCTAssertEqual(SampleAutomations.bedtimeSchedule.startMinutes, 20 * 60)
        XCTAssertEqual(SampleAutomations.bedtimeSchedule.stopMinutes, 6 * 60)
        XCTAssertEqual(SampleAutomations.bedtime.shortcut.accessibilityID, "remote.shortcut.bedtime-white-noise")
        XCTAssertEqual(ShortcutLink.availability(name: "Bedtime white noise", foreground: false, audioPlaying: false), .inApp)
        XCTAssertEqual(ShortcutLink.availability(name: "Goodnight", foreground: true, audioPlaying: false), .shortcutsURL)
        XCTAssertEqual(ShortcutLink.availability(name: "Goodnight", foreground: false, audioPlaying: true), .shortcutsURL)
        XCTAssertEqual(ShortcutLink.availability(name: "Goodnight", foreground: false, audioPlaying: false), .unavailable)
        let url = ShortcutLink.runURL(name: "Goodnight")
        XCTAssertEqual(url?.scheme, "shortcuts")
        XCTAssertEqual(url?.host, "run-shortcut")
        XCTAssertEqual(url?.query, "name=Goodnight")
        XCTAssertNil(ShortcutLink.runURL(name: " "))
        XCTAssertNil(ShortcutLink.runURL(name: "Night&day"))
    }

    func testOvernightWindowWrapsMidnight() {
        XCTAssertTrue(ScheduleEngine.contains(minute: 20 * 60, start: 20 * 60, stop: 6 * 60))
        XCTAssertTrue(ScheduleEngine.contains(minute: 23 * 60 + 15, start: 20 * 60, stop: 6 * 60))
        XCTAssertTrue(ScheduleEngine.contains(minute: 3 * 60, start: 20 * 60, stop: 6 * 60))
        XCTAssertFalse(ScheduleEngine.contains(minute: 6 * 60, start: 20 * 60, stop: 6 * 60))
        XCTAssertFalse(ScheduleEngine.contains(minute: 12 * 60, start: 20 * 60, stop: 6 * 60))
        XCTAssertFalse(ScheduleEngine.contains(minute: 19 * 60 + 59, start: 20 * 60, stop: 6 * 60))
        XCTAssertFalse(ScheduleEngine.contains(minute: 10 * 60, start: 10 * 60, stop: 10 * 60))
    }

    func testDaytimeWindowDoesNotWrap() {
        XCTAssertTrue(ScheduleEngine.contains(minute: 9 * 60, start: 8 * 60, stop: 10 * 60))
        XCTAssertFalse(ScheduleEngine.contains(minute: 7 * 60, start: 8 * 60, stop: 10 * 60))
        XCTAssertFalse(ScheduleEngine.contains(minute: 10 * 60, start: 8 * 60, stop: 10 * 60))
    }

    func testScheduleStartsWhiteNoiseAtEightAndStopsAtSix() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let night = SoundSchedule.overnightWhiteNoise()
        let eight = date(hour: 20, minute: 0, calendar: calendar)
        let three = date(hour: 3, minute: 0, calendar: calendar)
        let seven = date(hour: 7, minute: 0, calendar: calendar)
        let noon = date(hour: 12, minute: 0, calendar: calendar)

        let started = ScheduleEngine.step(schedules: [night], at: eight, calendar: calendar, hold: ScheduleHold())
        guard case .start(let id, let sound, let volume) = started.0 else {
            return XCTFail("expected start, got \(started.0)")
        }
        XCTAssertEqual(id, night.id)
        XCTAssertEqual(sound, BundledSound.whiteNoise.rawValue)
        XCTAssertEqual(volume, 0.6)

        let held = ScheduleEngine.step(schedules: [night], at: three, calendar: calendar, hold: started.1)
        XCTAssertEqual(held.0, .none)
        XCTAssertEqual(held.1.activeScheduleID, night.id)

        let stopped = ScheduleEngine.step(schedules: [night], at: seven, calendar: calendar, hold: held.1)
        XCTAssertEqual(stopped.0, .stop(scheduleID: night.id))
        XCTAssertNil(stopped.1.activeScheduleID)

        let idle = ScheduleEngine.step(schedules: [night], at: noon, calendar: calendar, hold: stopped.1)
        XCTAssertEqual(idle.0, .none)
    }

    func testStopDuringTheWindowStaysStoppedUntilMorning() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let night = SoundSchedule.overnightWhiteNoise()
        let nine = date(hour: 21, minute: 0, calendar: calendar)
        let started = ScheduleEngine.step(schedules: [night], at: nine, calendar: calendar, hold: ScheduleHold())
        var hold = started.1
        hold.activeScheduleID = nil
        hold.suppressedScheduleID = night.id
        let suppressed = ScheduleEngine.step(schedules: [night], at: nine, calendar: calendar, hold: hold)
        XCTAssertEqual(suppressed.0, .none)
        XCTAssertEqual(suppressed.1.suppressedScheduleID, night.id)
        let morning = date(hour: 7, minute: 0, calendar: calendar)
        let cleared = ScheduleEngine.step(schedules: [night], at: morning, calendar: calendar, hold: suppressed.1)
        XCTAssertEqual(cleared.0, .none)
        XCTAssertNil(cleared.1.suppressedScheduleID)
    }

    func testDisabledScheduleDoesNothing() {
        var night = SoundSchedule.overnightWhiteNoise()
        night.enabled = false
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let action = ScheduleEngine.step(
            schedules: [night],
            at: date(hour: 21, minute: 0, calendar: calendar),
            calendar: calendar,
            hold: ScheduleHold()
        )
        XCTAssertEqual(action.0, .none)
    }

    func testClockLabelAndInjectedTime() {
        XCTAssertEqual(ScheduleClock.label(minutes: 20 * 60), "8:00 PM")
        XCTAssertEqual(ScheduleClock.label(minutes: 6 * 60), "6:00 AM")
        XCTAssertEqual(ScheduleClock.label(minutes: 0), "12:00 AM")
        XCTAssertEqual(ScheduleClock.label(minutes: 12 * 60), "12:00 PM")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parsed = ScheduleClock.date(fromHHMM: "20:30", now: date(hour: 1, minute: 0, calendar: calendar), calendar: calendar)
        XCTAssertEqual(ScheduleClock.minutes(from: parsed!, calendar: calendar), 20 * 60 + 30)
        XCTAssertNil(ScheduleClock.date(fromHHMM: "25:00"))
    }

    func testRelayAddressParsing() {
        XCTAssertEqual(RelayEndpoint.url(from: "http://127.0.0.1:8791")?.port, 8791)
        XCTAssertEqual(RelayEndpoint.url(from: "100.96.1.18:8791")?.scheme, "http")
        XCTAssertEqual(RelayEndpoint.url(from: " 100.96.1.18:8791 ")?.host, "100.96.1.18")
        XCTAssertNil(RelayEndpoint.url(from: "not a url"))
        XCTAssertNil(RelayEndpoint.url(from: ""))
        XCTAssertTrue(RelayEndpoint.isLoopback("127.0.0.1"))
        XCTAssertTrue(RelayEndpoint.isLoopback("localhost"))
        XCTAssertFalse(RelayEndpoint.isLoopback("100.96.1.18"))
    }

    func testSoundWavesAreLoopablePCM() {
        for sound in BundledSound.allCases {
            let wav = SoundWave.wav(for: sound, sampleRate: 8_000, seconds: 0.25)
            XCTAssertEqual(String(data: wav.prefix(4), encoding: .ascii), "RIFF")
            XCTAssertEqual(String(data: wav.subdata(in: 8..<12), encoding: .ascii), "WAVE")
            XCTAssertGreaterThan(wav.count, 44)
            var energy = 0
            let samples = wav.dropFirst(44)
            var index = samples.startIndex
            while index + 1 < samples.endIndex {
                let value = Int(Int16(bitPattern: UInt16(samples[index]) | (UInt16(samples[index + 1]) << 8)))
                energy += abs(value)
                index += 2
            }
            XCTAssertGreaterThan(energy, 0, sound.rawValue)
        }
    }

    func testRemotePathPrefersTheOverlayOffSiteWiFi() {
        let lan = "https://192.168.7.103:8443"
        let overlay = "https://100.96.1.18:8443"
        XCTAssertTrue(RemotePathOrder.onSiteWiFi(lanHost: "192.168.7.103", wifiIPv4: "192.168.7.50"))
        XCTAssertFalse(RemotePathOrder.onSiteWiFi(lanHost: "192.168.7.103", wifiIPv4: nil))
        XCTAssertFalse(RemotePathOrder.onSiteWiFi(lanHost: "192.168.7.103", wifiIPv4: "10.0.0.8"))
        XCTAssertFalse(RemotePathOrder.onSiteWiFi(lanHost: "192.168.7.103", wifiIPv4: "100.96.1.89"))
        XCTAssertEqual(
            RemotePathOrder.order(lanURL: lan, overlayURL: overlay, connectedURL: nil, onSiteWiFi: true),
            [lan, overlay]
        )
        XCTAssertEqual(
            RemotePathOrder.order(lanURL: lan, overlayURL: overlay, connectedURL: lan, onSiteWiFi: true),
            [lan, overlay]
        )
        XCTAssertEqual(
            RemotePathOrder.order(lanURL: lan, overlayURL: overlay, connectedURL: nil, onSiteWiFi: false),
            [overlay, lan]
        )
        XCTAssertEqual(
            RemotePathOrder.order(lanURL: lan, overlayURL: overlay, connectedURL: lan, onSiteWiFi: false),
            [overlay, lan]
        )
        XCTAssertEqual(
            RemotePathOrder.order(lanURL: lan, overlayURL: overlay, connectedURL: overlay, onSiteWiFi: false),
            [overlay, lan]
        )
    }

    func testFrameInboxParsesOnePost() {
        let body = Data([0xff, 0xd8, 0xff, 0xd9])
        var raw = Data("POST /frame HTTP/1.1\r\nHost: 127.0.0.1:47221\r\nContent-Length: 4\r\n\r\n".utf8)
        XCTAssertEqual(FrameInboxParser.parse(raw), .needMore)
        raw.append(body)
        XCTAssertEqual(FrameInboxParser.parse(raw), .frame(body))
        let extra = raw + Data("nope".utf8)
        XCTAssertEqual(FrameInboxParser.parse(extra), .frame(body))
        let get = Data("GET /frame HTTP/1.1\r\nContent-Length: 0\r\n\r\n".utf8)
        XCTAssertEqual(FrameInboxParser.parse(get), .reject)
        let huge = Data("POST /frame HTTP/1.1\r\nContent-Length: 99999999\r\n\r\n".utf8)
        XCTAssertEqual(FrameInboxParser.parse(huge), .reject)
    }

    private func date(hour: Int, minute: Int, calendar: Calendar) -> Date {
        var parts = DateComponents()
        parts.calendar = calendar
        parts.timeZone = calendar.timeZone
        parts.year = 2026
        parts.month = 10
        parts.day = 16
        parts.hour = hour
        parts.minute = minute
        return parts.date!
    }
}
