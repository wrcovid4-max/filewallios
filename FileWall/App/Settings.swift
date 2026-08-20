import SwiftUI

extension Notification.Name {
    /// Posted when a folder is created, renamed, or deleted so the iPad sidebar
    /// (which caches the folder list) can refresh itself.
    static let vaultFoldersDidChange = Notification.Name("vaultFoldersDidChange")
}

/// The FileWall website pages, surfaced from Settings. Centralised so the links
/// live in one place (and can be reused by onboarding or the watch later).
enum FileWallLink {
    private static let base = "https://wrcovid4-max.github.io/FileWallWeb/"
    private static func url(_ page: String) -> URL { URL(string: base + page)! }

    static let home         = url("index.html")
    static let screens      = url("screens.html")
    static let platforms    = url("platforms.html")
    static let iPhone       = url("ios.html")
    static let iPad         = url("ipad.html")
    static let vision       = url("vision.html")
    static let xr           = url("xr.html")
    static let news         = url("news.html")
    static let appleBeta    = url("news-apple-beta.html")
    static let download     = url("download.html")
    static let support      = url("support.html")
    static let accessibility = url("accessibility.html")
    static let privacy      = url("privacy.html")
    static let terms        = url("terms.html")
    static let trademarks   = url("trademarks.html")
}

/// UserDefaults keys for the app's preferences. Centralised so `@AppStorage` in
/// the views and direct `UserDefaults` reads in non-view code (PhoneWatchSession,
/// AppState) use the exact same strings.
enum Pref {
    static let appearance = "pref.appearance"
    static let allowScreenshots = "pref.allowScreenshots"
    static let watchSync = "pref.watchSync"
    static let documentPreviews = "pref.documentPreviews"
    static let dailyBackup = "pref.dailyBackup"
    static let autoLockSeconds = "pref.autoLockSeconds"   // 0 == never
    static let iPadNav = "pref.iPadNav"                    // sidebar vs top bar (iPad/Mac)

    // Defaults, applied where a key has never been written.
    static let defaultWatchSync = true
    static let defaultDocumentPreviews = true
    static let defaultAutoLockSeconds = 15
}

/// On the big (iPad / Mac) canvas the section switcher can live in a left
/// **sidebar** (with the vault's folders listed under it) or as a **top-centered**
/// segmented bar. Selectable in Security, or with the toolbar toggle.
enum NavStyle: String, CaseIterable, Identifiable {
    case sidebar, topBar
    var id: String { rawValue }
    var title: String { self == .sidebar ? "Sidebar" : "Top Bar" }
    var symbol: String { self == .sidebar ? "sidebar.left" : "rectangle.topthird.inset.filled" }
}

/// Light / Dark / follow-system, applied at the app root via `preferredColorScheme`.
enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// The inactivity auto-lock choices (seconds; 0 == never).
enum AutoLock: Int, CaseIterable, Identifiable {
    case fifteen = 15, thirty = 30, oneMinute = 60, fiveMinutes = 300, never = 0
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .fifteen: return "15s"
        case .thirty: return "30s"
        case .oneMinute: return "1m"
        case .fiveMinutes: return "5m"
        case .never: return "Never"
        }
    }
}
