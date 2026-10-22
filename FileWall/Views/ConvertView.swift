import SwiftUI
import PDFKit

/// Converts text and PDF files on the device, free, with no internet. Results are shared
/// through the iPad's share sheet, so they can be saved to Files or sent anywhere.
struct ConvertView: View {
    let sourceURL: URL

    @Environment(\.dismiss) private var dismiss
    @State private var outputs: [URL] = []
    @State private var message = ""

    private var isPDF: Bool { sourceURL.pathExtension.lowercased() == "pdf" }

    var body: some View {
        NavigationView {
            List {
                Section("Convert \(sourceURL.lastPathComponent)") {
                    if isPDF {
                        Button("Extract text (.txt)") { run(textFromPDF) }
                    } else {
                        Button("Make a PDF") { run(pdfFromText) }
                        Button("Clean up text (.txt)") { run(cleanText) }
                    }
                }
                if !outputs.isEmpty {
                    Section("Ready to share") {
                        ForEach(outputs, id: \.self) { url in
                            ShareLink(item: url) {
                                Label(url.lastPathComponent, systemImage: "square.and.arrow.up")
                            }
                        }
                    }
                }
                if !message.isEmpty {
                    Section { Text(message).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("Convert")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private func run(_ work: (URL) throws -> URL) {
        do {
            outputs.insert(try work(sourceURL), at: 0)
            message = "Done. Tap a file above to save or send it."
        } catch {
            message = "Could not convert this file: \(error.localizedDescription)"
        }
    }

    private func textFromPDF(_ url: URL) throws -> URL {
        guard let document = PDFDocument(url: url) else { throw ConvertError.unreadable }
        let out = tempURL(ext: "txt")
        try (document.string ?? "").write(to: out, atomically: true, encoding: .utf8)
        return out
    }

    private func pdfFromText(_ url: URL) throws -> URL {
        let text = try readText(url)
        let out = tempURL(ext: "pdf")
        let page = CGRect(x: 0, y: 0, width: 612, height: 792)
        let body = page.insetBy(dx: 48, dy: 56)
        let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 12)]
        let renderer = UIGraphicsPDFRenderer(bounds: page)
        // Roughly one page of characters per PDF page; each page wraps its own text.
        let chunks = stride(from: 0, to: text.count, by: 3000).map { start in
            String(text.dropFirst(start).prefix(3000))
        }
        try renderer.writePDF(to: out) { context in
            for chunk in (chunks.isEmpty ? [""] : chunks) {
                context.beginPage()
                (chunk as NSString).draw(in: body, withAttributes: attributes)
            }
        }
        return out
    }

    private func cleanText(_ url: URL) throws -> URL {
        let text = try readText(url)
        let cleaned = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        let out = tempURL(ext: "txt")
        try cleaned.write(to: out, atomically: true, encoding: .utf8)
        return out
    }

    private func readText(_ url: URL) throws -> String {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { throw ConvertError.unreadable }
        return text
    }

    private func tempURL(ext: String) -> URL {
        let base = sourceURL.deletingPathExtension().lastPathComponent
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(base) (converted).\(ext)")
    }
}

enum ConvertError: LocalizedError {
    case unreadable
    var errorDescription: String? { "This file cannot be read as text or PDF." }
}
