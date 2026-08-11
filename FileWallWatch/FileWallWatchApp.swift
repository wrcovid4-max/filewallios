import SwiftUI

/// The watchOS app — a viewfinder onto the phone's vault, never a second vault.
/// It holds no keys and stores nothing: it asks the phone for a manifest and for
/// individual photos on demand, so a watch out of range (or lost) has nothing.
@main
struct FileWallWatchApp: App {
    @StateObject private var client = WatchConnectivityClient.shared

    var body: some Scene {
        WindowGroup {
            WatchVaultView()
                .environmentObject(client)
        }
    }
}
