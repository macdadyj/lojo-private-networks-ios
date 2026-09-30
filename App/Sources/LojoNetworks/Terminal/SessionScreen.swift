import LojoSSH
import SwiftUI
import UIKit

/// Full-screen terminal: tab strip, session bar, the SwiftTerm view and its prompts.
struct SessionScreen: View {
    @EnvironmentObject private var center: TerminalCenter

    var body: some View {
        VStack(spacing: 0) {
            TabStrip()
            if let session = center.selected {
                SessionPane(session: session)
                    .id(session.id)
            } else {
                Spacer()
            }
        }
        .background(Color(uiColor: UIColor(rgb: center.theme.palette.bg)).ignoresSafeArea())
        .preferredColorScheme(center.theme == .solarizedLight ? .light : .dark)
    }
}

private struct TabStrip: View {
    @EnvironmentObject private var center: TerminalCenter

    var body: some View {
        HStack(spacing: 8) {
            Button {
                center.showingSession = false
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 36, height: 32)
            }
            .accessibilityLabel("Back to hosts")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(center.sessions) { session in
                        TabChip(session: session, selected: session.id == center.selected?.id)
                    }
                }
            }
            Button {
                center.showingSession = false
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 36, height: 32)
            }
            .accessibilityLabel("New session")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
    }
}

private struct TabChip: View {
    @EnvironmentObject private var center: TerminalCenter
    @ObservedObject var session: TerminalSession
    let selected: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(session.phase.tint).frame(width: 7, height: 7)
            Text(session.host.label)
                .font(.footnote.weight(selected ? .semibold : .regular))
                .lineLimit(1)
            Button {
                center.close(session)
            } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
            }
            .accessibilityLabel("Close \(session.host.label)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(selected ? Color.primary.opacity(0.16) : Color.primary.opacity(0.06)))
        .contentShape(Capsule())
        .onTapGesture { center.selectedID = session.id }
    }
}

private struct SessionPane: View {
    @EnvironmentObject private var center: TerminalCenter
    @ObservedObject var session: TerminalSession
    @State private var flash: String?

    var body: some View {
        VStack(spacing: 0) {
            SessionBar(session: session, flash: $flash)
            ZStack {
                TerminalBridge(session: session)
                overlay
            }
        }
        .overlay(alignment: .top) {
            if let flash {
                Text(flash)
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(.thinMaterial))
                    .padding(.top, 52)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: flash)
        .alert(
            "Copy from the remote host?",
            isPresented: Binding(get: { session.pendingClipboard != nil }, set: { if !$0 { session.acceptClipboard(false) } })
        ) {
            Button("Allow") { session.acceptClipboard(true) }
            Button("Don't allow", role: .cancel) { session.acceptClipboard(false) }
        } message: {
            Text("A program on \(session.host.label) wants to put \(session.pendingClipboard?.count ?? 0) characters on the iPhone clipboard.")
        }
    }

    @ViewBuilder
    private var overlay: some View {
        switch session.phase {
        case .awaitingHostKey(let key):
            Dimmed { HostKeyPrompt(session: session, key: key) }
        case .awaitingPassword:
            Dimmed { PasswordPrompt(session: session) }
        case .hostKeyChanged(let new, let previous):
            HostKeyChangedView(session: session, new: new, previous: previous)
        case .failed(let text):
            Dimmed { EndedCard(session: session, icon: "exclamationmark.triangle.fill", tint: LojoTheme.danger, text: text) }
        case .ended(let text):
            VStack {
                Spacer()
                EndedCard(session: session, icon: "checkmark.circle", tint: .secondary, text: text)
                    .padding(.bottom, 24)
            }
        case .connecting, .connected, .reconnecting, .waitingForVPN:
            EmptyView()
        }
    }
}

private struct SessionBar: View {
    @EnvironmentObject private var center: TerminalCenter
    @ObservedObject var session: TerminalSession
    @Binding var flash: String?

    var body: some View {
        HStack(spacing: 4) {
            VStack(alignment: .leading, spacing: 1) {
                Text("\(session.host.username)@\(AddressDisplay.text(session.host.address, redact: center.redact))")
                    .font(.caption.monospaced().weight(.semibold))
                    .lineLimit(1)
                Text(session.phase.summary)
                    .font(.caption2)
                    .foregroundStyle(session.phase == .connected ? Color.secondary : session.phase.tint)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            bar("doc.on.clipboard", "Paste") { session.paste() }
            bar("doc.on.doc", "Copy selection") {
                show(session.copySelection() ? "Copied" : "Long-press to select text first")
            }
            bar("textformat.size.smaller", "Smaller text") { center.fontSize = max(TerminalCenter.fontRange.lowerBound, center.fontSize - 1) }
            bar("textformat.size.larger", "Larger text") { center.fontSize = min(TerminalCenter.fontRange.upperBound, center.fontSize + 1) }
            bar("keyboard", "Show or hide keyboard") { session.toggleKeyboard() }
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial)
    }

    private func bar(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 36, height: 32)
        }
        .accessibilityLabel(label)
    }

    private func show(_ text: String) {
        flash = text
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            if flash == text { flash = nil }
        }
    }
}

