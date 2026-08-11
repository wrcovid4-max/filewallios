import Foundation

/// The data contract between the phone and the watch over `WCSession`.
///
/// # The watch is a viewfinder, not a second vault
///
/// Nothing is pushed speculatively — the watch *asks*, the phone *answers*, so a
/// watch out of range costs nothing. And the phone only ever answers with **live,
/// non-hidden** items: a hidden item is never described in a manifest, never has
/// its bytes served, and therefore a lost watch cannot even ask for one. Trashed
/// and archived items are excluded too. That filtering happens on the phone
/// (`VaultService` queries the standard side, live only) — the watch simply can't
/// name anything it wasn't told about.

/// Keys and values for the small `WCSession` message dictionaries. Message values
/// must be property-list types, so structured payloads travel as JSON `Data`.
public enum WatchMessage {
    public static let requestKey = "req"

    public static let manifest = "manifest"   // watch → phone: "send me the list"
    public static let image = "image"         // watch → phone: "send this photo's bytes"
    public static let openOnPhone = "open"     // watch → phone: "surface this on the phone"

    public static let idKey = "id"            // uuid string, for image/open
    public static let payloadKey = "payload"  // reply: JSON or JPEG Data
    public static let errorKey = "error"      // reply: human-readable failure
    public static let okKey = "ok"            // reply: Bool ack
}

/// One item as the watch sees it. Deliberately thin: no folder, no blob, no key —
/// just enough to render a grid and request a photo. Photos are viewable on the
/// watch; video and documents show a placeholder plus "Open on iPhone".
public struct WatchVaultItem: Codable, Sendable, Identifiable, Equatable, Hashable {
    public let id: UUID
    public let name: String
    public let category: VaultCategory
    public let byteSize: Int64

    public init(id: UUID, name: String, category: VaultCategory, byteSize: Int64) {
        self.id = id
        self.name = name
        self.category = category
        self.byteSize = byteSize
    }

    /// Only photos can be shown on the watch; everything else routes to the phone.
    public var isViewableOnWatch: Bool { category == .photo }
}

/// The manifest the phone sends in answer to a `manifest` request: the live,
/// non-hidden items plus the vault's size for the complication.
public struct WatchVaultManifest: Codable, Sendable, Equatable {
    public let items: [WatchVaultItem]
    public let totalBytes: Int64

    public init(items: [WatchVaultItem], totalBytes: Int64) {
        self.items = items
        self.totalBytes = totalBytes
    }

    public var itemCount: Int { items.count }

    // JSON is the wire form (WCSession values are plist types, so we send Data).
    public func encoded() throws -> Data { try JSONEncoder().encode(self) }
    public static func decode(_ data: Data) throws -> WatchVaultManifest {
        try JSONDecoder().decode(WatchVaultManifest.self, from: data)
    }
}
