import Foundation
import FileWallKit

#if os(iOS)
import WatchConnectivity
import ImageIO
import UserNotifications

/// The phone's side of the watch link. The watch asks; this answers — nothing is
/// pushed. Every answer is scoped to **live, non-hidden** items, so a hidden or
/// trashed item is never named in a manifest, never served as bytes, and cannot
/// be requested by a lost watch.
final class PhoneWatchSession: NSObject, WCSessionDelegate {
    static let shared = PhoneWatchSession()

    /// Call once at app launch. No-op on platforms/devices without a paired watch.
    static func activateSession() { shared.activate() }

    private func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    // MARK: WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {}
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { session.activate() } // re-activate for a new watch

    func session(_ session: WCSession,
                 didReceiveMessage message: [String: Any],
                 replyHandler: @escaping ([String: Any]) -> Void) {
        switch message[WatchMessage.requestKey] as? String {

        case WatchMessage.manifest:
            Task {
                do {
                    let items = try await VaultService.shared.watchLiveItems().map {
                        WatchVaultItem(id: $0.id, name: $0.name, category: $0.category, byteSize: $0.byteSize)
                    }
                    let total = try await VaultService.shared.watchTotalBytes()
                    let manifest = WatchVaultManifest(items: items, totalBytes: total)
                    replyHandler([WatchMessage.payloadKey: try manifest.encoded()])
                } catch {
                    replyHandler([WatchMessage.errorKey: error.localizedDescription])
                }
            }

        case WatchMessage.image:
            guard let idString = message[WatchMessage.idKey] as? String,
                  let id = UUID(uuidString: idString) else {
                replyHandler([WatchMessage.errorKey: "Bad id"]); return
            }
            Task {
                do {
                    if let data = try await VaultService.shared.watchThumbnailData(id: id) {
                        replyHandler([WatchMessage.payloadKey: data])
                    } else {
                        // nil == not a live, non-hidden photo → refuse without detail.
                        replyHandler([WatchMessage.errorKey: "Not available on the watch"])
                    }
                } catch {
                    replyHandler([WatchMessage.errorKey: error.localizedDescription])
                }
            }

        case WatchMessage.openOnPhone:
            let name = (message["name"] as? String) ?? "a file"
            Self.postOpenNotification(name: name)
            replyHandler([WatchMessage.okKey: true])

        default:
            replyHandler([WatchMessage.errorKey: "Unknown request"])
        }
    }

    /// A local notification nudging the user to open the item on the phone. This is
    /// the "Open on iPhone" affordance for video/documents — the watch never
    /// receives their bytes, it just asks the phone to surface them.
    private static func postOpenNotification(name: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Open in FileWall"
            content.body = "Tap to view “\(name)” on your iPhone."
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            center.add(request)
        }
    }
}

// MARK: - Watch data, served from the standard side only

extension VaultService {

    /// Live, non-hidden items for the watch manifest. `find` queries the standard
    /// side with `states: [.live]`, so hidden/archived/trashed can't appear.
    func watchLiveItems() async throws -> [VaultFileSnapshot] {
        try await find(states: [.live], matching: nil,
                       sort: [NSSortDescriptor(key: "dateAdded", ascending: false)], limit: nil)
    }

    func watchTotalBytes() async throws -> Int64 {
        try await vaultStore().storageBreakdown(side: .standard).totalBytes
    }

    /// A downsampled JPEG for a photo, or nil if the id is not a live, non-hidden
    /// photo — the guard is what keeps the watch from ever pulling hidden, trashed,
    /// or non-image content.
    func watchThumbnailData(id: UUID, maxPixel: Int = 500) async throws -> Data? {
        let store = try await vaultStore()
        let matches = try await store.snapshots(forIDs: [id], side: .standard) // standard side ⇒ never hidden
        guard let item = matches.first, item.state == .live, item.category == .photo else { return nil }

        let key = try await keyStore.vaultKey(for: .standard)
        let blobURL = AppEnvironment.vaultDirectory.appendingPathComponent(id.uuidString)
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("watch-\(id.uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        try await ChunkedCipher().decryptFile(at: blobURL, to: temp, using: key)

        return WatchImageDownsampler.jpeg(from: temp, maxPixel: maxPixel)
    }
}

/// Downsamples an image file to a small JPEG via ImageIO — no full-size decode,
/// bounded memory, and it never writes plaintext anywhere but the temp file the
/// caller already wipes.
enum WatchImageDownsampler {
    static func jpeg(from url: URL, maxPixel: Int) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, thumbnail, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}

#else

/// macOS has no WatchConnectivity (Macs don't pair with a watch). No-op so the
/// app launch code stays cross-platform.
enum PhoneWatchSession { static func activateSession() {} }

#endif
