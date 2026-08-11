import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import FileWallKit

/// The live grid for one vault side. At the root it shows **folders** (openable
/// tiles) then the loose files; opening a folder pushes another `VaultGridView`
/// scoped to that folder. Per-file actions (Rename / Move / Share / Archive /
/// Delete), an import button, and the pinned Archive / Recently Deleted footer.
struct VaultGridView: View {
    let side: VaultSideSelector

    /// nil == the root of this side; non-nil == inside that folder.
    var folder: VaultFolderSnapshot? = nil

    /// iPad/Mac split view: tapping a file drives this selection instead of pushing.
    var selection: Binding<VaultFileSnapshot?>? = nil

    @State private var items: [VaultFileSnapshot] = []
    @State private var folders: [VaultFolderSnapshot] = []
    @State private var archiveCount = 0
    @State private var trashCount = 0
    @State private var searchText = ""
    @State private var categoryFilter: VaultCategory?
    @State private var density: GridDensity = .comfortable

    // Import
    @State private var photoPicks: [PhotosPickerItem] = []
    @State private var showPhotoPicker = false
    @State private var showFileImporter = false

    // File editing
    @State private var renameTarget: VaultFileSnapshot?
    @State private var renameText = ""
    @State private var moveTarget: VaultFileSnapshot?
    @State private var sharePayload: SharePayload?

    // Folder editing
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var folderRenameTarget: VaultFolderSnapshot?
    @State private var folderRenameText = ""
    @State private var folderDeleteTarget: VaultFolderSnapshot?

    // Bulk selection
    @State private var isSelecting = false
    @State private var selectedIDs: Set<UUID> = []
    @State private var showBatchMove = false

