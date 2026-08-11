import SwiftUI
import FileWallKit

/// The app's root. Three sections — Vault, Hidden, Security — plus the
/// cross-cutting screen protection.
///
/// iPhone uses a `TabView`; a full iPad `NavigationSplitView` (sidebar + grid +
/// inspector) is a refinement layered on later. `NavigationStack` is used for
/// push navigation inside each tab (never the deprecated `NavigationView`).
struct RootView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView {
            NavigationStack { VaultGridView(side: .standard) }
                .tabItem { Label("Vault", systemImage: "lock.rectangle.stack") }

            NavigationStack { HiddenView() }
                .tabItem { Label("Hidden", systemImage: "eye.slash") }

            NavigationStack { SecurityView() }
                .tabItem { Label("Security", systemImage: "shield.lefthalf.filled") }
        }
        // Screen protection overlay: an opaque blur while inactive or captured.
        .overlay {
            if app.isObscured {
                ZStack {
                    Rectangle().fill(.ultraThinMaterial)
                    Image(systemName: "lock.fill").font(.largeTitle).foregroundStyle(.secondary)
                }
                .ignoresSafeArea()
                .transition(.opacity)
            }
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active:
                app.isObscured = isScreenCaptured
            case .inactive:
                app.isObscured = true               // app-switcher snapshot shows nothing
            case .background:
                app.isObscured = true
                app.handleBackgrounding()           // lock hidden + wipe plaintext
            @unknown default:
                break
            }
        }
        .task { VaultService.wipePreviewCache() }    // stale plaintext never survives a launch
        #if os(iOS)
        .onReceive(NotificationCenter.default.publisher(for: UIScreen.capturedDidChangeNotification)) { _ in
            app.isObscured = isScreenCaptured
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.userDidTakeScreenshotNotification)) { _ in
            app.showScreenshotAlert = true
        }
        .alert("Screenshot saved to Photos", isPresented: $app.showScreenshotAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("iOS can’t block screenshots. A picture of what was on screen now exists in your photo library.")
        }
        #endif
    }

    private var isScreenCaptured: Bool {
        #if os(iOS)
        UIScreen.main.isCaptured
        #else
        false
        #endif
    }
}
