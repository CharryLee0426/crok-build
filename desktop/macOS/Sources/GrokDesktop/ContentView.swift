import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var extras: ExtrasFeatureModel
    @ObservedObject private var language = L10n.state
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openWindow) private var openWindow
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var window: NSWindow?

    var body: some View {
        // Sheets are attached outside the rebuilt content, so a theme preview can
        // rebuild the window behind the theme picker without dismissing it.
        splitView
            .id(extras.themeRevision)
            // Liquid metal bends toward the pointer (see `Atelier`).
            .modifier(MetalPointerFollower())
            .frame(minWidth: store.minimalMode ? 560 : 920, minHeight: 650)
            // Test builds only; outside the rebuilt content so a theme change keeps its samples.
            .overlay { PerformanceMonitorOverlay() }
            .sheet(isPresented: $store.showSettings) { SettingsView().desktopEnvironment(store) }
            .sheet(isPresented: $store.showCommandPalette) { CommandPalette().desktopEnvironment(store) }
            .sheet(item: $store.featurePanel) { panel in FeatureBrowser(panel: panel).desktopEnvironment(store) }
            .sheet(isPresented: $store.showAdvancedPanel) { AdvancedFeatureView().desktopEnvironment(store) }
            .sheet(isPresented: $store.showRename) { RenameTaskSheet().desktopEnvironment(store) }
            .sheet(item: $store.sheet) { sheet in sheet.content.desktopEnvironment(store) }
            .onChange(of: store.windowRequest) { _, window in
                guard let window else { return }
                openWindow(id: window.rawValue)
                store.windowRequest = nil
            }
            // The image viewer covers the whole window, toolbar included, from a panel above it.
            .background(HostWindowReader { window = $0; store.mainWindow = $0 })
            .onChange(of: store.imageViewer != nil) { _, _ in ImageViewerPresenter.shared.sync(store, window: window) }
            .onAppear { MarkdownImageCell.open = { [weak store] url, _ in store?.openImage(url: url) } }
            // For measured runs: CROK_DESKTOP_BROWSER opens the side panel's browser on an address at launch.
            .onAppear { if let address = ProcessInfo.processInfo.environment["CROK_DESKTOP_BROWSER"], !address.isEmpty { store.openBrowser(address) } }
            .onChange(of: store.minimalMode) { _, minimal in
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { columnVisibility = minimal ? .detailOnly : .all }
            }
    }

    private var splitView: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 264, max: 340)
        } detail: {
            VStack(spacing: 0) {
                AnnouncementBanner()
                if let banner = store.banner { BannerRow(text: banner) }
                GeometryReader { geometry in
                    HStack(spacing: 0) {
                        ConversationView().frame(maxWidth: .infinity)
                        if store.showInspector {
                            SidePanelView(containerWidth: geometry.size.width)
                                .transition(.move(edge: .trailing).combined(with: .opacity))
                        }
                    }
                }
            }
            .overlay { TitleBarGlass() }
            .overlay(alignment: .topTrailing) { DebugOverlay() }
            .background { GlassBackdrop(role: .canvas).ignoresSafeArea() }
            .navigationTitle(store.conversation?.title ?? L10n.t("new_task_row", "New task"))
            .navigationSubtitle(windowSubtitle)
            .toolbar { workspaceToolbar }
            .toolbar(store.minimalMode ? .hidden : .automatic, for: .windowToolbar)
            .themedToolbarBackground()
        }
        .navigationSplitViewStyle(.balanced)
        // Behind every column, so no opaque window background shows around the floating sidebar.
        .background { GlassBackdrop(role: .sidebar).ignoresSafeArea() }
        .foregroundStyle(Theme.ink)
        .onChange(of: store.showSearch) { _, visible in
            if visible { columnVisibility = .all } else { store.search = "" }
        }
        .task {
            await store.refreshWorkspace()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                guard !Task.isCancelled else { break }
                await store.refreshWorkspace()
            }
        }
        .background(Button("") {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
            }
        }.keyboardShortcut("b").hidden())
    }

    /// The project's folder, or for a session of another computer that computer and the session's folder.
    private var windowSubtitle: String {
        if let remote = store.conversation?.remote {
            return "\(remote.computer) · \(URL(fileURLWithPath: remote.cwd).lastPathComponent)"
        }
        return store.project?.name ?? L10n.t("your_workspace", "Your workspace")
    }

    @ToolbarContentBuilder
    private var workspaceToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if let project = store.project {
                Button { store.revealProject() } label: {
                    Label { Text(L10n.t("reveal_in_finder", "Reveal in Finder")) } icon: { Image(nsImage: FinderIcon.image).renderingMode(.original) }
                }
                .help(L10n.t("reveal_named_in_finder", "Reveal {name} in Finder", ["name": project.name]))
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { store.showInspector.toggle() }
                } label: {
                    Label(L10n.t("side_panel_label", "Side panel"), systemImage: "sidebar.right")
                }.help(store.showInspector ? L10n.t("side_panel_hide", "Hide side panel · ⌘J") : L10n.t("side_panel_show", "Show files, side chat, terminal, and browser · ⌘J"))
            }
        }
    }
}