    private var isRoot: Bool { folder == nil }
    private var columns: [GridItem] { [GridItem(.adaptive(minimum: density.minimum), spacing: 8)] }
    private var navTitle: String { folder?.name ?? (side == .hidden ? "Hidden" : "Vault") }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                if isRoot && !folders.isEmpty { foldersSection }
                filesSection
            }
            if isSelecting {
                selectionBar
            } else if isRoot {
                destinationsFooter   // pinned dock at the very bottom
            }
        }
        .navigationTitle(navTitle)
        .navigationBarTitleDisplayMode(isRoot ? .large : .inline)
        .searchable(text: $searchText, prompt: "Search by name")
        .toolbar { toolbarContent }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoPicks, matching: .images)
        .task { await load() }
        .refreshable { await load() }
        .onChange(of: photoPicks) { picks in Task { await importPhotos(picks) } }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item],
                      allowsMultipleSelection: true) { result in Task { await importFiles(result) } }
        .sheet(item: $moveTarget) { target in
            MoveSheet(folders: rootFolders, currentFolder: target.folderID) { destination in
                Task { await move(target, to: destination) }
            }
        }
        .sheet(item: $sharePayload) { FileShareSheet(url: $0.url) }
        .sheet(isPresented: $showBatchMove) {
            MoveSheet(folders: rootFolders, currentFolder: nil) { destination in
                Task { await batchMove(to: destination) }
            }
        }
        .alert("Rename", isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { renameTarget = nil }
            Button("Save") {
                guard let target = renameTarget else { return }
                let newName = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                Task { await commitRename(target: target, newName: newName) }
            }
        }
        .alert("Rename Folder", isPresented: Binding(get: { folderRenameTarget != nil }, set: { if !$0 { folderRenameTarget = nil } })) {
            TextField("Folder name", text: $folderRenameText)
            Button("Cancel", role: .cancel) { folderRenameTarget = nil }
            Button("Save") {
                guard let target = folderRenameTarget else { return }
                let newName = folderRenameText.trimmingCharacters(in: .whitespacesAndNewlines)
                Task { await commitFolderRename(target: target, newName: newName) }
            }
        }
        .confirmationDialog("Delete Folder?",
                            isPresented: Binding(get: { folderDeleteTarget != nil }, set: { if !$0 { folderDeleteTarget = nil } }),
                            titleVisibility: .visible) {
            Button("Delete Folder", role: .destructive) {
                if let target = folderDeleteTarget { Task { await deleteFolder(target) } }
            }
            Button("Cancel", role: .cancel) { folderDeleteTarget = nil }
        } message: {
            Text("The folder is removed. Its files aren’t deleted — they move back to the main vault.")
        }
        .alert("New Folder", isPresented: $showNewFolder) {
            TextField("Folder name", text: $newFolderName)
            Button("Cancel", role: .cancel) {}
            Button("Create") { Task { await createFolder() } }
        }
    }

    // MARK: Sections

    private var foldersSection: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(rootFolders) { f in
                NavigationLink {
                    VaultGridView(side: side, folder: f, selection: selection)
                } label: {
                    FolderTile(folder: f, side: side)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button { folderRenameTarget = f; folderRenameText = f.name } label: { Label("Rename", systemImage: "pencil") }
                    Button(role: .destructive) { folderDeleteTarget = f } label: { Label("Delete Folder", systemImage: "trash") }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
    }

    private var filesSection: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(filteredItems) { item in
                tile(for: item)
                    .contextMenu { liveActions(for: item) }
            }
        }
        .padding(8)
    }

    @ViewBuilder
    private func tile(for item: VaultFileSnapshot) -> some View {
        if isSelecting {
            let picked = selectedIDs.contains(item.id)
            Button { toggleSelect(item.id) } label: { FileTile(item: item, side: side) }
                .buttonStyle(.plain)
                .overlay(alignment: .topTrailing) {
                    Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, picked ? Color.accentColor : Color.black.opacity(0.35))
                        .font(.title3)
                        .padding(5)
                }
                .overlay {
                    if picked { RoundedRectangle(cornerRadius: 12).stroke(Color.accentColor, lineWidth: 3) }
                }
        } else if let selection {
            Button { selection.wrappedValue = item } label: { FileTile(item: item, side: side) }
                .buttonStyle(.plain)
                .overlay {
                    if selection.wrappedValue?.id == item.id {
                        RoundedRectangle(cornerRadius: 12).stroke(Color.accentColor, lineWidth: 3)
                    }
                }
        } else {
            NavigationLink { ItemDetailView(item: item, side: side) } label: { FileTile(item: item, side: side) }
                .buttonStyle(.plain)
        }
    }

    private func toggleSelect(_ id: UUID) {
        if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) }
    }

    /// Batch actions on the selected files. On the standard side "Hide" moves them
    /// into the hidden vault; on the hidden side the same button reads "Unhide"
    /// and moves them back.
    private var selectionBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 20) {
                Text("\(selectedIDs.count)").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                selectionButton(icon: side == .hidden ? "eye" : "eye.slash",
                                title: side == .hidden ? "Unhide" : "Hide") {
                    Task { await batchSetHidden(side != .hidden) }
                }
                selectionButton(icon: "folder", title: "Move") { showBatchMove = true }
                selectionButton(icon: "archivebox", title: "Archive") { Task { await batchArchive() } }
                selectionButton(icon: "trash", title: "Delete", role: .destructive) { Task { await batchDelete() } }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .disabled(selectedIDs.isEmpty)
        }
        .background(.bar)
    }

    private func selectionButton(icon: String, title: String, role: ButtonRole? = nil,
                                 action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            VStack(spacing: 2) {
                Image(systemName: icon).font(.body)
                Text(title).font(.caption2)
            }
        }
    }

    private var filteredItems: [VaultFileSnapshot] {
        items.filter { item in
            (categoryFilter == nil || item.category == categoryFilter)
                && (searchText.isEmpty || item.name.localizedCaseInsensitiveContains(searchText))
        }
    }

    /// Folders always come from the side's root (used for the Move picker too).
    private var rootFolders: [VaultFolderSnapshot] { folders }

    // MARK: Footer (root only)

    private var destinationsFooter: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 10) {
                footerCard(icon: "archivebox", title: "Archive", count: archiveCount) { StateListView(side: side, state: .archived) }
                footerCard(icon: "trash", title: "Recently Deleted", count: trashCount) { StateListView(side: side, state: .trashed) }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .background(.bar)
    }

    private func footerCard<Destination: View>(icon: String, title: String, count: Int,
                                               @ViewBuilder destination: @escaping () -> Destination) -> some View {
        NavigationLink { destination() } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                Text(title).font(.caption).lineLimit(1)
                Spacer(minLength: 4)
                Text("\(count)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(Color.secondary.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            Button(isSelecting ? "Done" : "Select") {
                isSelecting.toggle()
                if !isSelecting { selectedIDs = [] }
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Picker("Type", selection: $categoryFilter) {
                    Text("All Types").tag(VaultCategory?.none)
                    ForEach(VaultCategory.allCases, id: \.self) { category in
                        Text(category.rawValue.capitalized).tag(VaultCategory?.some(category))
                    }
                }
                Picker("Layout", selection: $density) {
                    ForEach(GridDensity.allCases, id: \.self) { d in
                        Label(d.title, systemImage: d.symbol).tag(d)
                    }
                }
            } label: {
                Image(systemName: categoryFilter == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button { showPhotoPicker = true } label: { Label("Photos", systemImage: "photo") }
                Button { showFileImporter = true } label: { Label("Files", systemImage: "doc") }
                if isRoot {
                    Divider()
                    Button { showNewFolder = true } label: { Label("New Folder", systemImage: "folder.badge.plus") }
                }
            } label: { Image(systemName: "plus") }
        }
    }

    @ViewBuilder
    private func liveActions(for item: VaultFileSnapshot) -> some View {
        Button { renameTarget = item; renameText = item.name } label: { Label("Rename", systemImage: "pencil") }
        Button { moveTarget = item } label: { Label("Move to Folder", systemImage: "folder") }
        Button { Task { await share(item) } } label: { Label("Share", systemImage: "square.and.arrow.up") }
        Button { Task { await archive(item) } } label: { Label("Archive", systemImage: "archivebox") }
        Button(role: .destructive) { Task { await trash(item) } } label: { Label("Delete", systemImage: "trash") }
    }

    // MARK: Data

    private func load() async {
        do {
            let store = try await VaultService.shared.vaultStore()
            let all = try await store.liveFiles(side: side)
            items = all.filter { $0.folderID == folder?.id }
            if isRoot {
                folders = try await store.folders(side: side)
                archiveCount = try await store.archiveCount(side: side)
                trashCount = try await store.recentlyDeletedCount(side: side)
            }
        } catch { /* keep the grid resilient */ }
    }

    private func archive(_ item: VaultFileSnapshot) async {
        try? await VaultService.shared.vaultStore().archive(id: item.id); await load()
    }
    private func trash(_ item: VaultFileSnapshot) async {
        try? await VaultService.shared.vaultStore().trash(id: item.id); await load()
    }
    private func move(_ item: VaultFileSnapshot, to folderID: UUID?) async {
        try? await VaultService.shared.vaultStore().move(id: item.id, toFolder: folderID)
        moveTarget = nil; await load()
    }
    // MARK: Batch

    private func exitSelection() { isSelecting = false; selectedIDs = [] }

    private func batchDelete() async {
        guard let store = try? await VaultService.shared.vaultStore() else { return }
        for id in selectedIDs { try? await store.trash(id: id) }
        exitSelection(); await load()
    }
    private func batchArchive() async {
        guard let store = try? await VaultService.shared.vaultStore() else { return }
        for id in selectedIDs { try? await store.archive(id: id) }
        exitSelection(); await load()
    }
    private func batchSetHidden(_ hidden: Bool) async {
        guard let store = try? await VaultService.shared.vaultStore() else { return }
        for id in selectedIDs { try? await store.setHidden(id: id, hidden) }
        exitSelection(); await load()
    }
    private func batchMove(to folderID: UUID?) async {
        guard let store = try? await VaultService.shared.vaultStore() else { return }
        for id in selectedIDs { try? await store.move(id: id, toFolder: folderID) }
        showBatchMove = false; exitSelection(); await load()
    }

    private func share(_ item: VaultFileSnapshot) async {
        // Decrypt to the short-lived preview cache for the share sheet.
        if let url = try? await VaultService.shared.decryptToPreviewCache(id: item.id, name: item.name, side: side) {
            sharePayload = SharePayload(url: url)
        }
    }
    private func commitRename(target: VaultFileSnapshot, newName: String) async {
        renameTarget = nil
        guard !newName.isEmpty else { return }
        try? await VaultService.shared.vaultStore().rename(id: target.id, to: newName); await load()
    }
    private func commitFolderRename(target: VaultFolderSnapshot, newName: String) async {
        folderRenameTarget = nil
        guard !newName.isEmpty else { return }
        try? await VaultService.shared.vaultStore().renameFolder(id: target.id, to: newName); await load()
    }
    private func deleteFolder(_ target: VaultFolderSnapshot) async {
        folderDeleteTarget = nil
        try? await VaultService.shared.vaultStore().deleteFolder(id: target.id); await load()
    }
    private func createFolder() async {
        let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        newFolderName = ""
        guard !name.isEmpty else { return }
        _ = try? await VaultService.shared.vaultStore().createFolder(name: name, colorIndex: Int.random(in: 0..<10), side: side)
        await load()
    }
    private func importPhotos(_ picks: [PhotosPickerItem]) async {
        for pick in picks {
            if let data = try? await pick.loadTransferable(type: Data.self) {
                let name = "Photo-\(Int(Date().timeIntervalSince1970)).jpg"
                _ = try? await VaultService.shared.importData(data, name: name, mimeType: "image/jpeg",
                                                              folderID: folder?.id, side: side)
            }
        }
        photoPicks = []; await load()
    }
    private func importFiles(_ result: Result<[URL], Error>) async {
        guard case let .success(urls) = result else { return }
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { continue }
            let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            _ = try? await VaultService.shared.importData(data, name: url.lastPathComponent, mimeType: mime,
                                                          folderID: folder?.id, side: side)
        }
        await load()
    }
}

