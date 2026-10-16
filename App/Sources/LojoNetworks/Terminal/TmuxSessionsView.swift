import LojoSSH
import SwiftUI
import UIKit

/// tmux sessions on one host: list, attach, and kill. Kill asks first and only sends a name this
/// app considers safe. The install command is displayed, never executed.
struct TmuxSessionsView: View {
    @EnvironmentObject private var center: TerminalCenter
    @Environment(\.dismiss) private var dismiss
    let host: SSHHost
    var previewRows: [TmuxRemoteSession]?

    @State private var rows: [TmuxRemoteSession] = []
    @State private var loading = false
    @State private var message: String?
    @State private var pendingKill: TmuxRemoteSession?
    @State private var showInstall = false

    var body: some View {
        NavigationStack {
            List {
                if loading {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Asking the host…").foregroundStyle(.secondary)
                    }
                }
                if let message {
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(LojoTheme.warning)
                }
                if rows.isEmpty, !loading, message == nil {
                    Text("No sessions on this host yet. A session appears here after you connect with Keep sessions alive on.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                ForEach(rows) { row in
                    Button {
                        attach(row)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "terminal")
                                .foregroundStyle(LojoTheme.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.name)
                                    .font(.body.monospaced().weight(.medium))
                                    .foregroundStyle(.primary)
                                Text(row.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                    .accessibilityLabel("Attach \(row.name), \(row.detail)")
                    .swipeActions {
                        Button("Kill", role: .destructive) { pendingKill = row }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Sessions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("tmux.sessions.done")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showInstall = true
                    } label: {
                        Image(systemName: "info.circle")
                    }
                    .accessibilityLabel("Install command")
                }
            }
            .safeAreaInset(edge: .bottom) {
                Text("These sessions stay on the host when the phone disconnects. Attach opens one here. Kill ends it on the host. On the host they live in tmux socket “lojo”.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
            }
            .confirmationDialog(
                "End \(pendingKill?.name ?? "this session")?",
                isPresented: Binding(get: { pendingKill != nil }, set: { if !$0 { pendingKill = nil } }),
                titleVisibility: .visible
            ) {
                Button("Kill session", role: .destructive) {
                    if let pendingKill { kill(pendingKill) }
                }
                Button("Cancel", role: .cancel) { pendingKill = nil }
            } message: {
                Text("Anything still running in it on the host stops.")
            }
            .sheet(isPresented: $showInstall) { TmuxInstallSheet() }
            .task { await load() }
        }
    }

    private func load() async {
        if let previewRows {
            rows = previewRows
            return
        }
        loading = true
        message = nil
        do {
            rows = try await center.listTmuxSessions(on: host)
            loading = false
        } catch {
            loading = false
            message = TerminalSession.message(for: error)
        }
    }

    private func attach(_ row: TmuxRemoteSession) {
        guard previewRows == nil else { return }
        center.attachTmuxSession(named: row.name, on: host)
        dismiss()
    }

    private func kill(_ row: TmuxRemoteSession) {
        pendingKill = nil
        if previewRows != nil {
            rows.removeAll { $0.name == row.name }
            return
        }
        Task {
            do {
                try await center.killTmuxSession(row.name, on: host)
                rows.removeAll { $0.name == row.name }
                Haptics.success()
            } catch {
                message = TerminalSession.message(for: error)
                Haptics.error()
            }
        }
    }
}

struct TmuxInstallSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Run this on the host, as someone who can use sudo. LOJO Networks does not install anything for you.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(TmuxCommand.installCommand)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color(uiColor: .tertiarySystemBackground)))
                Button {
                    UIPasteboard.general.string = TmuxCommand.installCommand
                    copied = true
                    Haptics.success()
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(PrimaryButtonStyle())
                Spacer()
            }
            .padding(20)
            .navigationTitle("Install tmux")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
