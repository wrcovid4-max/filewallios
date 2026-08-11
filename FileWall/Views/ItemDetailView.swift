import SwiftUI
import FileWallKit
#if os(iOS)
import QuickLook
import UIKit
#endif

/// Full view of one item. Photos display in-app (zoom with a pinch); other
/// formats open in Quick Look against the short-lived preview cache. Plaintext for
/// images stays in memory; only Quick Look formats touch the cache, and it's wiped
/// on lock/background/launch.
struct ItemDetailView: View {
    let item: VaultFileSnapshot
    let side: VaultSideSelector

    @Environment(\.dismiss) private var dismiss
    @State private var imageData: Data?
    @State private var previewURL: URL?
    @State private var scale: CGFloat = 1
    #if os(iOS)
    @State private var showFullScreen = false
    @State private var showMarkup = false
    #endif

    var body: some View {
        Group {
            if item.category == .photo {
                photoView
            } else {
                otherView
            }
        }
        .navigationTitle(item.name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    #if os(iOS)
                    Button { showFullScreen = true } label: {
                        Label("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right")
                    }
                    .disabled(item.category == .photo ? imageData == nil : previewURL == nil)
                    if item.category == .photo {
                        Button { showMarkup = true } label: {
                            Label("Markup", systemImage: "pencil.tip.crop.circle")
                        }
                        .disabled(imageData == nil)
                    }
                    Divider()
                    #endif
                    if let previewURL {
                        ShareLink("Export a Copy", item: previewURL)
                    }
                    Button(role: .destructive) { Task { await deleteItem() } } label: {
                        Label("Delete", systemImage: "trash")
                    }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .task { await prepare() }
        #if os(iOS)
        .fullScreenCover(isPresented: $showFullScreen) { fullScreenViewer }
        .fullScreenCover(isPresented: $showMarkup) { markupEditor }
        #endif
    }

    #if os(iOS)
    // A borderless, full-screen presentation of the item — the iPad payoff of
    // "Full Screen" when the preview otherwise sits in the split-view detail pane.
    @ViewBuilder
    private var fullScreenViewer: some View {
        NavigationStack {
            Group {
                if item.category == .photo, let imageData, let image = Image(vaultData: imageData) {
                    ZoomableImage(image: image)
                } else if let previewURL {
                    QuickLookView(url: previewURL).ignoresSafeArea()
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(item.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { showFullScreen = false } }
                if item.category == .photo {
                    ToolbarItem(placement: .primaryAction) {
                        Button { showFullScreen = false; showMarkup = true } label: {
                            Label("Markup", systemImage: "pencil.tip.crop.circle")
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var markupEditor: some View {
        if let imageData, let ui = UIImage(data: imageData) {
            MarkupView(baseImage: ui) { data in Task { await saveMarkup(data) } }
        } else {
            // Shouldn't happen (button is disabled until loaded), but stay safe.
            Color.clear.onAppear { showMarkup = false }
        }
    }

    /// Save the annotated image as a *new* vault item, next to the original — markup
    /// never overwrites the source.
    private func saveMarkup(_ data: Data) async {
        let base = (item.name as NSString).deletingPathExtension
        let name = "\(base) markup.png"
        _ = try? await VaultService.shared.importData(data, name: name, mimeType: "image/png",
                                                      folderID: item.folderID, side: side)
    }
    #endif

    @ViewBuilder
    private var photoView: some View {
        if let imageData, let image = Image(vaultData: imageData) {
            image
                .resizable()
                .scaledToFit()
                .scaleEffect(scale)
                .gesture(MagnificationGesture().onChanged { scale = max(1, $0) }.onEnded { _ in
                    withAnimation { scale = max(1, min(scale, 4)) }
                })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.9))
                .ignoresSafeArea(edges: .bottom)
        } else {
            ProgressView()
        }
    }

    private var otherView: some View {
        VStack(spacing: 16) {
            Image(systemName: item.category == .video ? "film" : "doc.text")
                .font(.system(size: 64)).foregroundStyle(.secondary)
            Text(item.name).font(.headline).multilineTextAlignment(.center)
            Text(ByteCountFormatter.string(fromByteCount: item.byteSize, countStyle: .file))
                .foregroundStyle(.secondary)

            #if os(iOS)
            if let previewURL {
                NavigationLink { QuickLookView(url: previewURL) } label: {
                    Label("Open Preview", systemImage: "eye")
                }
                .buttonStyle(.borderedProminent)
            } else {
                ProgressView()
            }
            #endif
        }
        .padding()
    }

    private func prepare() async {
        if item.category == .photo {
            imageData = try? await VaultService.shared.decryptedData(for: item.id, side: side)
        } else {
            // Decrypt to the preview cache for Quick Look / export.
            previewURL = try? await VaultService.shared.decryptToPreviewCache(id: item.id, name: item.name, side: side)
        }
    }

    private func deleteItem() async {
        try? await VaultService.shared.vaultStore().trash(id: item.id)
        dismiss()
    }
}

#if os(iOS)
/// A full-screen, pinch-to-zoom / drag-to-pan image on a black field. Double-tap
/// resets. Used by the "Full Screen" viewer.
struct ZoomableImage: View {
    let image: Image
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        image
            .resizable()
            .scaledToFit()
            .scaleEffect(scale)
            .offset(offset)
            .gesture(
                SimultaneousGesture(
                    MagnificationGesture()
                        .onChanged { scale = max(1, $0) }
                        .onEnded { _ in withAnimation { scale = min(max(scale, 1), 6); if scale == 1 { offset = .zero; lastOffset = .zero } } },
                    DragGesture()
                        .onChanged { g in guard scale > 1 else { return }
                            offset = CGSize(width: lastOffset.width + g.translation.width,
                                            height: lastOffset.height + g.translation.height) }
                        .onEnded { _ in lastOffset = offset }
                )
            )
            .onTapGesture(count: 2) {
                withAnimation { scale = scale > 1 ? 1 : 2; offset = .zero; lastOffset = .zero }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            .ignoresSafeArea()
    }
}

/// Minimal Quick Look host for a single decrypted file in the preview cache.
struct QuickLookView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}
#endif
