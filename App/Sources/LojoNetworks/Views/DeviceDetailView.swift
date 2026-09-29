import SwiftUI

struct PendingOutput: Identifiable {
    let device: Device
    let pin: Device.Pin
    let turnOn: Bool

    var id: String { device.key + ":" + pin.pin }
}

struct DeviceDetailView: View {
    let deviceKey: String
    @EnvironmentObject private var store: NetworkStore
    @EnvironmentObject private var router: Router
    @State private var pending: PendingOutput?
    @State private var showFullStill = false

    var body: some View {
        Group {
            if let device = store.device(key: deviceKey) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        header(device)
                        if let blocker = store.actionBlocker(for: device) {
                            BlockerNote(text: blocker)
                        }
                        if device.camera.enabled {
                            cameraCard(device)
                        }
                        if !device.gpio.isEmpty {
                            controlsCard(device)
                        }
                        factsCard(device)
                        activityCard(device)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 32)
                }
                .background(Color(uiColor: .systemGroupedBackground))
                .navigationTitle(device.displayName)
                .navigationBarTitleDisplayMode(.inline)
                .refreshable { await store.refresh(.user) }
                .sheet(item: $pending) { p in
                    OutputConfirmSheet(pending: p) {
                        pending = nil
                        Task { await store.setOutput(p.device, pin: p.pin, on: p.turnOn) }
                    } onCancel: {
                        pending = nil
                    }
                    .presentationDetents([.height(430)])
                    .presentationDragIndicator(.visible)
                }
                .fullScreenCover(isPresented: $showFullStill) {
                    FullStillView(device: device)
                }
                .onAppear { openPendingConfirmation(device) }
            } else {
                ContentUnavailableView(
                    "Device not found",
                    systemImage: "questionmark.square.dashed",
                    description: Text("It may have been removed from your network.")
                )
            }
        }
    }

    private func openPendingConfirmation(_ device: Device) {
        guard let pinID = router.pendingConfirmPin else { return }
        router.pendingConfirmPin = nil
        guard let pin = device.gpio.first(where: { $0.pin == pinID }) ?? device.gpio.first else { return }
        pending = PendingOutput(device: device, pin: pin, turnOn: !pin.isOn)
    }

    // MARK: - header

    private func header(_ device: Device) -> some View {
        HStack(spacing: 14) {
            DeviceIcon(kind: device.kind, online: device.online, size: 56)
            VStack(alignment: .leading, spacing: 6) {
                Text(device.displayName)
                    .font(.title2.weight(.bold))
                Text("\(device.kind.title) · \(device.siteName)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    StatusDot(style: device.online ? .online : .offline, size: 8)
                    Text(statusText(device))
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(device.online ? LojoTheme.online : .secondary)
                }
            }
            Spacer()
        }
        .padding(.top, 8)
        .accessibilityElement(children: .combine)
    }

    private func statusText(_ device: Device) -> String {
        if device.online {
            return "Online · since \(RelativeTime.text(device.statusSince))"
        }
        return "Offline · since \(RelativeTime.text(device.statusSince))"
    }

    // MARK: - camera

    private func cameraCard(_ device: Device) -> some View {
        let stage = store.captureStage[device.key]
        let blocked = store.actionBlocker(for: device) != nil
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Camera", systemImage: "camera.fill")
                    .font(.headline)
                Spacer()
                if let at = device.capturedDate {
                    Text(RelativeTime.text(at))
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Captured \(RelativeTime.text(at))")
                }
            }

            stillView(device)
                .overlay {
                    if stage != nil {
                        ZStack {
                            Rectangle().fill(.black.opacity(0.35))
                            VStack(spacing: 10) {
                                ProgressView().tint(.white)
                                Text(stage?.text ?? "")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.white)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: stage)
                .onTapGesture {
                    if hasStill(device) { showFullStill = true }
                }
                .accessibilityAddTraits(hasStill(device) ? .isButton : [])
                .accessibilityHint(hasStill(device) ? "Opens the still full screen" : "")

            if let err = device.camera.lastError {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(LojoTheme.warning)
            }

            Button {
                Task { await store.capture(device) }
            } label: {
                Label(stage == nil ? "Capture now" : "Capturing…", systemImage: "camera.shutter.button")
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(stage != nil || blocked)
            .accessibilityHint("Asks the camera for a fresh still")
        }
        .card()
    }

    private func hasStill(_ device: Device) -> Bool {
        store.isDemo ? device.capturedDate != nil : store.stills[device.key] != nil
    }

    @ViewBuilder
    private func stillView(_ device: Device) -> some View {
        if store.isDemo, let at = device.capturedDate {
            DemoStillView(deviceKey: device.key, title: device.displayName, capturedAt: at)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else if let still = store.stills[device.key] {
            Image(uiImage: still.image)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityLabel("Latest camera still from \(device.displayName)")
        } else {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.06))
                .aspectRatio(4 / 3, contentMode: .fit)
                .overlay(
                    VStack(spacing: 8) {
                        Image(systemName: "photo")
                            .font(.largeTitle)
                            .foregroundStyle(.tertiary)
                        Text(device.camera.hasStill ? "Loading still…" : "No still yet. Tap Capture now.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                )
                .accessibilityElement(children: .combine)
        }
    }

    // MARK: - controls

    private func controlsCard(_ device: Device) -> some View {
        let blocked = store.actionBlocker(for: device) != nil
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Controls", systemImage: "switch.2")
                    .font(.headline)
                Spacer()
                Text("Confirm before sending")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(device.gpio) { pin in
                OutputRow(
                    pin: pin,
                    busy: store.outputBusy == device.key + ":" + pin.pin,
                    disabled: blocked || store.outputBusy != nil,
                    lastChange: store.lastChange(for: device, pin: pin.pin)
                ) {
                    Haptics.selection()
                    pending = PendingOutput(device: device, pin: pin, turnOn: !pin.isOn)
                }
            }
        }
        .card()
    }

    // MARK: - facts

    private func factsCard(_ device: Device) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Details", systemImage: "info.circle")
                .font(.headline)
            FactRow(label: "Site", value: device.siteName)
            FactRow(label: "Type", value: device.kind.title)
            FactRow(label: "Last update", value: RelativeTime.full(device.lastUpdate))
            FactRow(label: "Joined network", value: RelativeTime.full(ISODate.parse(device.firstSeenAt)))
            if let path = store.link.path {
                FactRow(label: "Reached via", value: path.longTitle)
            } else if store.isDemo {
                FactRow(label: "Reached via", value: ConnectionPath.overlay.longTitle)
            }
            if let loc = device.location {
                FactRow(label: "Location", value: String(format: "%.4f, %.4f", loc.lat, loc.lon))
                FactRow(label: "Location source", value: loc.sourceText)
                Button {
                    router.tab = .map
                } label: {
                    Label("Show on map", systemImage: "map")
                        .font(.subheadline.weight(.semibold))
                }
                .padding(.top, 2)
            } else {
                FactRow(label: "Location", value: "Not reported")
            }
        }
        .card()
    }

    private func activityCard(_ device: Device) -> some View {
        let recent = store.events(for: device)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Recent activity", systemImage: "clock.arrow.circlepath")
                    .font(.headline)
                Spacer()
                Button("All") { router.tab = .activity }
                    .font(.subheadline.weight(.semibold))
            }
            if recent.isEmpty {
                Text("Nothing recorded for this device yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(recent) { ev in
                    EventRow(event: ev, compact: true)
                }
            }
        }
        .card()
    }
}

