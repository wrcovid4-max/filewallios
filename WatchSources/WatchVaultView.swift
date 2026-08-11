import SwiftUI
import FileWallKit

/// The watch's main screen: a scrollable list of the vault's live, non-hidden
/// items, with the vault size up top. Tapping a photo opens it; tapping a
/// video/document opens the detail with an "Open on iPhone" button.
struct WatchVaultView: View {
    @EnvironmentObject private var client: WatchConnectivityClient

    var body: some View {
        NavigationStack {
            List {
                if client.totalBytes > 0 {
                    Section {
                        HStack {
                            Image(systemName: "lock.fill")
                            Text(byteText(client.totalBytes))
                            Spacer()
                            Text("\(client.items.count)")
                                .foregroundStyle(.secondary)
                        }
                        .font(.footnote)
                    }
                }

                ForEach(client.items) { item in
                    NavigationLink(value: item) {
                        WatchItemRow(item: item)
                    }
                }

                if client.items.isEmpty {
                    Text(client.statusMessage ?? "Open FileWall on your iPhone to sync.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("FileWall")
            .navigationDestination(for: WatchVaultItem.self) { item in
                WatchItemDetailView(item: item)
            }
        }
        .onAppear { client.refresh() }
    }

    private func byteText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// One row: category glyph, name, size.
struct WatchItemRow: View {
    let item: WatchVaultItem

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: glyph)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).font(.body).lineLimit(1)
                Text(ByteCountFormatter.string(fromByteCount: item.byteSize, countStyle: .file))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var glyph: String {
        switch item.category {
        case .photo: return "photo"
        case .video: return "film"
        case .document: return "doc"
        case .other: return "questionmark.square.dashed"
        }
    }
}
