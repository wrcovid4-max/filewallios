import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import FileWallKit

/// The live grid for one vault side: photos/videos/documents, an import button,
/// folder filter chips, per-file actions, and the Archive / Recently Deleted
/// destinations at the end.
struct VaultGridView: View {
    let side: VaultSideSelector

    /// When provided (iPad/Mac split view), tapping a tile sets this selection and
    /// the detail column previews it. When nil (iPhone), a tile pushes a
    /// full-screen `ItemDetailView` instead.
    var selection: Binding<VaultFileSnapshot?>? = nil

    @State private var items: [VaultFileSnapshot] = []
    @State private var folders: [VaultFolderSnapshot] = []
    @State private var archiveCount = 0
    @State private var trashCount = 0
    @State private var selectedFolder: UUID?

    // Import
    @State private var photoPicks: [PhotosPickerItem] = []
    @State private var showPhotoPicker = false
    @State private var showFileImporter = false

    // Per-file editing
    @State private var renameTarget: VaultFileSnapshot?
    @State private var renameText = ""
    @State private var moveTarget: VaultFileSnapshot?
    @State private var showNewFolder = false
    @State private var newFolderName = ""

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 8)]

    var body: some View {
        ScrollView {
            if !folders.isEmpty { folderChips }

            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(filteredItems) { item in
                    tile(for: item)
                        .contextMenu { liveActions(for: item) }
                }
            }
            .padding(8)

            destinations
        }
        .navigationTitle(side == .hidden ? "Hidden" : "Vault")
        .toolbar { toolbarContent }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoPicks, matching: .images)
        .task { await load() }
        .refreshable { await load() }
        .onChange(of: photoPicks) { picks in Task { await importPhotos(picks) } }
        .fileImporter(isPresented: $showFileImporter,
                      allowedContentTypes: [.item],
                      allowsMultipleSelection: true) { result in
            Task { await importFiles(result) }
        }
        .alert("Rename", isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { renameTarget = nil }
            Button("Save") { Task { await commitRename() } }
        }
        .sheet(item: $moveTarget) { target in
            MoveSheet(folders: folders, currentFolder: target.folderID) { destination in
                Task { await move(target, to: destination) }
            }
        }
        .alert("New Folder", isPresented: $showNewFolder) {
            TextField("Folder name", text: $newFolderName)
            Button("Cancel", role: .cancel) {}
            Button("Create") { Task { await createFolder() } }
        }
    }

    // MARK: Pieces

    /// A tile that either drives the split-view selection (iPad) or pushes a
    /// detail screen (iPhone).
    @ViewBuilder
    private func tile(for item: VaultFileSnapshot) -> some View {
        if let selection {
            Button { selection.wrappedValue = item } label: {
                FileTile(item: item, side: side)
            }
            .buttonStyle(.plain)
            .overlay {
                if selection.wrappedValue?.id == item.id {
                    RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor, lineWidth: 3)
                }
            }
        } else {
            NavigationLink { ItemDetailView(item: item, side: side) } label: {
                FileTile(item: item, side: side)
            }
            .buttonStyle(.plain)
        }
    }

    private var filteredItems: [VaultFileSnapshot] {
        guard let selectedFolder else { return items }
        return items.filter { $0.folderID == selectedFolder }
    }

    private var folderChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(title: "All", isOn: selectedFolder == nil) { selectedFolder = nil }
                ForEach(folders) { folder in
                    chip(title: folder.name, isOn: selectedFolder == folder.id) { selectedFolder = folder.id }
                }
            }
            .padding(.horizontal, 8)
        }
        .padding(.top, 4)
    }

    private func chip(title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.footnote.weight(.medium))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(isOn ? Color.accentColor.opacity(0.2) : Color.gray.opacity(0.15))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var destinations: some View {
        VStack(spacing: 8) {
            NavigationLink {
                StateListView(side: side, state: .archived)
            } label: { destinationRow(icon: "archivebox", title: "Archive", count: archiveCount) }

            NavigationLink {
                StateListView(side: side, state: .trashed)
            } label: { destinationRow(icon: "trash", title: "Recently Deleted", count: trashCount) }
        }
        .padding()
    }

    private func destinationRow(icon: String, title: String, count: Int) -> some View {
        HStack {
            Image(systemName: icon)
            Text(title)
            Spacer()
            Text("\(count)").foregroundStyle(.secondary)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .padding()
        .background(Color.gray.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .buttonStyle(.plain)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button { showPhotoPicker = true } label: { Label("Photos", systemImage: "photo") }
                Button { showFileImporter = true } label: { Label("Files", systemImage: "doc") }
                Divider()
                Button { showNewFolder = true } label: { Label("New Folder", systemImage: "folder.badge.plus") }
            } label: {
                Image(systemName: "plus")
            }
        }
    }

    @ViewBuilder
    private func liveActions(for item: VaultFileSnapshot) -> some View {
        Button { renameTarget = item; renameText = item.name } label: { Label("Rename", systemImage: "pencil") }
        Button { moveTarget = item } label: { Label("Move to Folder", systemImage: "folder") }
        Button { Task { await archive(item) } } label: { Label("Archive", systemImage: "archivebox") }
        Button(role: .destructive) { Task { await trash(item) } } label: { Label("Delete", systemImage: "trash") }
    }

    // MARK: Data

    private func load() async {
        do {
            let store = try await VaultService.shared.vaultStore()
            items = try await store.liveFiles(side: side)
            folders = try await store.folders(side: side)
            archiveCount = try await store.archiveCount(side: side)
            trashCount = try await store.recentlyDeletedCount(side: side)
        } catch { /* surfaced elsewhere; keep the grid resilient */ }
    }

    private func archive(_ item: VaultFileSnapshot) async {
        try? await VaultService.shared.vaultStore().archive(id: item.id)
        await load()
    }

    private func trash(_ item: VaultFileSnapshot) async {
        try? await VaultService.shared.vaultStore().trash(id: item.id)
        await load()
    }

    private func move(_ item: VaultFileSnapshot, to folder: UUID?) async {
        try? await VaultService.shared.vaultStore().move(id: item.id, toFolder: folder)
        moveTarget = nil
        await load()
    }

    private func commitRename() async {
        guard let target = renameTarget else { return }
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        renameTarget = nil
        guard !name.isEmpty else { return }
        try? await VaultService.shared.vaultStore().rename(id: target.id, to: name)
        await load()
    }

    private func createFolder() async {
        let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        newFolderName = ""
        guard !name.isEmpty else { return }
        _ = try? await VaultService.shared.vaultStore()
            .createFolder(name: name, colorIndex: Int.random(in: 0..<8), side: side)
        await load()
    }

    private func importPhotos(_ picks: [PhotosPickerItem]) async {
        for pick in picks {
            if let data = try? await pick.loadTransferable(type: Data.self) {
                let name = "Photo-\(Int(Date().timeIntervalSince1970)).jpg"
                _ = try? await VaultService.shared.importData(data, name: name, mimeType: "image/jpeg",
                                                              folderID: selectedFolder, side: side)
            }
        }
        photoPicks = []
        await load()
    }

    private func importFiles(_ result: Result<[URL], Error>) async {
        guard case let .success(urls) = result else { return }
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { continue }
            let ext = url.pathExtension
            let mime = UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
            _ = try? await VaultService.shared.importData(data, name: url.lastPathComponent, mimeType: mime,
                                                          folderID: selectedFolder, side: side)
        }
        await load()
    }
}

/// Folder picker for the Move action.
private struct MoveSheet: View {
    let folders: [VaultFolderSnapshot]
    let currentFolder: UUID?
    let onPick: (UUID?) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Button {
                    onPick(nil); dismiss()
                } label: {
                    HStack { Text("No Folder"); Spacer(); if currentFolder == nil { Image(systemName: "checkmark") } }
                }
                ForEach(folders) { folder in
                    Button {
                        onPick(folder.id); dismiss()
                    } label: {
                        HStack { Text(folder.name); Spacer(); if currentFolder == folder.id { Image(systemName: "checkmark") } }
                    }
                }
            }
            .navigationTitle("Move to Folder")
        }
    }
}
