import SwiftUI
import FileWallKit

/// The iPad / Mac layout: a three-column `NavigationSplitView`.
///
/// - **Sidebar** — the three sections (Vault, Hidden, Security).
/// - **Content** — the grid for the chosen section.
/// - **Detail** — a **live preview** of the selected item, updating as you tap
///   around the grid. This inspector pane is the iPad-only payoff of the bigger
///   canvas: on iPhone the same tap pushes a full-screen detail instead.
struct SplitRootView: View {
    enum Section: Hashable { case vault, hidden, security }

    @EnvironmentObject private var app: AppState
    @State private var section: Section? = .vault
    @State private var selected: VaultFileSnapshot?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
        } content: {
            content
        } detail: {
            detail
        }
        // Selecting a different section clears the stale preview.
        .onChange(of: section) { _ in selected = nil }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $section) {
            Label("Vault", systemImage: "lock.rectangle.stack").tag(Section.vault)
            Label("Hidden", systemImage: "eye.slash").tag(Section.hidden)
            Label("Security", systemImage: "shield.lefthalf.filled").tag(Section.security)
        }
        .navigationTitle("FileWall")
    }

    // MARK: Content column

    @ViewBuilder
    private var content: some View {
        switch section ?? .vault {
        case .vault:
            NavigationStack { VaultGridView(side: .standard, selection: $selected) }
        case .hidden:
            NavigationStack { HiddenView(selection: $selected) }
        case .security:
            NavigationStack { SecurityView() }
        }
    }

    // MARK: Detail column — the live preview

    @ViewBuilder
    private var detail: some View {
        if let selected {
            NavigationStack {
                ItemDetailView(item: selected, side: section == .hidden ? .hidden : .standard)
            }
            // A new id tears down and rebuilds the preview, so its decrypt task
            // re-runs for the newly-selected item.
            .id(selected.id)
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "sidebar.right").font(.system(size: 44)).foregroundStyle(.tertiary)
            Text(section == .security ? "Vault settings" : "Select an item to preview")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
