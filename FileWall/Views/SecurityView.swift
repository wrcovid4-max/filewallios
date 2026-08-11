import SwiftUI
import Charts
import UniformTypeIdentifiers
import FileWallKit

/// The Security section: appearance, storage, inactivity auto-lock, the
/// hidden-vault lock, privacy toggles, local encrypted-archive export/restore,
/// and Google Backup & Sync.
struct SecurityView: View {
    @EnvironmentObject private var app: AppState
    @StateObject private var auth = GoogleAuth.shared

    @AppStorage(Pref.appearance) private var appearanceRaw = Appearance.system.rawValue
    @AppStorage(Pref.autoLockSeconds) private var autoLockSeconds = Pref.defaultAutoLockSeconds
    @AppStorage(Pref.allowScreenshots) private var allowScreenshots = false
    @AppStorage(Pref.watchSync) private var watchSync = Pref.defaultWatchSync
    @AppStorage(Pref.documentPreviews) private var documentPreviews = Pref.defaultDocumentPreviews
    @AppStorage(Pref.dailyBackup) private var dailyBackup = false

    @State private var storage: StorageBreakdown?
    @State private var backupStatus: String?
    @State private var working = false

    // Local archive export / import
    @State private var showExportPassphrase = false
    @State private var exportPassphrase = ""
    @State private var exportedArchive: IdentifiableURL?
    @State private var showImportPicker = false
    @State private var pendingImportURL: URL?
    @State private var showImportPassphrase = false
    @State private var importPassphrase = ""

    var body: some View {
        List {
            appearanceSection
            storageSection
            autoLockSection
            hiddenVaultSection
            privacySection
            localArchiveSection
            backupSection
        }
        .navigationTitle("Security")
        .task { await loadStorage() }
        .alert("Export Passphrase", isPresented: $showExportPassphrase) {
            SecureField("Passphrase (min 8)", text: $exportPassphrase)
            Button("Cancel", role: .cancel) { exportPassphrase = "" }
            Button("Export") { runExport() }
        } message: {
            Text("You’ll need this passphrase to restore the archive. It isn’t stored anywhere.")
        }
        .sheet(item: $exportedArchive) { item in ExportShareSheet(url: item.url) }
        .fileImporter(isPresented: $showImportPicker, allowedContentTypes: [.data],
                      allowsMultipleSelection: false) { handleImportPick($0) }
        .alert("Archive Passphrase", isPresented: $showImportPassphrase) {
            SecureField("Passphrase", text: $importPassphrase)
            Button("Cancel", role: .cancel) { pendingImportURL = nil; importPassphrase = "" }
            Button("Restore") { runImport() }
        } message: {
            Text("Enter the passphrase this .fwvault was exported with.")
        }
    }

    // MARK: Appearance

