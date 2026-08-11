import SwiftUI
import Charts
import FileWallKit

/// The Security section: storage breakdown, the hidden-vault lock, biometric
/// options, and Google Backup & Sync.
struct SecurityView: View {
    @EnvironmentObject private var app: AppState
    @StateObject private var auth = GoogleAuth.shared

    @State private var storage: StorageBreakdown?
    @State private var backupStatus: String?
    @State private var working = false

    var body: some View {
        List {
            storageSection
            hiddenVaultSection
            backupSection
        }
        .navigationTitle("Security")
        .task { await loadStorage() }
    }

    // MARK: Storage

    private var storageSection: some View {
        Section("Storage") {
            if let storage, storage.totalBytes > 0 {
                Chart(categoryRows(storage)) { row in
                    BarMark(
                        x: .value("Bytes", row.bytes),
                        y: .value("Category", row.name)
                    )
                    .foregroundStyle(by: .value("Category", row.name))
                }
                .chartLegend(.hidden)
                .frame(height: 160)

                LabeledContent("Total", value: ByteCountFormatter.string(fromByteCount: storage.totalBytes, countStyle: .file))
                LabeledContent("Items", value: "\(storage.itemCount)")
            } else {
                Text("Your vault is empty.").foregroundStyle(.secondary)
            }
        }
    }

    private struct CategoryRow: Identifiable {
        let id = UUID(); let name: String; let bytes: Int64
    }

    private func categoryRows(_ s: StorageBreakdown) -> [CategoryRow] {
        s.bytesByCategory
            .map { CategoryRow(name: $0.key.rawValue.capitalized, bytes: $0.value) }
            .sorted { $0.bytes > $1.bytes }
    }

    // MARK: Hidden vault

    private var hiddenVaultSection: some View {
        Section {
            Button(role: .destructive) {
                app.lockHidden()
            } label: {
                Label("Lock Hidden Vault Now", systemImage: "lock.fill")
            }
            .disabled(!app.hiddenUnlocked)

            Toggle("Require biometrics only", isOn: Binding(
                get: { app.biometricsOnly },
                set: { app.biometricsOnly = $0 }))
        } header: {
            Text("Hidden Vault")
        } footer: {
            Text("With this off, Face ID or Touch ID falls back to your device passcode. With it on, only biometrics can unlock the hidden vault.")
        }
    }

    // MARK: Backup

    private var backupSection: some View {
        Section {
            if auth.isSignedIn {
                LabeledContent("Signed in", value: auth.email ?? "Google")

                Button {
                    run { let r = try await DriveBackupService.shared.backup(sides: [.standard, .hidden])
                          return "Backed up \(r.items) file\(r.items == 1 ? "" : "s")." }
                } label: { Label("Back Up Now", systemImage: "icloud.and.arrow.up") }

                Button {
                    run { let r = try await DriveBackupService.shared.restore()
                          return "Restored \(r.items) file\(r.items == 1 ? "" : "s")." }
                } label: { Label("Restore from Backup", systemImage: "icloud.and.arrow.down") }

                Button(role: .destructive) { auth.signOut() } label: {
                    Label("Sign Out", systemImage: "person.crop.circle.badge.xmark")
                }
            } else {
                Button {
                    run { try await auth.signIn(); return "Signed in." }
                } label: { Label("Sign in with Google", systemImage: "person.crop.circle.badge.plus") }
            }

            if working { ProgressView() }
            if let backupStatus { Text(backupStatus).font(.footnote).foregroundStyle(.secondary) }
        } header: {
            Text("Cloud Backup & Sync")
        } footer: {
            Text("The backup is encrypted before it leaves your device and shares one file with the FileWall Android app. It's as safe as your Google account.")
        }
    }

    // MARK: Helpers

    private func loadStorage() async {
        storage = try? await VaultService.shared.vaultStore().storageBreakdown(side: .standard)
    }

    /// Run an async backup/auth op, surfacing its outcome and refreshing storage.
    private func run(_ op: @escaping () async throws -> String) {
        working = true
        backupStatus = nil
        Task {
            do { backupStatus = try await op() }
            catch { backupStatus = error.localizedDescription }
            await loadStorage()
            working = false
        }
    }
}
