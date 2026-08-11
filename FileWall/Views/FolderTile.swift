import SwiftUI
import FileWallKit

/// A macOS-style folder tile: a tinted blue folder glyph, or — when the folder
/// holds a photo — that newest photo as a cover, with the folder's name and live
/// item count. Tapping opens the folder; long-press gives Rename / Delete.
struct FolderTile: View {
    let folder: VaultFolderSnapshot
    let side: VaultSideSelector

    @State private var cover: Image?

    private var color: Color { FolderPalette.color(folder.colorIndex) }

    var body: some View {
        // Square base; the folder glyph (or cover) fills it CENTERED, and the
        // name sits in a bottom bar as an overlay so the two never collide.
        color.opacity(0.18)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let cover {
                    cover.resizable().scaledToFill()
                } else {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 46))
                        .foregroundStyle(color)
                }
            }
            .overlay(alignment: .bottom) {
                HStack(spacing: 4) {
                    Image(systemName: "folder.fill").font(.caption2)
                    Text(folder.name).font(.caption).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 2)
                    Text("\(folder.liveItemCount)").font(.caption2.weight(.semibold))
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity)
                .foregroundStyle(cover == nil ? Color.primary : .white)
                .background(
                    cover == nil
                        ? AnyShapeStyle(.ultraThinMaterial)
                        : AnyShapeStyle(LinearGradient(colors: [.black.opacity(0), .black.opacity(0.65)],
                                                       startPoint: .top, endPoint: .bottom))
                )
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .task { await loadCover() }
    }

    private func loadCover() async {
        guard cover == nil else { return }
        guard let files = try? await VaultService.shared.vaultStore().liveFiles(inFolder: folder.id, side: side),
              let newestPhoto = files.first(where: { $0.category == .photo }) else { return }
        if let data = try? await VaultService.shared.decryptedData(for: newestPhoto.id, side: side),
           let image = Image(vaultData: data) {
            cover = image
        }
    }
}

/// A small palette so folders can be visually distinct, indexed by `colorIndex`
/// (which round-trips through the cross-platform backup).
enum FolderPalette {
    static let colors: [Color] = [.blue, .indigo, .purple, .pink, .red, .orange, .yellow, .green, .teal, .cyan]
    static func color(_ index: Int) -> Color {
        colors[((index % colors.count) + colors.count) % colors.count]
    }
}
