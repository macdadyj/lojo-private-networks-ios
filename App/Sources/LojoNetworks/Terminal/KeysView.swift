import LojoSSH
import SwiftUI
import UIKit

struct KeysView: View {
    @EnvironmentObject private var keys: SSHKeyStore
    @State private var naming: SSHKeyRecord.Kind?
    @State private var newLabel = "LOJO iPhone"
    @State private var importing = false
    @State private var deleting: SSHKeyRecord?
    @State private var error: String?

    var body: some View {
        List {
            if !keys.keys.isEmpty {
                Section {
                    ForEach(keys.keys) { record in
                        NavigationLink {
                            KeyDetailView(record: record)
                        } label: {
                            KeyRow(record: record)
                        }
                        .swipeActions {
                            Button("Delete", role: .destructive) { deleting = record }
                        }
                    }
                } header: {
                    Text("On this iPhone")
                } footer: {
                    Text("Add a key's public half to ~/.ssh/authorized_keys on each device you want to reach. The private half never leaves this iPhone.")
                }
            }
            Section {
                Button {
                    start(.secureEnclaveP256)
                } label: {
                    Label("New Secure Enclave key", systemImage: "cpu")
                }
                .disabled(!keys.secureEnclaveAvailable)
                Button {
                    start(.ed25519)
                } label: {
                    Label("New Ed25519 key", systemImage: "key.horizontal")
                }
                Button {
                    importing = true
                } label: {
                    Label("Import a private key…", systemImage: "square.and.arrow.down")
                }
            } header: {
                Text("Add a key")
            } footer: {
                Text(keys.secureEnclaveAvailable
                     ? "Secure Enclave keys (ECDSA P-256) are recommended: the key is created inside the chip and can't be copied off it, not even into a backup. Ed25519 keys are stored in the Keychain for this iPhone only."
                     : "This device has no Secure Enclave. Ed25519 keys are stored in the Keychain for this iPhone only.")
            }
        }
        .navigationTitle("SSH keys")
        .alert("Name the key", isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField("Label", text: $newLabel)
            Button("Create") { create() }
            Button("Cancel", role: .cancel) { naming = nil }
        } message: {
            Text("The label is added to the public key as a comment, so you can recognise it in authorized_keys.")
        }
        .confirmationDialog(
            "Delete this key?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete key", role: .destructive) {
                if let deleting { keys.delete(deleting) }
                deleting = nil
            }
        } message: {
            Text("Hosts that only trust this key will stop accepting this iPhone. A Secure Enclave key can't be recovered.")
        }
        .alert("Couldn't create the key", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: {
            Text(error ?? "")
        }
        .sheet(isPresented: $importing) {
            ImportKeyView()
                .environmentObject(keys)
        }
    }

    private func start(_ kind: SSHKeyRecord.Kind) {
        newLabel = "LOJO iPhone"
        naming = kind
    }

    private func create() {
        guard let kind = naming else { return }
        naming = nil
        let label = newLabel.trimmingCharacters(in: .whitespaces).isEmpty ? "LOJO iPhone" : newLabel
        do {
            switch kind {
            case .secureEnclaveP256: try keys.generateSecureEnclave(label: label)
            case .ed25519, .p256: try keys.generateEd25519(label: label)
            }
            Haptics.success()
        } catch {
            self.error = TerminalSession.message(for: error)
        }
    }
}

private struct KeyRow: View {
    let record: SSHKeyRecord

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: record.kind == .secureEnclaveP256 ? "cpu" : "key.horizontal")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 8).fill(record.kind == .secureEnclaveP256 ? LojoTheme.accentDeep : LojoTheme.accent))
            VStack(alignment: .leading, spacing: 2) {
                Text(record.label).font(.body.weight(.medium))
                Text(record.kind.title).font(.caption).foregroundStyle(.secondary)
                Text(record.fingerprint).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

private struct KeyDetailView: View {
    let record: SSHKeyRecord
    @State private var copied = false

    var body: some View {
        List {
            Section("Public key") {
                Text(record.publicKey)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
                Button {
                    UIPasteboard.general.string = record.publicKey
                    copied = true
                    Haptics.success()
                } label: {
                    Label(copied ? "Copied" : "Copy public key", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                ShareLink(item: record.publicKey) {
                    Label("Share public key", systemImage: "square.and.arrow.up")
                }
            }
            Section {
                LabeledContent("Type", value: record.kind.title)
                LabeledContent("Fingerprint") {
                    Text(record.fingerprint).font(.caption.monospaced()).textSelection(.enabled)
                }
                LabeledContent("Created", value: record.created.formatted(date: .abbreviated, time: .shortened))
            }
            Section {
                Text("On the device, append the line above to `~/.ssh/authorized_keys` of the user you log in as. The file should be mode 600 and `~/.ssh` mode 700.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(record.label)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ImportKeyView: View {
    @EnvironmentObject private var keys: SSHKeyStore
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var label = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text)
                        .font(.caption.monospaced())
                        .frame(minHeight: 180)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("Private key")
                } footer: {
                    Text("Paste an unencrypted OpenSSH Ed25519 or ECDSA P-256 key, or a PEM P-256 key. It goes straight into the Keychain and is never written to a file. A key generated on this iPhone is safer, because an imported key already exists somewhere else.")
                }
                Section("Label") {
                    TextField("Optional", text: $label)
                }
                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(LojoTheme.danger)
                    }
                }
            }
            .navigationTitle("Import key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") {
                        do {
                            try keys.importKey(text: text, label: label)
                            text = ""
                            Haptics.success()
                            dismiss()
                        } catch {
                            self.error = TerminalSession.message(for: error)
                        }
                    }
                    .disabled(text.isEmpty)
                }
            }
        }
    }
}
