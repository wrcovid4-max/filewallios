import SwiftUI
import FileWallKit
#if os(iOS)
import PDFKit
#endif

/// A grid tile: a decrypted thumbnail for photos (plaintext held in memory only,
/// never written to disk), a rendered first-page cover for PDFs when "Document
/// Previews" is on, or a category glyph otherwise. The name sits over a scrim.
struct FileTile: View {
    let item: VaultFileSnapshot
    let side: VaultSideSelector

    @AppStorage(Pref.documentPreviews) private var documentPreviews = Pref.defaultDocumentPreviews
    @State private var thumbnail: Image?

    var body: some View {
        // A flexible base pinned to a 1:1 square by the grid column width. The
        // image and name are overlays clipped to that square, so a wide photo
        // fills its own tile and never bleeds into neighbours.
        Color.secondary.opacity(0.12)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let thumbnail {
                    thumbnail.resizable().scaledToFill()
                } else {
                    Image(systemName: glyph)
                        .font(.system(size: 30))
                        .foregroundStyle(.secondary)
                }
            }
            .overlay(alignment: .bottom) {
                Text(item.name)
                    .font(.caption2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        LinearGradient(colors: [.black.opacity(0), .black.opacity(0.6)],
                                       startPoint: .top, endPoint: .bottom)
                    )
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
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
        guard thumbnail == nil else { return }
        switch item.category {
        case .photo:
            if let data = try? await VaultService.shared.decryptedData(for: item.id, side: side),
               let image = Image(vaultData: data) {
                thumbnail = image
            }
        case .document:
            #if os(iOS)
            // Only PDFs can be rendered to a cover, and only when the user opted in
            // (a document cover is decrypted vault content shown on a tile).
            guard documentPreviews, item.mimeType == "application/pdf" else { return }
            if let data = try? await VaultService.shared.decryptedData(for: item.id, side: side),
               let cover = pdfCover(data) {
                thumbnail = cover
            }
            #endif
        default:
            break
        }
    }

    #if os(iOS)
    private func pdfCover(_ data: Data) -> Image? {
        guard let document = PDFDocument(data: data), let page = document.page(at: 0) else { return nil }
        let image = page.thumbnail(of: CGSize(width: 240, height: 240), for: .mediaBox)
        return Image(uiImage: image)
    }
    #endif
}
