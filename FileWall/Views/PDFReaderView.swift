import SwiftUI
import PDFKit
import AVFoundation

/// The iPad/iPhone PDF reader: page box, single / two-page / continuous layouts, full screen,
/// read aloud, highlight with undo, and saving a marked copy back into the vault.
struct PDFReaderView: View {
    let url: URL
    let item: VaultFileSnapshot
    let side: VaultSideSelector

    @State private var document: PDFDocument?
    @State private var layout = 0            // 0 single page, 1 two-up, 2 continuous
    @State private var currentPage = 1
    @State private var pageField = ""
    @State private var chromeHidden = false
    @State private var highlights: [(PDFPage, PDFAnnotation)] = []
    @State private var status = ""
    @StateObject private var holder = PDFHolder()
    @StateObject private var voice = ReadAloud()

    var body: some View {
        Group {
            if let document {
                PDFKitRepresentable(document: document, layout: layout, page: $currentPage, holder: holder)
                    .ignoresSafeArea(edges: chromeHidden ? .all : [])
            } else {
                ProgressView()
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !chromeHidden { pageBar }
        }
        .toolbar(chromeHidden ? .hidden : .visible, for: .navigationBar)
        .statusBarHidden(chromeHidden)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Picker("Layout", selection: $layout) {
                        Text("Single page").tag(0)
                        Text("Two pages").tag(1)
                        Text("Continuous").tag(2)
                    }
                } label: { Image(systemName: "rectangle.split.2x1") }
                Button { toggleReadAloud() } label: {
                    Image(systemName: voice.synth.isSpeaking ? "speaker.slash" : "speaker.wave.2")
                }
                Button { highlightSelection() } label: { Image(systemName: "highlighter") }
                Button { undoHighlight() } label: { Image(systemName: "arrow.uturn.backward") }
                    .disabled(highlights.isEmpty)
                Button { Task { await saveMarkedCopy() } } label: { Image(systemName: "square.and.arrow.down") }
                Button { chromeHidden.toggle() } label: {
                    Image(systemName: chromeHidden ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                }
            }
        }
        .onAppear {
            if document == nil { document = PDFDocument(url: url) }
            pageField = "\(currentPage)"
        }
        .onChange(of: currentPage) { pageField = "\($0)" }
        .overlay(alignment: .bottom) {
            if !status.isEmpty {
                Text(status)
                    .font(.footnote)
                    .padding(8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 60)
            }
        }
    }

    private var pageBar: some View {
        HStack {
            Text("Page")
            TextField("Page", text: $pageField, onCommit: goToPage)
                .keyboardType(.numberPad)
                .textFieldStyle(.roundedBorder)
                .frame(width: 70)
            Text("of \(document?.pageCount ?? 0)").foregroundStyle(.secondary)
            Spacer()
            Button { move(by: -1) } label: { Image(systemName: "chevron.up") }
            Button { move(by: 1) } label: { Image(systemName: "chevron.down") }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func goToPage() {
        guard let number = Int(pageField), let count = document?.pageCount, count > 0 else { return }
        currentPage = min(max(number, 1), count)
    }

    private func move(by delta: Int) {
        let count = document?.pageCount ?? 0
        currentPage = min(max(currentPage + delta, 1), max(count, 1))
    }

    private func toggleReadAloud() {
        if voice.synth.isSpeaking {
            voice.stop()
        } else {
            voice.speak(document?.page(at: currentPage - 1)?.string ?? "")
        }
    }

    private func highlightSelection() {
        guard let selection = holder.view?.currentSelection else {
            flash("Select some text first.")
            return
        }
        for page in selection.pages {
            let annotation = PDFAnnotation(bounds: selection.bounds(for: page), forType: .highlight, withProperties: nil)
            annotation.color = UIColor.yellow.withAlphaComponent(0.5)
            page.addAnnotation(annotation)
            highlights.append((page, annotation))
        }
        holder.view?.clearSelection()
    }

    private func undoHighlight() {
        guard let last = highlights.popLast() else { return }
        last.0.removeAnnotation(last.1)
    }

    /// Writes the document with its highlights into the vault as a new "(marked)" file.
    private func saveMarkedCopy() async {
        guard let document else { return }
        let base = (item.name as NSString).deletingPathExtension
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).pdf")
        guard document.write(to: out), let data = try? Data(contentsOf: out) else {
            flash("Could not save the marked copy.")
            return
        }
        _ = try? await VaultService.shared.importData(data, name: "\(base) (marked).pdf",
                                                      mimeType: "application/pdf",
                                                      folderID: item.folderID, side: side)
        try? FileManager.default.removeItem(at: out)
        flash("Saved a marked copy to the vault.")
    }

    private func flash(_ message: String) {
        status = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { if status == message { status = "" } }
    }
}

/// Holds the live PDFView so toolbar actions can read its selection.
final class PDFHolder: ObservableObject {
    weak var view: PDFView?
}

/// Reads text aloud with the system voice.
final class ReadAloud: ObservableObject {
    let synth = AVSpeechSynthesizer()
    func speak(_ text: String) {
        synth.stopSpeaking(at: .immediate)
        guard !text.isEmpty else { return }
        synth.speak(AVSpeechUtterance(string: text))
    }
    func stop() { synth.stopSpeaking(at: .immediate) }
}

private struct PDFKitRepresentable: UIViewRepresentable {
    let document: PDFDocument
    let layout: Int
    @Binding var page: Int
    let holder: PDFHolder

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.document = document
        holder.view = view
        NotificationCenter.default.addObserver(context.coordinator,
                                               selector: #selector(Coordinator.pageChanged(_:)),
                                               name: .PDFViewPageChanged, object: view)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        context.coordinator.parent = self
        view.displayMode = layout == 1 ? .twoUp : (layout == 2 ? .singlePageContinuous : .singlePage)
        if let target = document.page(at: max(page - 1, 0)), view.currentPage != target,
           context.coordinator.lastRequested != page {
            view.go(to: target)
            context.coordinator.lastRequested = page
        }
    }

    final class Coordinator: NSObject {
        var parent: PDFKitRepresentable
        var lastRequested = -1
        init(parent: PDFKitRepresentable) { self.parent = parent }

        @objc func pageChanged(_ note: Notification) {
            guard let view = note.object as? PDFView, let doc = view.document,
                  let current = view.currentPage else { return }
            let index = doc.index(for: current) + 1
            if index != parent.page {
                parent.page = index
                lastRequested = index
            }
        }
    }
}
