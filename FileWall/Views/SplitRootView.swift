import SwiftUI
import FileWallKit

/// The iPad / Mac layout. Two selectable shapes (Security ▸ Navigation, or the
/// toolbar toggle):
///
/// - **Sidebar** — a left column listing Vault / Hidden / Security, with the
///   vault's **folders** nested under Vault so you can jump straight in; then the
///   grid; then a live **preview** of the selected item.
/// - **Top Bar** — the section switcher moves to a centered segmented control at
///   the top; the grid and live preview sit side by side beneath it.
///
/// In both, Security fills the width (no blank right pane).
struct SplitRootView: View {
    enum Section: Hashable { case vault, hidden, security }

    /// A single selection type so the sidebar List can mix sections and folders.
    enum SidebarItem: Hashable {
        case section(Section)
        case folder(UUID)
    }

    @EnvironmentObject private var app: AppState
    @AppStorage(Pref.iPadNav) private var navRaw = NavStyle.sidebar.rawValue

    @State private var sidebarSelection: SidebarItem? = .section(.vault)
    @State private var section: Section? = .vault          // drives the top-bar picker
    @State private var selected: VaultFileSnapshot?
    @State private var folders: [VaultFolderSnapshot] = []
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    private var navStyle: NavStyle { NavStyle(rawValue: navRaw) ?? .sidebar }

    var body: some View {
        Group {
            switch navStyle {
            case .sidebar: sidebarLayout
            case .topBar:  topBarLayout
            }
        }
        .task { await loadFolders() }
        .onChange(of: navStyle) { _ in syncSelections() }
        .onChange(of: sidebarSelection) { _ in selected = nil; section = derivedSection }
        .onChange(of: section) { _ in selected = nil }
    }

    // MARK: Sidebar layout

    private var sidebarLayout: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
        } content: {
            contentColumn(for: sidebarSection, folder: sidebarFolder)
        } detail: {
            detail(for: sidebarSection)
        }
    }

    private var sidebar: some View {
        // A flat list (no Sections) so the sidebar style doesn't add collapse
        // chevrons. Folders sit indented beneath Vault.
        List(selection: $sidebarSelection) {
            Label("Vault", systemImage: "lock.rectangle.stack").tag(SidebarItem.section(.vault))
            ForEach(folders) { f in
                Label(f.name, systemImage: "folder.fill")
                    .tag(SidebarItem.folder(f.id))
                    .padding(.leading, 16)
            }
            Label("Hidden", systemImage: "eye.slash").tag(SidebarItem.section(.hidden))
            Label("Security", systemImage: "shield.lefthalf.filled").tag(SidebarItem.section(.security))
        }
        .listStyle(.sidebar)
        .navigationTitle("FileWall")
        .toolbar { ToolbarItem(placement: .primaryAction) { layoutToggle } }
    }

    // MARK: Top-bar layout

    private var topBarLayout: some View {
        NavigationStack {
            Group {
                if (section ?? .vault) == .security {
                    contentColumn(for: .security, folder: nil)   // full width
                } else {
                    HStack(spacing: 0) {
                        contentColumn(for: section ?? .vault, folder: nil)
                            .frame(maxWidth: .infinity)
                        Divider()
                        detail(for: section ?? .vault)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .principal) { sectionPicker }
                ToolbarItem(placement: .navigationBarTrailing) { layoutToggle }
            }
        }
    }

    private var sectionPicker: some View {
        Picker("Section", selection: Binding(get: { section ?? .vault }, set: { section = $0 })) {
            Text("Vault").tag(Section.vault)
            Text("Hidden").tag(Section.hidden)
            Text("Security").tag(Section.security)
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 360)
    }

    private var layoutToggle: some View {
        Button {
            let next: NavStyle = navStyle == .sidebar ? .topBar : .sidebar
            withAnimation { navRaw = next.rawValue }
        } label: {
            Image(systemName: navStyle == .sidebar ? "rectangle.topthird.inset.filled" : "sidebar.left")
        }
        .help(navStyle == .sidebar ? "Move switcher to the top" : "Move switcher to the sidebar")
    }

    // MARK: Content column

    @ViewBuilder
    private func contentColumn(for section: Section, folder: VaultFolderSnapshot?) -> some View {
        switch section {
        case .vault:
            NavigationStack { VaultGridView(side: .standard, folder: folder, selection: $selected) }
        case .hidden:
            NavigationStack { HiddenView(selection: $selected) }
        case .security:
            // Wide so settings fills the canvas instead of hugging a narrow column.
            NavigationStack { SecurityView() }
                .navigationSplitViewColumnWidth(min: 420, ideal: 720)
        }
    }

    // MARK: Detail column — live preview

    @ViewBuilder
    private func detail(for section: Section) -> some View {
        if section == .security {
            aboutPane                               // no blank pane for settings
        } else if let selected {
            NavigationStack {
                ItemDetailView(item: selected, side: section == .hidden ? .hidden : .standard)
            }
            .id(selected.id)
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "sidebar.right").font(.system(size: 44)).foregroundStyle(.tertiary)
            Text("Select an item to preview").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var aboutPane: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.shield.fill").font(.system(size: 56)).foregroundStyle(.tint)
            Text("FileWall").font(.title2.weight(.semibold))
            Text("Your files, encrypted on this device.")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                Text("Version \(version)").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Selection plumbing

    /// The section implied by the current sidebar selection (a folder ⇒ Vault).
    private var sidebarSection: Section {
        switch sidebarSelection {
        case .section(let s): return s
        case .folder:         return .vault
        case nil:             return .vault
        }
    }

    private var sidebarFolder: VaultFolderSnapshot? {
        if case let .folder(id) = sidebarSelection { return folders.first { $0.id == id } }
        return nil
    }

    private var derivedSection: Section { sidebarSection }

    /// Keep the two switchers agreed when the user flips layouts.
    private func syncSelections() {
        switch navStyle {
        case .topBar:  section = sidebarSection
        case .sidebar: sidebarSelection = .section(section ?? .vault)
        }
    }

    private func loadFolders() async {
        folders = (try? await VaultService.shared.vaultStore().folders(side: .standard)) ?? []
    }
}