/// Grid tile density — the "different grid view options".
enum GridDensity: String, CaseIterable, Hashable {
    case compact, comfortable, large
    var minimum: CGFloat {
        switch self { case .compact: return 78; case .comfortable: return 108; case .large: return 156 }
    }
    var title: String {
        switch self { case .compact: return "Compact"; case .comfortable: return "Comfortable"; case .large: return "Large" }
    }
    var symbol: String {
        switch self {
        case .compact: return "square.grid.4x3.fill"
        case .comfortable: return "square.grid.3x3.fill"
        case .large: return "square.grid.2x2.fill"
        }
    }
}

/// Wraps a decrypted temp URL so it can drive a share `.sheet(item:)`.
private struct SharePayload: Identifiable {
    let id = UUID()
    let url: URL
}

private struct FileShareSheet: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Image(systemName: "square.and.arrow.up").font(.system(size: 44)).foregroundStyle(.secondary)
                Text(url.lastPathComponent).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
                    .buttonStyle(.borderedProminent)
            }
            .padding()
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
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
                Button { onPick(nil); dismiss() } label: {
                    HStack { Text("No Folder"); Spacer(); if currentFolder == nil { Image(systemName: "checkmark") } }
                }
                ForEach(folders) { folder in
                    Button { onPick(folder.id); dismiss() } label: {
                        HStack { Text(folder.name); Spacer(); if currentFolder == folder.id { Image(systemName: "checkmark") } }
                    }
                }
            }
            .navigationTitle("Move to Folder")
        }
    }
}
