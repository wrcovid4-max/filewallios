import SwiftUI
import FileWallKit

/// The Archive and Recently Deleted destinations. Same screen, different actions:
/// archived items can be unarchived / deleted; trashed items can be restored or
/// permanently erased (with confirmation), and the whole trash can be emptied.
/// Neither shows the import button.
struct StateListView: View {
    let side: VaultSideSelector
    let state: LifecycleFilter   // .archived or .trashed

    @State private var items: [VaultFileSnapshot] = []
    @State private var confirmDeleteForever: VaultFileSnapshot?
    @State private var confirmEmpty = false

    var body: some View {
        List {
            ForEach(items) { item in
                row(item)
                    .contextMenu { actions(for: item) }
            }
            if items.isEmpty {
                Text(state == .trashed ? "Nothing in Recently Deleted." : "Nothing archived.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(state == .trashed ? "Recently Deleted" : "Archive")
        .toolbar {
            if state == .trashed && !items.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button("Empty", role: .destructive) { confirmEmpty = true }
                }
            }
        }
        .task { await load() }
        .confirmationDialog("Delete Forever?", isPresented: Binding(
            get: { confirmDeleteForever != nil },
            set: { if !$0 { confirmDeleteForever = nil } })) {
            Button("Delete Forever", role: .destructive) { Task { await deleteForever() } }
            Button("Cancel", role: .cancel) { confirmDeleteForever = nil }
        } message: {
            Text("This can’t be undone.")
        }
        .confirmationDialog("Empty Recently Deleted?", isPresented: $confirmEmpty) {
            Button("Empty", role: .destructive) { Task { await empty() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Permanently erase everything in Recently Deleted for this vault.")
        }
    }

    private func row(_ item: VaultFileSnapshot) -> some View {
        HStack {
            Image(systemName: glyph(item))
            VStack(alignment: .leading) {
                Text(item.name).lineLimit(1)
                if case let .trashed(purge) = item.state {
                    Text("Auto-deletes \(purge.formatted(.relative(presentation: .named)))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(ByteCountFormatter.string(fromByteCount: item.byteSize, countStyle: .file))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func actions(for item: VaultFileSnapshot) -> some View {
        if state == .trashed {
            Button { Task { await restore(item) } } label: { Label("Restore", systemImage: "arrow.uturn.backward") }
            Button(role: .destructive) { confirmDeleteForever = item } label: { Label("Delete Forever", systemImage: "trash.slash") }
        } else {
            Button { Task { await unarchive(item) } } label: { Label("Remove from Archive", systemImage: "arrow.up.bin") }
            Button(role: .destructive) { Task { await trash(item) } } label: { Label("Delete", systemImage: "trash") }
        }
    }

    private func glyph(_ item: VaultFileSnapshot) -> String {
        switch item.category {
        case .photo: return "photo"; case .video: return "film"
        case .document: return "doc.text"; case .other: return "doc"
        }
    }

    // MARK: Data

    private func load() async {
        guard let store = try? await VaultService.shared.vaultStore() else { return }
        if state == .trashed {
            items = (try? await store.recentlyDeletedFiles(side: side)) ?? []
        } else {
            items = (try? await store.archivedFiles(side: side)) ?? []
        }
    }

    private func restore(_ item: VaultFileSnapshot) async {
        try? await VaultService.shared.vaultStore().restore(id: item.id); await load()
    }
    private func unarchive(_ item: VaultFileSnapshot) async {
        try? await VaultService.shared.vaultStore().unarchive(id: item.id); await load()
    }
    private func trash(_ item: VaultFileSnapshot) async {
        try? await VaultService.shared.vaultStore().trash(id: item.id); await load()
    }
    private func deleteForever() async {
        guard let item = confirmDeleteForever else { return }
        confirmDeleteForever = nil
        try? await VaultService.shared.vaultStore().deleteForever(id: item.id); await load()
    }
    private func empty() async {
        _ = try? await VaultService.shared.vaultStore().emptyRecentlyDeleted(side: side); await load()
    }
}
