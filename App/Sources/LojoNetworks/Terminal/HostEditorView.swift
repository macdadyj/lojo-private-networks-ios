import LojoSSH
import SwiftUI

struct HostEditorView: View {
    @EnvironmentObject private var center: TerminalCenter
    @EnvironmentObject private var hosts: HostStore
    @EnvironmentObject private var keys: SSHKeyStore
    @Environment(\.dismiss) private var dismiss
    @State private var host: SSHHost
    @State private var portText: String
    @State private var confirmForgetKey = false
    @State private var confirmDelete = false
    @State private var hasPassword: Bool
    private let isNew: Bool

    init(draft: HostDraft) {
        _host = State(initialValue: draft.host)
        _portText = State(initialValue: String(draft.host.port))
        _hasPassword = State(initialValue: false)
        isNew = draft.isNew
    }

    private var trimmedAddress: String { host.address.trimmingCharacters(in: .whitespaces).lowercased() }

    private var addressProblem: String? {
        let address = trimmedAddress
        if address.isEmpty { return nil }
        if IPv4Range.parse(address) != nil {
            return hosts.policy.allows(address: address) ? nil
                : "Only LOJO overlay addresses (100.64.0.0/10) and LOJO-routed subnets are allowed."
        }
        return OverlayPolicy.privateSuffixes.contains(where: { address.hasSuffix($0) }) ? nil
            : "Use an overlay IPv4 address or a .lan name. Public hosts are refused."
    }

    private var port: Int? { Int(portText).flatMap { (1...65535).contains($0) ? $0 : nil } }

    private var canSave: Bool {
        !host.label.trimmingCharacters(in: .whitespaces).isEmpty && !trimmedAddress.isEmpty
            && addressProblem == nil && port != nil && !host.username.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Label", text: $host.label)
                    TextField("Address", text: $host.address)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Port", text: $portText)
                        .keyboardType(.numberPad)
                    TextField("User", text: $host.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Group", text: $host.group)
                } footer: {
                    if let addressProblem {
                        Text(addressProblem).foregroundStyle(LojoTheme.danger)
                    } else {
                        Text("SSH only goes over the LOJO overlay. The LOJO VPN must be on to connect.")
                    }
                }

                Section("Authentication") {
                    Picker("Key", selection: $host.keyID) {
                        Text("Any key on this iPhone").tag(String?.none)
                        ForEach(keys.keys) { record in
                            Text(record.label).tag(Optional(record.id))
                        }
                    }
                    if hasPassword {
                        Button("Forget saved password", role: .destructive) {
                            keys.forgetPassword(hostID: host.id)
                            hasPassword = false
                        }
                    } else {
                        Text("No saved password. The app asks for one only if the host refuses every key.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if !isNew {
                    hostKeySection
                    Section {
                        Button("Delete host", role: .destructive) { confirmDelete = true }
                    }
                }
            }
            .navigationTitle(isNew ? "New host" : host.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).disabled(!canSave)
                }
            }
            .confirmationDialog("Forget the saved host key?", isPresented: $confirmForgetKey, titleVisibility: .visible) {
                Button("Forget host key", role: .destructive) {
                    hosts.forgetHostKey(for: host)
                    Haptics.warning()
                }
            } message: {
                Text("Only do this if you know why the key changed (for example, the device was reinstalled). The next connection shows the new fingerprint for you to check.")
            }
            .confirmationDialog("Delete \(host.label)?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete host", role: .destructive) {
                    keys.forgetPassword(hostID: host.id)
                    hosts.delete(host)
                    dismiss()
                }
            }
            .onAppear { hasPassword = keys.password(hostID: host.id) != nil }
        }
    }

    private var hostKeySection: some View {
        Section {
            let saved = hosts.savedHostKeys(for: host)
            if saved.isEmpty {
                Text("No host key saved yet. It's checked and saved on the first connection.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(saved, id: \.self) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.keyType).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(entry.fingerprint).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
                Button("Forget saved host key", role: .destructive) { confirmForgetKey = true }
            }
        } header: {
            Text("Host key")
        }
    }

    private func save() {
        guard let port else { return }
        host.port = port
        host.label = host.label.trimmingCharacters(in: .whitespaces)
        host.address = trimmedAddress
        host.group = host.group.trimmingCharacters(in: .whitespaces).isEmpty ? "Hosts" : host.group
        hosts.upsert(host)
        Haptics.success()
        dismiss()
    }
}

struct TerminalSettingsView: View {
    @EnvironmentObject private var center: TerminalCenter
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Text") {
                    Stepper(value: $center.fontSize, in: TerminalCenter.fontRange, step: 1) {
                        LabeledContent("Font size", value: "\(Int(center.fontSize)) pt")
                    }
                    Text("user@host:~$ ls -la")
                        .font(.system(size: CGFloat(center.fontSize), design: .monospaced))
                        .foregroundStyle(Color(uiColor: UIColor(rgb: center.theme.palette.fg)))
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color(uiColor: UIColor(rgb: center.theme.palette.bg))))
                }
                Section("Theme") {
                    ForEach(TerminalTheme.allCases) { theme in
                        Button {
                            center.theme = theme
                        } label: {
                            HStack {
                                ThemeSwatch(theme: theme)
                                Text(theme.title).foregroundStyle(.primary)
                                Spacer()
                                if center.theme == theme {
                                    Image(systemName: "checkmark").foregroundStyle(LojoTheme.accent)
                                }
                            }
                        }
                    }
                }
                Section {
                    Toggle("Mask addresses", isOn: $center.redact)
                } footer: {
                    Text("Hides the last two parts of every IP address in the Terminal tab, for screenshots and screen sharing.")
                }
            }
            .navigationTitle("Terminal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct ThemeSwatch: View {
    let theme: TerminalTheme

    var body: some View {
        let palette = theme.palette
        HStack(spacing: 0) {
            ForEach(Array([palette.bg, palette.fg, palette.ansi[1], palette.ansi[2], palette.ansi[4]].enumerated()), id: \.offset) { _, rgb in
                Rectangle().fill(Color(uiColor: UIColor(rgb: rgb)))
            }
        }
        .frame(width: 60, height: 22)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.3)))
    }
}
