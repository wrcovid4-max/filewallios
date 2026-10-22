import Foundation

/// Which files were saved to a folder (iCloud Drive, Google Drive, ...). Shown as a mark on the grid.
enum ExportLog {
    private static let key = "exported_to_folder_ids"

    static func isExported(_ id: UUID) -> Bool {
        (UserDefaults.standard.stringArray(forKey: key) ?? []).contains(id.uuidString)
    }

    static func mark(_ id: UUID) {
        var ids = UserDefaults.standard.stringArray(forKey: key) ?? []
        if !ids.contains(id.uuidString) { ids.append(id.uuidString) }
        UserDefaults.standard.set(ids, forKey: key)
    }
}