private struct Dimmed<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            content
                .padding(20)
                .frame(maxWidth: 420)
                .background(RoundedRectangle(cornerRadius: LojoTheme.cornerRadius).fill(Color(uiColor: .secondarySystemBackground)))
                .padding(20)
        }
    }
}

private struct HostKeyPrompt: View {
    @EnvironmentObject private var center: TerminalCenter
    @ObservedObject var session: TerminalSession
    let key: HostKeyInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("First connection", systemImage: "key.viewfinder")
                .font(.headline)
            Text("This app hasn't seen \(session.host.label) (\(AddressDisplay.text(session.host.address, redact: center.redact))) before. Check that the fingerprint matches the host, for example with `ssh-keygen -lf` on it.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(key.type).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(key.fingerprint)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(uiColor: .tertiarySystemBackground)))
            HStack {
                Button("Cancel") { session.answerHostKey(trust: false) }
                    .buttonStyle(SecondaryButtonStyle())
                Button("Trust and connect") { session.answerHostKey(trust: true) }
                    .buttonStyle(PrimaryButtonStyle())
            }
        }
    }
}

private struct PasswordPrompt: View {
    @EnvironmentObject private var keys: SSHKeyStore
    @ObservedObject var session: TerminalSession
    @State private var password = ""
    @State private var save = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Password for \(session.host.username)", systemImage: "lock")
                .font(.headline)
            Text(keys.keys.isEmpty
                 ? "There's no SSH key on this phone yet, and \(session.host.label) accepts passwords."
                 : "\(session.host.label) didn't accept this phone's keys. Keys are safer: add the public key to its authorized_keys.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            SecureField("Password", text: $password)
                .textContentType(.password)
                .focused($focused)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(uiColor: .tertiarySystemBackground)))
                .onSubmit(submit)
            Toggle("Save in Keychain (this iPhone only)", isOn: $save)
                .font(.subheadline)
            HStack {
                Button("Cancel") { session.answerPassword(nil, save: false) }
                    .buttonStyle(SecondaryButtonStyle())
                Button("Connect", action: submit)
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(password.isEmpty)
            }
        }
        .onAppear { focused = true }
    }

    private func submit() {
        guard !password.isEmpty else { return }
        session.answerPassword(password, save: save)
    }
}

private struct HostKeyChangedView: View {
    @EnvironmentObject private var center: TerminalCenter
    @ObservedObject var session: TerminalSession
    let new: HostKeyInfo
    let previous: [KnownHosts.Entry]

    var body: some View {
        ZStack {
            LojoTheme.danger.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Image(systemName: "exclamationmark.octagon.fill")
                        .font(.system(size: 44))
                    Text("HOST KEY CHANGED")
                        .font(.title.weight(.heavy))
                    Text("\(session.host.label) (\(AddressDisplay.text(session.host.address, redact: center.redact))) answered with a different host key than the one saved on this phone. Someone may be intercepting the connection (possible man-in-the-middle), or the host was reinstalled. The connection was refused.")
                        .font(.body)
                    fingerprint("Saved", previous.map { "\($0.keyType)  \($0.fingerprint)" }.joined(separator: "\n"))
                    fingerprint("Now offered", "\(new.type)  \(new.fingerprint)")
                    Text("If you know why it changed, open the host's settings in the Terminal tab and use Forget saved host key, then connect again and check the new fingerprint.")
                        .font(.subheadline)
                    Button("Close session") { center.close(session) }
                        .buttonStyle(PrimaryButtonStyle(tint: Color.black.opacity(0.35)))
                }
                .foregroundStyle(.white)
                .padding(24)
            }
        }
    }

    private func fingerprint(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased()).font(.caption.weight(.bold)).opacity(0.8)
            Text(value).font(.footnote.monospaced()).textSelection(.enabled)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.25)))
    }
}

private struct EndedCard: View {
    @EnvironmentObject private var center: TerminalCenter
    @ObservedObject var session: TerminalSession
    let icon: String
    let tint: Color
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(text, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Close") { center.close(session) }
                    .buttonStyle(SecondaryButtonStyle())
                Button("Reconnect") { session.connect() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(center.vpnAddress == nil)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(uiColor: .secondarySystemBackground)))
        .padding(.horizontal, 16)
    }
}

/// Hosts the session's long-lived SwiftTerm view; the same view moves between containers on tab switches.
private struct TerminalBridge: UIViewRepresentable {
    let session: TerminalSession

    func makeUIView(context: Context) -> Container {
        Container()
    }

    func updateUIView(_ container: Container, context: Context) {
        container.host(session.hostView)
    }

    final class Container: UIView {
        private weak var child: UIView?

        func host(_ view: UIView) {
            guard child !== view || view.superview !== self else { return }
            if let child, child.superview === self { child.removeFromSuperview() }
            addSubview(view)
            child = view
            setNeedsLayout()
            DispatchQueue.main.async { _ = view.becomeFirstResponder() }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            child?.frame = bounds
        }
    }
}
