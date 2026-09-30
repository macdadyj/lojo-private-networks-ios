import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: RanchStore

    var body: some View {
        NavigationStack {
            List {
                Section {
                    StatusBanner()
                }
                Section("Cameras") {
                    if store.devices.isEmpty && store.connected {
                        Text("No devices on Pub-Node right now.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(store.devices) { device in
                        DeviceCard(device: device)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Ranch Field")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await store.refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Refresh")
                }
            }
            .refreshable {
                await store.refresh()
            }
            .task {
                await store.bootstrap()
            }
        }
        .preferredColorScheme(.dark)
    }
}

private struct StatusBanner: View {
    @EnvironmentObject private var store: RanchStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(store.connected ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(store.statusLine)
                    .font(.subheadline)
            }
            Text("Stills and GPIO on the Cloud Run Pub-Node path. Flex GPIO is not used.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let err = store.errorText {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct DeviceCard: View {
    @EnvironmentObject private var store: RanchStore
    let device: RanchDevice

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.displayName)
                        .font(.headline)
                    Text(device.site.isEmpty ? "site unknown" : device.site)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if device.webcamEnabled {
                    Button {
                        Task { await store.capture(device) }
                    } label: {
                        if store.capturingID == device.socketID {
                            ProgressView()
                        } else {
                            Label("Capture", systemImage: "camera.fill")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.capturingID != nil)
                } else {
                    Text("No camera")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let still = store.stillURL(for: device) {
                AsyncImage(url: still) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    case .failure:
                        Text("Still failed to load")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    default:
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding()
                    }
                }
            }

            if let captured = device.capturedAt {
                Text(captured)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let err = device.lastCaptureError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if !device.sortedPins.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("GPIO")
                        .font(.subheadline.weight(.semibold))
                    ForEach(device.sortedPins, id: \.self) { pin in
                        let on = (device.gpioPins[pin] ?? 0) == 1
                        HStack {
                            Text("Pin \(pin)")
                            Spacer()
                            Text(on ? "ON" : "OFF")
                                .font(.caption.monospaced())
                                .foregroundStyle(on ? .green : .secondary)
                            if store.gpioBusy == device.socketID + ":" + pin {
                                ProgressView()
                            } else {
                                Button("ON") {
                                    Task { await store.setGPIO(device, pin: pin, value: 1) }
                                }
                                .buttonStyle(.bordered)
                                .disabled(store.gpioBusy != nil || on)
                                Button("OFF") {
                                    Task { await store.setGPIO(device, pin: pin, value: 0) }
                                }
                                .buttonStyle(.bordered)
                                .disabled(store.gpioBusy != nil || !on)
                            }
                        }
                    }
                }
            }
        }
        .padding(.vertical, 6)
    }
}