    private var appearanceSection: some View {
        Section("Appearance") {
            Picker("Theme", selection: $appearanceRaw) {
                ForEach(Appearance.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
        }
    }

    // MARK: Storage

    private var storageSection: some View {
        Section("Storage") {
            if let storage, storage.totalBytes > 0 {
                Chart(categoryRows(storage)) { row in
                    BarMark(x: .value("Bytes", row.bytes), y: .value("Category", row.name))
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
        s.bytesByCategory.map { CategoryRow(name: $0.key.rawValue.capitalized, bytes: $0.value) }
            .sorted { $0.bytes > $1.bytes }
    }

    // MARK: Auto-lock

    private var autoLockSection: some View {
        Section {
            Picker("Lock after", selection: $autoLockSeconds) {
                ForEach(AutoLock.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .onChange(of: autoLockSeconds) { _ in app.scheduleAutoLock() }
        } header: {
            Text("Inactivity Auto-Lock")
        } footer: {
            Text("Locks the hidden vault after this idle time. The vault also always locks when the app goes to the background.")
        }
    }

    // MARK: Hidden vault

    private var hiddenVaultSection: some View {
        Section {
            Button(role: .destructive) { app.lockHidden() } label: {
                Label("Lock Hidden Vault Now", systemImage: "lock.fill")
            }
            .disabled(!app.hiddenUnlocked)

            Toggle("Require biometrics only", isOn: Binding(
                get: { app.biometricsOnly }, set: { app.biometricsOnly = $0 }))
        } header: {
            Text("Hidden Vault")
        } footer: {
            Text("With this off, Face ID or Touch ID falls back to your device passcode. With it on, only biometrics can unlock the hidden vault.")
        }
    }

    // MARK: Privacy toggles

    private var privacySection: some View {
        Section {
            Toggle("Allow Screenshots", isOn: $allowScreenshots)
            Toggle("Sync to Wear OS", isOn: $watchSync)
            Toggle("Document Previews", isOn: $documentPreviews)
        } header: {
            Text("Privacy")
        } footer: {
            Text("Screenshots off keeps vault content out of the app-switcher preview and screen recordings. Wear OS sync mirrors only non-hidden files to the watch. Document Previews render a PDF’s first page on its tile.")
        }
    }

    // MARK: Local encrypted archive

    private var localArchiveSection: some View {
        Section {
            Button { showExportPassphrase = true } label: {
                Label("Export .fwvault", systemImage: "square.and.arrow.up")
            }
            Button { showImportPicker = true } label: {
                Label("Restore from .fwvault", systemImage: "square.and.arrow.down")
            }
        } header: {
            Text("Encrypted Archive")
        } footer: {
            Text("Export the whole vault as a single passphrase-protected .fwvault file (Save to Files), or restore one. Same format as the FileWall Android app.")
        }
    }

    // MARK: Cloud backup

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
                Toggle("Back up daily", isOn: $dailyBackup)
                    .onChange(of: dailyBackup) { on in
                        if on { BackgroundBackup.schedule() } else { BackgroundBackup.cancel() }
                    }
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
            Text("Encrypted before it leaves your device and shares one backup with the FileWall Android app. As safe as your Google account.")
        }
    }

    // MARK: Actions

    private func loadStorage() async {
        storage = try? await VaultService.shared.vaultStore().storageBreakdown(side: .standard)
    }

    private func run(_ op: @escaping () async throws -> String) {
        working = true; backupStatus = nil
        Task {
            do { backupStatus = try await op() } catch { backupStatus = error.localizedDescription }
            await loadStorage(); working = false
        }
    }

    private func runExport() {
        let pass = exportPassphrase; exportPassphrase = ""
        working = true; backupStatus = nil
        Task {
            do { exportedArchive = IdentifiableURL(url: try await DriveBackupService.shared.exportLocalArchive(passphrase: pass)) }
            catch { backupStatus = error.localizedDescription }
            working = false
        }
    }

    private func handleImportPick(_ result: Result<[URL], Error>) {
        guard case let .success(urls) = result, let picked = urls.first else { return }
        let scoped = picked.startAccessingSecurityScopedResource()
        defer { if scoped { picked.stopAccessingSecurityScopedResource() } }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(picked.lastPathComponent)
        try? FileManager.default.removeItem(at: temp)
        do {
            try FileManager.default.copyItem(at: picked, to: temp)
            pendingImportURL = temp
            showImportPassphrase = true
        } catch {
            backupStatus = "Couldn’t read that file."
        }
    }

    private func runImport() {
        guard let url = pendingImportURL else { return }
        let pass = importPassphrase
        importPassphrase = ""; pendingImportURL = nil
        working = true; backupStatus = nil
        Task {
            do { let r = try await DriveBackupService.shared.importLocalArchive(from: url, passphrase: pass)
                 backupStatus = "Restored \(r.items) file\(r.items == 1 ? "" : "s")." }
            catch { backupStatus = error.localizedDescription }
            await loadStorage(); working = false
        }
    }
}

/// Wraps a URL so it can drive a `.sheet(item:)`.
private struct IdentifiableURL: Identifiable {
    let id = UUID()
    let url: URL
}

/// A small sheet offering to save/share a freshly-exported archive.
private struct ExportShareSheet: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Image(systemName: "lock.doc").font(.system(size: 48)).foregroundStyle(.secondary)
                Text("Your encrypted archive is ready.").font(.headline)
                Text(url.lastPathComponent).font(.footnote).foregroundStyle(.secondary)
                ShareLink(item: url) { Label("Save or Share", systemImage: "square.and.arrow.up") }
                    .buttonStyle(.borderedProminent)
            }
            .padding()
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
    }
}
