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
