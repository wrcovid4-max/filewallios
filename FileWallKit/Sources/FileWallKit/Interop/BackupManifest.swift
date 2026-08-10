import Foundation

/// One folder in a backup manifest. Fields and types match Android's
/// `manifest.json` exactly (see BACKUP_FORMAT.md): times are epoch **ms**, color
/// is an index, `hidden` is the hidden-vault flag.
public struct BackupFolder: Sendable, Equatable {
    public var id: String
    public var name: String
    public var colorIndex: Int
    public var createdAt: Int64   // epoch ms
    public var hidden: Bool

    public init(id: String, name: String, colorIndex: Int, createdAt: Int64, hidden: Bool) {
        self.id = id; self.name = name; self.colorIndex = colorIndex
        self.createdAt = createdAt; self.hidden = hidden
    }
}

/// One item (file) in a backup manifest. `entry` is the ZIP entry that holds its
/// raw **plaintext** bytes (`blobs/<id>`). `deletedAt == 0` means live; otherwise
/// the epoch-ms it entered Recently Deleted (the 30-day purge clock restarts from
/// it on restore).
public struct BackupItem: Sendable, Equatable {
    public var id: String
    public var name: String
    public var mimeType: String
    public var sizeBytes: Int64   // plaintext size
    public var addedAt: Int64     // epoch ms
    public var folderId: String?  // nil == root
    public var hidden: Bool
    public var archived: Bool
    public var deletedAt: Int64   // 0 == live
    public var entry: String

    public init(id: String, name: String, mimeType: String, sizeBytes: Int64, addedAt: Int64,
                folderId: String?, hidden: Bool, archived: Bool, deletedAt: Int64, entry: String) {
        self.id = id; self.name = name; self.mimeType = mimeType; self.sizeBytes = sizeBytes
        self.addedAt = addedAt; self.folderId = folderId; self.hidden = hidden
        self.archived = archived; self.deletedAt = deletedAt; self.entry = entry
    }
}

/// Encoder/decoder for `manifest.json` (format version 2). Uses
/// `JSONSerialization` rather than `Codable` so the exact shape — `folderId:
/// null`, integer epoch-ms, boolean literals — matches Android's `org.json`
/// output and parses Android's without surprises.
enum BackupManifest {

    static let version = 2

    static func encode(folders: [BackupFolder], items: [BackupItem], createdAt: Int64) throws -> Data {
        let dict: [String: Any] = [
            "version": version,
            "createdAt": createdAt,
            "folders": folders.map { f -> [String: Any] in
                ["id": f.id, "name": f.name, "colorIndex": f.colorIndex,
                 "createdAt": f.createdAt, "hidden": f.hidden]
            },
            "items": items.map { i -> [String: Any] in
                ["id": i.id, "name": i.name, "mimeType": i.mimeType, "sizeBytes": i.sizeBytes,
                 "addedAt": i.addedAt, "folderId": i.folderId as Any? ?? NSNull(),
                 "hidden": i.hidden, "archived": i.archived, "deletedAt": i.deletedAt,
                 "entry": i.entry]
            }
        ]
        return try JSONSerialization.data(withJSONObject: dict, options: [])
    }

    /// Lenient decode. Never hard-fails on `version` — reads what it understands,
    /// defaults the rest. v1 manifests (no `archived`/`deletedAt`) default those
    /// to live, exactly as the spec requires.
    static func decode(_ data: Data) throws -> (folders: [BackupFolder], items: [BackupItem]) {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CryptoError.malformedHeader
        }

        let folders: [BackupFolder] = (root["folders"] as? [[String: Any]] ?? []).map { f in
            BackupFolder(
                id: f["id"] as? String ?? UUID().uuidString,
                name: f["name"] as? String ?? "Folder",
                colorIndex: (f["colorIndex"] as? NSNumber)?.intValue ?? 0,
                createdAt: (f["createdAt"] as? NSNumber)?.int64Value ?? 0,
                hidden: (f["hidden"] as? NSNumber)?.boolValue ?? false)
        }

        let items: [BackupItem] = (root["items"] as? [[String: Any]] ?? []).map { i in
            let folderId: String?
            if let raw = i["folderId"], !(raw is NSNull), let s = raw as? String, !s.isEmpty {
                folderId = s
            } else {
                folderId = nil
            }
            return BackupItem(
                id: i["id"] as? String ?? UUID().uuidString,
                name: i["name"] as? String ?? "file",
                mimeType: i["mimeType"] as? String ?? "application/octet-stream",
                sizeBytes: (i["sizeBytes"] as? NSNumber)?.int64Value ?? 0,
                addedAt: (i["addedAt"] as? NSNumber)?.int64Value ?? 0,
                folderId: folderId,
                hidden: (i["hidden"] as? NSNumber)?.boolValue ?? false,
                archived: (i["archived"] as? NSNumber)?.boolValue ?? false,   // v1 default
                deletedAt: (i["deletedAt"] as? NSNumber)?.int64Value ?? 0,     // v1 default (live)
                entry: i["entry"] as? String ?? "blobs/\(i["id"] as? String ?? "")")
        }
        return (folders, items)
    }
}
