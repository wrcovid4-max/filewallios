import SwiftUI
import UIKit          // UIImage lives here on watchOS; SwiftUI doesn't re-export it
import FileWallKit

/// Detail for one item. Photos load on demand and zoom with the Digital Crown.
/// Video and documents never travel to the watch — they show a glyph and an
/// "Open on iPhone" button that nudges the phone.
struct WatchItemDetailView: View {
    let item: WatchVaultItem
    @EnvironmentObject private var client: WatchConnectivityClient

    @State private var imageData: Data?
    @State private var isLoading = true
    @State private var crownZoom = 1.0

    var body: some View {
        Group {
            if item.isViewableOnWatch {
                photoBody
            } else {
                openOnPhoneBody
            }
        }
        .navigationTitle(item.name)
        .task { await load() }
    }

    @ViewBuilder
    private var photoBody: some View {
        if let data = imageData, let image = image(from: data) {
            image
                .resizable()
                .scaledToFit()
                .scaleEffect(crownZoom)
                // Digital Crown zoom (watchOS 9). `focusable` is what lets the
                // crown drive this view rather than scrolling the list.
                .focusable(true)
                .digitalCrownRotation($crownZoom, from: 1.0, through: 4.0, by: 0.05,
                                      sensitivity: .low, isContinuous: false,
                                      isHapticFeedbackEnabled: true)
                .ignoresSafeArea()
        } else if isLoading {
            ProgressView()
        } else {
            VStack(spacing: 6) {
                Image(systemName: "photo").font(.title3)
                Text("Couldn’t load this photo.").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var openOnPhoneBody: some View {
        VStack(spacing: 10) {
            Image(systemName: item.category == .video ? "film" : "doc")
                .font(.system(size: 34))
            Text(item.name).font(.footnote).multilineTextAlignment(.center)
            Button {
                client.requestOpenOnPhone(item)
            } label: {
                Label("Open on iPhone", systemImage: "iphone")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    private func load() async {
        guard item.isViewableOnWatch else { isLoading = false; return }
        imageData = await client.loadImage(id: item.id)
        isLoading = false
    }

    // UIImage is available on watchOS; this is the only decode of the photo, held
    // in memory only while the view is on screen.
    private func image(from data: Data) -> Image? {
        guard let ui = UIImage(data: data) else { return nil }
        return Image(uiImage: ui)
    }
}
