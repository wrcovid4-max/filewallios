import SwiftUI
import PDFKit

/// Opens a PDF at one page, for "Open page N" in Ask AI answers.
struct PDFPageViewer: View {
    let url: URL
    let page: Int

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            PDFKitPage(url: url, page: page)
                .navigationTitle("Page \(page)")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                }
        }
    }
}

private struct PDFKitPage: UIViewRepresentable {
    let url: URL
    let page: Int

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.document = PDFDocument(url: url)
        if let target = view.document?.page(at: max(page - 1, 0)) {
            view.go(to: target)
        }
        return view
    }

    func updateUIView(_ uiView: PDFView, context: Context) {}
}
