import SwiftUI

/// The hidden vault. Gated by biometrics (with passcode fallback) every session;
/// once unlocked it shows the same grid as the standard side, but for the hidden
/// side. Backgrounding re-locks it (see AppState.handleBackgrounding).
struct HiddenView: View {
    @EnvironmentObject private var app: AppState
    @State private var failed = false

    var body: some View {
        if app.hiddenUnlocked {
            VaultGridView(side: .hidden)
        } else {
            lockedGate
        }
    }

    private var lockedGate: some View {
        VStack(spacing: 18) {
            Image(systemName: "eye.slash.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
            Text("Hidden Vault")
                .font(.title2.weight(.semibold))
            Text("Locked behind \(app.biometricsOnly ? "biometrics" : "Face ID, Touch ID, or your passcode").")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button {
                Task { await unlock() }
            } label: {
                Label("Unlock", systemImage: "faceid")
                    .frame(maxWidth: 220)
            }
            .buttonStyle(.borderedProminent)

            if failed {
                Text("Authentication failed. Try again.")
                    .font(.caption).foregroundStyle(.red)
            }
        }
        .padding()
        .navigationTitle("Hidden")
    }

    private func unlock() async {
        failed = false
        let ok = await app.unlockHidden()
        if !ok { failed = true }
    }
}
