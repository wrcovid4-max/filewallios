import SwiftUI
#if os(iOS)
import PencilKit
import UIKit

/// A full-screen PencilKit markup editor for a decrypted photo. The user draws /
/// annotates with the standard tool picker (pen, highlighter, eraser, ruler),
/// then **Save** flattens the drawing onto the image and hands the PNG bytes back
/// so the caller can store it as a new vault item. Nothing is written to disk here
/// — the base image is plaintext held in memory, and the composite is passed as
/// `Data` for the caller to encrypt.
struct MarkupView: View {
    let baseImage: UIImage
    let onSave: (Data) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var canvasView = PKCanvasView()
    @State private var container: UIView?

    var body: some View {
        NavigationStack {
            MarkupCanvas(image: baseImage, canvasView: canvasView, container: $container)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Markup")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .primaryAction) {
                        Button("Undo") { canvasView.undoManager?.undo() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            if let data = flatten() { onSave(data) }
                            dismiss()
                        }
                    }
                }
        }
    }

    /// Snapshot exactly what's on screen (image + drawing, as laid out) to a PNG.
    /// Capturing the composed view hierarchy keeps the annotation aligned with the
    /// aspect-fit image without any coordinate-space math.
    private func flatten() -> Data? {
        guard let container else { return nil }
        let renderer = UIGraphicsImageRenderer(bounds: container.bounds)
        let image = renderer.image { _ in
            container.drawHierarchy(in: container.bounds, afterScreenUpdates: true)
        }
        return image.pngData()
    }
}

/// Hosts a `UIImageView` (aspect-fit) with a transparent `PKCanvasView` on top and
/// wires up the floating `PKToolPicker`. Publishes the composed container back so
/// the parent can flatten it on Save.
private struct MarkupCanvas: UIViewRepresentable {
    let image: UIImage
    let canvasView: PKCanvasView
    @Binding var container: UIView?

    func makeUIView(context: Context) -> UIView {
        let root = UIView()
        root.backgroundColor = .systemBackground

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false

        canvasView.translatesAutoresizingMaskIntoConstraints = false
        canvasView.backgroundColor = .clear
        canvasView.isOpaque = false
        canvasView.drawingPolicy = .anyInput          // finger or Apple Pencil

        root.addSubview(imageView)
        root.addSubview(canvasView)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: root.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            canvasView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            canvasView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            canvasView.topAnchor.constraint(equalTo: root.topAnchor),
            canvasView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        let toolPicker = context.coordinator.toolPicker
        toolPicker.setVisible(true, forFirstResponder: canvasView)
        toolPicker.addObserver(canvasView)

        DispatchQueue.main.async {
            canvasView.becomeFirstResponder()
            container = root
        }
        return root
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        let toolPicker = PKToolPicker()
    }
}
#endif