struct BlockerNote: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "pause.circle.fill")
            .font(.footnote.weight(.medium))
            .foregroundStyle(LojoTheme.warning)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(LojoTheme.warning.opacity(0.12)))
    }
}

struct FactRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.subheadline)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }
}

struct OutputRow: View {
    let pin: Device.Pin
    let busy: Bool
    let disabled: Bool
    let lastChange: NetworkEvent?
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(pin.isOn ? LojoTheme.online.opacity(0.18) : Color.primary.opacity(0.06))
                Image(systemName: "power")
                    .font(.headline)
                    .foregroundStyle(pin.isOn ? LojoTheme.online : .secondary)
            }
            .frame(width: 40, height: 40)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(pin.title)
                    .font(.body.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if busy {
                ProgressView()
                    .frame(width: 84)
            } else {
                Button(action: action) {
                    Text(pin.isOn ? "Turn off" : "Turn on")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 84)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.bordered)
                .tint(pin.isOn ? .secondary : LojoTheme.accent)
                .disabled(disabled)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(pin.title), \(pin.subtitle), currently \(pin.isOn ? "on" : "off")")
    }

    private var detail: String {
        var text = "\(pin.subtitle) · \(pin.isOn ? "ON" : "OFF")"
        if let lastChange {
            text += " · changed \(RelativeTime.text(lastChange.date))"
        }
        return text
    }
}

struct OutputConfirmSheet: View {
    let pending: PendingOutput
    let onConfirm: () -> Void
    let onCancel: () -> Void

    private var verb: String { pending.turnOn ? "Turn on" : "Turn off" }

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle().fill(LojoTheme.warning.opacity(0.16))
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(LojoTheme.warning)
            }
            .frame(width: 64, height: 64)
            .padding(.top, 20)
            .accessibilityHidden(true)

            Text("\(verb) \(pending.pin.title)?")
                .font(.title3.weight(.bold))
                .multilineTextAlignment(.center)

            VStack(spacing: 8) {
                Text("This sends a command to **\(pending.device.displayName)** (\(pending.pin.subtitle)). Whatever is wired to it — a gate, pump, light or relay — will physically \(pending.turnOn ? "switch on" : "switch off").")
                Text("Make sure people and animals are clear before you confirm.")
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)

            VStack(spacing: 10) {
                Button {
                    onConfirm()
                } label: {
                    Label("\(verb) now", systemImage: "power")
                }
                .buttonStyle(PrimaryButtonStyle(tint: pending.turnOn ? LojoTheme.accent : LojoTheme.accentDeep))
                .accessibilityHint("Sends the command to the device")

                Button("Cancel", role: .cancel, action: onCancel)
                    .buttonStyle(SecondaryButtonStyle())
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }
}

struct FullStillView: View {
    let device: Device
    @EnvironmentObject private var store: NetworkStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            Group {
                if store.isDemo, let at = device.capturedDate {
                    DemoStillView(deviceKey: device.key, title: device.displayName, capturedAt: at)
                } else if let still = store.stills[device.key] {
                    Image(uiImage: still.image)
                        .resizable()
                        .scaledToFit()
                        .accessibilityLabel("Camera still from \(device.displayName)")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 32))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .white.opacity(0.25))
            }
            .padding()
            .accessibilityLabel("Close")
        }
    }
}
