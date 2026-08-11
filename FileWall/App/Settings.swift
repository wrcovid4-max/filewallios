import SwiftUI

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
