import SwiftUI
import FileWallKit

/// Grid placeholder for documents: the first lines of a Word or text file, on white.
struct DocPreviewGlyph: View {
    let item: VaultFileSnapshot
    let side: VaultSideSelector
    let fallback: String

    @State private var lines: [String] = []

    private static let textExtensions: Set<String> = ["txt", "md", "csv", "log", "json", "xml", "html", "htm", "docx"]
    private var ext: String { (item.name as NSString).pathExtension.lowercased() }

    var body: some View {
        Group {
            if lines.isEmpty {
                Image(systemName: fallback)
                    .font(.system(size: 30))
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(size: 7)).foregroundStyle(Color.black.opacity(0.75)).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color.white)
            }
        }
        .task { await load() }
    }

    private func load() async {
        guard Self.textExtensions.contains(ext),
              let url = try? await VaultService.shared.decryptToPreviewCache(id: item.id, name: item.name, side: side)
        else { return }
        let text: String
        if ext == "docx" {
            text = (try? ZipExtract.docxText(Data(contentsOf: url))) ?? ""
        } else {
            text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }
        lines = Array(text.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .prefix(14))
    }
}
