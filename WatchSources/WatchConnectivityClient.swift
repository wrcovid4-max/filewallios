import Foundation
import SwiftUI
import WatchConnectivity
import FileWallKit

/// The watch's side of the link. Request/response only — the watch asks, the
/// phone answers. Nothing is cached to disk; the manifest lives in memory and
/// photos are fetched on demand and held only while on screen.
@MainActor
final class WatchConnectivityClient: NSObject, ObservableObject {
    static let shared = WatchConnectivityClient()

    @Published private(set) var items: [WatchVaultItem] = []
    @Published private(set) var totalBytes: Int64 = 0
    @Published private(set) var isReachable = false
    @Published private(set) var statusMessage: String?

    private override init() {
        super.init()
        activate()
    }

    private func activate() {
        guard WCSession.isSupported() else {
            statusMessage = "This watch can’t connect."
            return
        }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    /// Ask the phone for the current list of live, non-hidden items.
    func refresh() {
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        session.sendMessage([WatchMessage.requestKey: WatchMessage.manifest], replyHandler: { reply in
            if let data = reply[WatchMessage.payloadKey] as? Data,
               let manifest = try? WatchVaultManifest.decode(data) {
                Task { @MainActor in
                    self.items = manifest.items
                    self.totalBytes = manifest.totalBytes
                    self.statusMessage = manifest.items.isEmpty ? "Your vault is empty." : nil
                }
            } else if let error = reply[WatchMessage.errorKey] as? String {
                Task { @MainActor in self.statusMessage = error }
            }
        }, errorHandler: { error in
            Task { @MainActor in self.statusMessage = error.localizedDescription }
        })
    }

    /// Fetch one photo's downsampled bytes. Returns nil if the phone declines
    /// (e.g. it isn't a live, non-hidden photo) or is unreachable.
    func loadImage(id: UUID) async -> Data? {
        await withCheckedContinuation { continuation in
            let session = WCSession.default
            guard session.activationState == .activated, session.isReachable else {
                continuation.resume(returning: nil); return
            }
            session.sendMessage(
                [WatchMessage.requestKey: WatchMessage.image, WatchMessage.idKey: id.uuidString],
                replyHandler: { reply in continuation.resume(returning: reply[WatchMessage.payloadKey] as? Data) },
                errorHandler: { _ in continuation.resume(returning: nil) })
        }
    }

    /// Ask the phone to surface a video/document — the watch never receives their
    /// bytes, it just nudges the phone.
    func requestOpenOnPhone(_ item: WatchVaultItem) {
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        session.sendMessage(
            [WatchMessage.requestKey: WatchMessage.openOnPhone,
             WatchMessage.idKey: item.id.uuidString,
             "name": item.name],
            replyHandler: { _ in }, errorHandler: { _ in })
    }
}

// WatchConnectivity delegate callbacks arrive off the main actor; hop back on.
// watchOS only requires `activationDidCompleteWith` (the inactive/deactivate
// pair is iOS-only).
extension WatchConnectivityClient: WCSessionDelegate {
    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        Task { @MainActor in
            self.isReachable = session.isReachable
            if activationState == .activated { self.refresh() }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.isReachable = session.isReachable
            if session.isReachable { self.refresh() } // catch up when the phone comes back
        }
    }
}
