import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import LojoRemote

final class RelayEndToEndTests: XCTestCase {
    func testTwoRolesRoundTripOnTheRealRelay() async throws {
        let server = Process()
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        server.arguments = ["node", root.appendingPathComponent("relay/server.js").path]
        let port = 18791
        server.environment = ProcessInfo.processInfo.environment.merging([
            "PORT": String(port),
            "BIND": "127.0.0.1",
            "ONLINE_MS": "500",
        ]) { _, new in new }
        try server.run()
        defer { server.terminate() }
        let base = URL(string: "http://127.0.0.1:\(port)")!
        try await waitUntilReady(base)
        let client = RelayClient(baseURL: base, networkCode: "ci-remote")
        let other = RelayClient(baseURL: base, networkCode: "other-room")

        let phone = try await client.register(RegisterBody(
            id: "spare-1",
            name: "Spare iPhone",
            batteryPercent: 81,
            charging: false,
            schedules: [],
            shortcuts: SampleAutomations.shortcuts
        ))
        XCTAssertTrue(phone.online)
        XCTAssertEqual(phone.batteryPercent, 81)
        XCTAssertEqual(phone.shortcuts.map(\.name), ["Bedtime white noise", "Morning off"])
        let hidden = try await other.list()
        XCTAssertTrue(hidden.isEmpty)

        _ = try await client.command(CommandBody(kind: .play, soundID: BundledSound.whiteNoise.rawValue), phoneID: phone.id)
        let delivered = try await client.heartbeat(HeartbeatBody(
            batteryPercent: 81,
            charging: false,
            playback: .idle,
            music: [],
            lastError: nil,
            ack: []
        ), phoneID: phone.id)
        XCTAssertEqual(delivered.commands.map(\.kind), [.play])
        XCTAssertEqual(delivered.commands.first?.soundID, "white-noise")

        let playing = PlaybackSnapshot(
            playing: true,
            soundID: "white-noise",
            title: "White Noise",
            volume: 0.6,
            source: .bundled
        )
        let cleared = try await client.heartbeat(HeartbeatBody(
            batteryPercent: 80,
            charging: true,
            playback: playing,
            music: [MusicTrack(id: "music:1", title: "Night", artist: "Lojo")],
            lastError: nil,
            ack: delivered.commands.map(\.id)
        ), phoneID: phone.id)
        XCTAssertTrue(cleared.commands.isEmpty)

        let listed = try await client.list()
        XCTAssertEqual(listed.first?.playback?.title, "White Noise")
        XCTAssertEqual(listed.first?.batteryLabel, "Battery 80% · charging")
        XCTAssertEqual(listed.first?.music.first?.title, "Night")

        let shortcut = try await client.command(
            CommandBody(kind: .runShortcut, shortcutName: SampleAutomations.bedtime.name),
            phoneID: phone.id
        )
        XCTAssertEqual(shortcut.shortcutName, SampleAutomations.bedtime.name)
        let deliveredShortcut = try await client.heartbeat(HeartbeatBody(
            batteryPercent: 80,
            charging: true,
            playback: playing,
            music: [],
            shortcuts: SampleAutomations.shortcuts,
            lastError: nil,
            ack: []
        ), phoneID: phone.id)
        XCTAssertEqual(deliveredShortcut.commands.map(\.kind), [.runShortcut])

        let saved = try await client.saveSchedules([SampleAutomations.bedtimeSchedule], phoneID: phone.id)
        XCTAssertEqual(saved.schedules.first?.windowLabel, "8:00 PM – 6:00 AM")
        XCTAssertEqual(saved.scheduleRevision, 1)
        let again = try await client.schedules(phoneID: phone.id)
        XCTAssertEqual(again.schedules, saved.schedules)

        let jpeg = Data([0xff, 0xd8, 0xff, 0xd9])
        try await client.postFrame(jpeg, phoneID: phone.id)
        let frame = try await client.latestFrame(phoneID: phone.id)
        XCTAssertEqual(frame, jpeg)

        try await Task.sleep(nanoseconds: 1_200_000_000)
        let stale = try await client.list()
        XCTAssertEqual(stale.first?.online, false)
    }

    func testTwoSparePhonesDoNotShareCommands() async throws {
        let server = Process()
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        server.arguments = ["node", root.appendingPathComponent("relay/server.js").path]
        let port = 18792
        server.environment = ProcessInfo.processInfo.environment.merging([
            "PORT": String(port),
            "BIND": "127.0.0.1",
            "ONLINE_MS": "5000",
        ]) { _, new in new }
        try server.run()
        defer { server.terminate() }
        let base = URL(string: "http://127.0.0.1:\(port)")!
        try await waitUntilReady(base)
        let client = RelayClient(baseURL: base, networkCode: "ci-remote")

        _ = try await client.register(RegisterBody(
            id: "spare-1", name: "Spare iPhone", batteryPercent: 80, charging: false, schedules: []
        ))
        _ = try await client.register(RegisterBody(
            id: "spare-2", name: "Barn phone", batteryPercent: 40, charging: true, schedules: []
        ))
        let listed = try await client.list()
        XCTAssertEqual(listed.map(\.name), ["Barn phone", "Spare iPhone"])
        XCTAssertEqual(listed.map(\.id), ["spare-2", "spare-1"])

        _ = try await client.command(CommandBody(kind: .play, soundID: "rain"), phoneID: "spare-2")
        _ = try await client.command(CommandBody(kind: .stop), phoneID: "spare-1")
        let barn = try await client.heartbeat(HeartbeatBody(
            batteryPercent: 40, charging: true, playback: .idle, music: [], lastError: nil, ack: []
        ), phoneID: "spare-2")
        let spare = try await client.heartbeat(HeartbeatBody(
            batteryPercent: 80, charging: false, playback: .idle, music: [], lastError: nil, ack: []
        ), phoneID: "spare-1")
        XCTAssertEqual(barn.commands.map(\.kind), [.play])
        XCTAssertEqual(barn.commands.first?.soundID, "rain")
        XCTAssertEqual(spare.commands.map(\.kind), [.stop])
        XCTAssertFalse(spare.commands.contains { $0.soundID == "rain" })

        let libraryID = LibraryRequest(scope: "songs", page: 0).soundID
        _ = try await client.command(CommandBody(kind: .play, soundID: libraryID), phoneID: "spare-2")
        let barnLibrary = try await client.heartbeat(HeartbeatBody(
            batteryPercent: 40, charging: true, playback: .idle, music: [], lastError: nil, ack: []
        ), phoneID: "spare-2")
        let spareQuiet = try await client.heartbeat(HeartbeatBody(
            batteryPercent: 80, charging: false, playback: .idle, music: [], lastError: nil, ack: []
        ), phoneID: "spare-1")
        XCTAssertTrue(barnLibrary.commands.contains { $0.soundID == libraryID })
        XCTAssertFalse(spareQuiet.commands.contains { ($0.soundID ?? "").hasPrefix("library:") })
    }

    private func waitUntilReady(_ base: URL) async throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            var request = URLRequest(url: base.appendingPathComponent("health"))
            request.timeoutInterval = 1
            if let (_, response) = try? await URLSession.shared.data(for: request),
               let http = response as? HTTPURLResponse, http.statusCode == 200 {
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("relay did not start")
    }
}
