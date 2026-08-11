import SwiftUI
import FileWallKit

/// A grid tile: a decrypted thumbnail for photos (plaintext held in memory only,
/// never written to disk), or a category glyph for everything else, with the name
/// over a scrim at the bottom.
struct FileTile: View {
    let item: VaultFileSnapshot
    let side: VaultSideSelector

    @State private var thumbnail: Image?

    var body: some View {
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.15))

            if let thumbnail {
                thumbnail
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: glyph)
                    .font(.title)
                    .foregroundStyle(.secondary)
            }

            Text(item.name)
                .font(.caption2)
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.ultraThinMaterial)
        }
        .frame(height: 110)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .task { await loadThumbnail() }
    }

    private var glyph: String {
        switch item.category {
        case .photo: return "photo"
        case .video: return "film"
        case .document: return "doc.text"
        case .other: return "doc"
        }
    }

    private func loadThumbnail() async {
        guard item.category == .photo, thumbnail == nil else { return }
        if let data = try? await VaultService.shared.decryptedData(for: item.id, side: side),
           let image = Image(vaultData: data) {
            thumbnail = image
        }
    }
}
