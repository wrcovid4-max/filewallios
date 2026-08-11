import SwiftUI
import FileWallKit
#if os(iOS)
import QuickLook
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
    }

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