/// The banner over the conversation (`AppStore.banner`). It goes by itself `lifetime` after it was
/// last shown, and stays while the pointer rests on it, so its text can be read to the end or selected.
struct BannerRow: View {
    @EnvironmentObject var store: AppStore
    let text: String
    var lifetime: Duration = BannerRow.lifetime
    static let lifetime: Duration = .seconds(5)
    @State private var hovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle")
            Text(text).textSelection(.enabled)
            Spacer(minLength: 4)
            IconButton(icon: "xmark", help: L10n.t("dismiss", "Dismiss")) { store.banner = nil }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 24).padding(.vertical, 10)
        .background(Theme.hover.opacity(0.7))
        .onHover { hovered = $0 }
        .task(id: Showing(revision: store.bannerRevision, hovered: hovered)) {
            guard !hovered else { return }
            let revision = store.bannerRevision
            try? await Task.sleep(for: lifetime)
            if !Task.isCancelled, store.bannerRevision == revision { store.banner = nil }
        }
    }

    private struct Showing: Equatable {
        var revision: Int
        var hovered: Bool
    }
}

/// Finder's own icon, for the toolbar's Reveal in Finder button.
@MainActor
enum FinderIcon {
    static let image: NSImage = {
        let path = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder")?.path ?? "/System/Library/CoreServices/Finder.app"
        let icon = (NSWorkspace.shared.icon(forFile: path).copy() as? NSImage) ?? NSImage()
        icon.size = NSSize(width: 18, height: 18)
        return icon
    }()
}

struct RenameTaskSheet: View {
    @ObservedObject private var language = L10n.state
    @EnvironmentObject var store: AppStore
    @State private var title = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.t("rename_task", "Rename task")).font(.system(size: 20, weight: .semibold))
                Text(L10n.t("rename_task_detail", "The new title appears in the sidebar and the window title.")).font(.system(size: 13)).foregroundStyle(Theme.muted)
            }
            DesktopTextField(L10n.t("rename_task_field", "Task title"), text: $title, symbol: "pencil")
                .onSubmit(rename)
            HStack {
                Spacer()
                Button(L10n.t("cancel", "Cancel")) { store.showRename = false }.keyboardShortcut(.cancelAction)
                Button(L10n.t("rename", "Rename"), action: rename).keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.buttonStyle(SubtleButtonStyle()).font(.system(size: 13, weight: .medium))
        }
        .padding(24).frame(width: 460).glassSheetBackground()
        .onAppear { title = store.conversation?.title ?? "" }
    }

    private func rename() {
        guard let id = store.state.selectedConversationID else { store.showRename = false; return }
        store.features.sessions.applyRename(id: id, title: title)
        store.showRename = false
    }
}
