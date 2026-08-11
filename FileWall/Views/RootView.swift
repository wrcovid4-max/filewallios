import SwiftUI
import FileWallKit

/// The app's root. Adaptive: a three-column `NavigationSplitView` on the roomy
/// iPad/Mac canvas (sidebar → grid → **live preview**), and a `TabView` on the
/// iPhone. Because the choice keys off the horizontal size class, iPad Split View
/// / Slide Over (which report a compact width) automatically fall back to the
/// phone layout — no separate multitasking handling needed.
struct RootView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.scenePhase) private var scenePhase
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    @AppStorage(Pref.appearance) private var appearanceRaw = Appearance.system.rawValue
    @AppStorage(Pref.allowScreenshots) private var allowScreenshots = false

    private var appearance: Appearance { Appearance(rawValue: appearanceRaw) ?? .system }

    var body: some View {
        adaptiveContent
            .preferredColorScheme(appearance.colorScheme)
            .overlay { screenObscuringOverlay }
            .onChange(of: scenePhase) { phase in
                switch phase {
                case .active:     app.isObscured = shouldObscure(captured: isScreenCaptured); app.noteActivity()
                case .inactive:   app.isObscured = shouldObscure(captured: true)   // app-switcher snapshot
                case .background: app.isObscured = shouldObscure(captured: true); app.handleBackgrounding()
                @unknown default: break
                }
            }
            .task { VaultService.wipePreviewCache() }
            #if os(iOS)
            .onReceive(NotificationCenter.default.publisher(for: UIScreen.capturedDidChangeNotification)) { _ in
                app.isObscured = shouldObscure(captured: isScreenCaptured)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.userDidTakeScreenshotNotification)) { _ in
                if !allowScreenshots { app.showScreenshotAlert = true }
            }
            .alert("Screenshot saved to Photos", isPresented: $app.showScreenshotAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("iOS can’t block screenshots. A picture of what was on screen now exists in your photo library.")
            }
            #endif
    }

    @ViewBuilder
    private var adaptiveContent: some View {
        #if os(iOS)
        if horizontalSizeClass == .regular {
            SplitRootView()          // iPad full-screen / large canvas
        } else {
            phoneTabs                // iPhone, or iPad multitasking (compact width)
        }
        #else
        SplitRootView()             // macOS: always the big-canvas layout
        #endif
    }

    private var phoneTabs: some View {
        TabView {
            NavigationStack { VaultGridView(side: .standard) }
                .tabItem { Label("Vault", systemImage: "lock.rectangle.stack") }

            NavigationStack { HiddenView() }
                .tabItem { Label("Hidden", systemImage: "eye.slash") }

            NavigationStack { SecurityView() }
                .tabItem { Label("Security", systemImage: "shield.lefthalf.filled") }
        }
    }

    @ViewBuilder
    private var screenObscuringOverlay: some View {
        if app.isObscured {
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                Image(systemName: "lock.fill").font(.largeTitle).foregroundStyle(.secondary)
            }
            .ignoresSafeArea()
            .transition(.opacity)
        }
    }

    /// Obscure the screen only when the user hasn't opted to allow screenshots.
    private func shouldObscure(captured: Bool) -> Bool {
        allowScreenshots ? false : captured
    }

    private var isScreenCaptured: Bool {
        #if os(iOS)
        UIScreen.main.isCaptured
        #else
        false
        #endif
    }
}
