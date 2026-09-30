import Foundation
import SwiftUI

@MainActor
final class RanchStore: ObservableObject {
    @Published var devices: [RanchDevice] = []
    @Published var baseURL: URL?
    @Published var endpointLabel = "searching…"
    @Published var statusLine = "Looking for santa…"
    @Published var connected = false
    @Published var errorText: String?
    @Published var capturingID: String?
    @Published var gpioBusy: String?
    @Published var stillTick: Int = 0

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 20
        return URLSession(configuration: config)
    }()

    func bootstrap() async {
        await discover()
        await refresh()
    }

    func discover() async {
        for ep in RanchEndpoint.allCases {
            if let url = URL(string: ep.rawValue + "/health") {
                do {
                    let (data, response) = try await session.data(from: url)
                    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { continue }
                    let health = try JSONDecoder().decode(HealthResponse.self, from: data)
                    if health.ok {
                        baseURL = URL(string: ep.rawValue)
                        endpointLabel = ep.label
                        connected = true
                        errorText = nil
                        statusLine = "\(ep.label) · \(health.devices ?? 0) devices"
                        return
                    }
                } catch {
                    continue
                }
            }
        }
        connected = false
        baseURL = nil
        endpointLabel = "offline"
        statusLine = "Can’t reach santa"
        errorText = "Join home Wi‑Fi or connect OpenVPN (Connexa), then pull to refresh."
    }

    func refresh() async {
        if baseURL == nil {
            await discover()
        }
        guard let base = baseURL else { return }
        do {
            let (data, response) = try await session.data(from: base.appendingPathComponent("devices"))
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            let decoded = try JSONDecoder().decode(DevicesResponse.self, from: data)
            devices = decoded.devices
            connected = true
            errorText = nil
            statusLine = "\(endpointLabel) · \(devices.count) devices · stills + GPIO"
            stillTick += 1
        } catch {
            connected = false
            errorText = error.localizedDescription
            statusLine = "Refresh failed"
            await discover()
        }
    }

    func capture(_ device: RanchDevice) async {
        guard let base = baseURL else { return }
        capturingID = device.socketID
        defer { capturingID = nil }
        var req = URLRequest(url: base.appendingPathComponent("devices/\(device.socketID)/capture"))
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        do {
            let (data, response) = try await session.data(for: req)
            let http = response as? HTTPURLResponse
            if http?.statusCode == 404 {
                errorText = "Device not on Pub-Node right now"
                await refresh()
                return
            }
            let decoded = try JSONDecoder().decode(CaptureResponse.self, from: data)
            if decoded.ok != true {
                errorText = decoded.error ?? "capture refused"
                return
            }
            let previous = device.capturedAt
            for _ in 0..<8 {
                try await Task.sleep(nanoseconds: 700_000_000)
                await refresh()
                if let updated = devices.first(where: { $0.socketID == device.socketID }) {
                    if updated.lastCaptureError != nil { return }
                    if updated.hasStill && updated.capturedAt != previous { return }
                }
            }
        } catch {
            errorText = error.localizedDescription
        }
    }

    func stillURL(for device: RanchDevice) -> URL? {
        guard let base = baseURL, device.hasStill else { return nil }
        let path = device.stillPath ?? "/devices/\(device.socketID)/still"
        var url = URL(string: path, relativeTo: base)?.absoluteURL
        if var comps = url.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }) {
            comps.queryItems = [URLQueryItem(name: "t", value: "\(stillTick)")]
            url = comps.url
        }
        return url
    }

    func setGPIO(_ device: RanchDevice, pin: String, value: Int) async {
        guard let base = baseURL else { return }
        gpioBusy = device.socketID + ":" + pin
        defer { gpioBusy = nil }
        var req = URLRequest(url: base.appendingPathComponent("devices/\(device.socketID)/gpio"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["pin": pin, "value": value])
        req.timeoutInterval = 12
        do {
            let (data, response) = try await session.data(for: req)
            let http = response as? HTTPURLResponse
            if http?.statusCode == 404 {
                errorText = "Device not on Pub-Node right now"
                await refresh()
                return
            }
            if http?.statusCode == 400 {
                let decoded = try? JSONDecoder().decode(CaptureResponse.self, from: data)
                errorText = decoded?.error ?? "GPIO request rejected"
                return
            }
            let decoded = try JSONDecoder().decode(CaptureResponse.self, from: data)
            if decoded.ok != true {
                errorText = decoded.error ?? "GPIO failed"
                return
            }
            errorText = nil
            await refresh()
        } catch {
            errorText = error.localizedDescription
        }
    }
}
