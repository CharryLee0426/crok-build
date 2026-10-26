import SwiftUI
import UIKit

/// Signed in: Sessions and Profile (mobile/DESIGN.md "Tabs"), and o11y in dev builds ("o11y"). Holding Sessions
/// offers Mark All as Read for the selected computer; holding Profile opens the computer switcher, the way Telegram
/// switches accounts.
struct MainView: View {
    @Environment(CrokEngine.self) private var engine
    @State private var tab: MainTab = .sessions
    @State private var sessionsPath = NavigationPath()
    @State private var showsLink = false
    @State private var picture = AccountPicture()
    @State private var actionError: RelayError?

    enum MainTab: Hashable { case sessions, profile, o11y }

    var body: some View {
        let user = engine.account.value??.user ?? engine.credentials.user
        TabView(selection: $tab) {
            NavigationStack(path: $sessionsPath) {
                SessionsListView()
                    .navigationDestination(for: SessionRoute.self) { route in
                        SessionScreen(route: route)
                    }
                    .navigationDestination(for: ProjectRoute.self) { route in
                        ProjectSessionsView(projectKey: route.key)
                    }
                    .navigationDestination(for: ArchivedRoute.self) { route in
                        ArchivedSessionsView(deviceId: route.deviceId)
                    }
                    .background(TabBarContextMenus(menu: tabMenu))
            }
            .environment(\.openSessionRoute, OpenSessionRouteAction { route in sessionsPath.append(route) })
            .tabItem { Label("Sessions", systemImage: "bubble.left.and.bubble.right") }
            .badge(engine.selectedUnread)
            .tag(MainTab.sessions)

            NavigationStack {
                ProfileView()
            }
            .tabItem {
                Label {
                    Text("Profile")
                } icon: {
                    Image(uiImage: AvatarImages.profileTab(picture: picture.image, user: user, selected: tab == .profile))
                }
            }
            .badge(engine.otherComputersUnread)
            .tag(MainTab.profile)

            if AppInfo.showsO11yTab {
                O11yTab()
                    .tabItem {
                        Label {
                            Text(verbatim: "o11y")
                        } icon: {
                            Image(systemName: "chart.xyaxis.line")
                        }
                    }
                    .tag(MainTab.o11y)
                    .accessibilityIdentifier("o11yTab")
            }
        }
        .environment(\.openLinkComputer, OpenLinkComputerAction { showsLink = true })
        .onAppear { picture.load(user.imageUrl) }
        .onChange(of: user.imageUrl) { _, url in picture.load(url) }
        .onChange(of: engine.selectedComputerId) { _, _ in
            // Another computer: its Sessions tab starts at its list, like a switched Telegram account.
            sessionsPath = NavigationPath()
        }
        .sheet(isPresented: $showsLink) {
            NavigationStack { LinkComputerView(showsClose: true) }
        }
        .relayErrorAlert($actionError)
    }

    /// Holding a tab: Sessions → Mark All as Read; Profile → the computers and Link a computer.
    private func tabMenu(_ index: Int) -> UIMenu? {
        switch index {
        case 0:
            let ids = ReadAll.unreadIDs(in: engine.selectedGroups)
            let read = UIAction(
                title: String(localized: "Mark All as Read"), image: UIImage(systemName: "checkmark.bubble"),
                attributes: ids.isEmpty ? [.disabled] : []
            ) { _ in
                Task { @MainActor in actionError = await engine.markRead(ids) }
            }
            return UIMenu(children: [read])
        case 1:
            return ComputerSwitcherMenu.make(engine: engine) { showsLink = true }
        default:
            return nil
        }
    }
}

/// The computer switcher (Telegram's account menu), the same from the Profile tab and from the Sessions title: each
/// computer with its avatar and "N unread" or its status, a checkmark on the selected one, then Link a computer.
@MainActor
enum ComputerSwitcherMenu {
    static func make(engine: CrokEngine, onLink: @escaping @MainActor () -> Void) -> UIMenu {
        let selected = engine.selectedComputerId
        let computers = engine.computerAccounts.map { computer in
            UIAction(
                title: computer.name, subtitle: ComputerSwitcherItems.subtitle(computer),
                image: AvatarImages.computer(computer), state: computer.id == selected ? .on : .off
            ) { _ in
                Task { @MainActor in engine.selectComputer(computer.id) }
            }
        }
        let link = UIAction(title: String(localized: "Link a computer"), image: UIImage(systemName: "plus")) { _ in
            Task { @MainActor in onLink() }
        }
        return UIMenu(children: [
            UIMenu(options: .displayInline, children: computers),
            UIMenu(options: .displayInline, children: [link]),
        ])
    }
}

/// A transparent UIKit button over a SwiftUI view that opens a `UIMenu` on tap, built when it opens (SwiftUI's
/// `Menu` leaves out the second line of its items).
struct UIMenuButtonOverlay: UIViewRepresentable {
    let accessibilityLabel: String
    var accessibilityValue: String?
    let identifier: String
    let menu: @MainActor () -> UIMenu

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .custom)
        button.showsMenuAsPrimaryAction = true
        button.backgroundColor = .clear
        update(button)
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        update(button)
    }

    private func update(_ button: UIButton) {
        let make = menu
        button.menu = UIMenu(children: [
            UIDeferredMenuElement.uncached { completion in
                completion(make().children)
            }
        ])
        button.accessibilityLabel = accessibilityLabel
        button.accessibilityValue = accessibilityValue
        button.accessibilityIdentifier = identifier
    }
}

/// A screen on the Sessions stack: a session, or a new one about to start (relay/DESIGN.md §5 "New sessions"), which
/// becomes that session in the same entry once the relay made it.
enum SessionRoute: Hashable {
    case session(DocID)
    case new(NewSessionRoute)
}

struct NewSessionRoute: Hashable {
    var target: NewSessionTarget
    /// `/new <prompt>`: sent at once.
    var prompt: String?
    /// Made once per entry, so the screen never starts two sessions for it.
    var clientId: String = UUID().uuidString.lowercased()
}

/// Pushes a screen on the Sessions stack (from the list, the compose button, or `/new` in a session).
@MainActor
struct OpenSessionRouteAction: Sendable {
    let open: @MainActor (SessionRoute) -> Void

    func callAsFunction(_ route: SessionRoute) {
        open(route)
    }
}

private struct OpenSessionRouteKey: EnvironmentKey {
    static let defaultValue = OpenSessionRouteAction(open: { _ in })
}

/// Opens Link a computer (the QR scanner) as a sheet over the tabs.
@MainActor
struct OpenLinkComputerAction: Sendable {
    let open: @MainActor () -> Void

    func callAsFunction() {
        open()
    }
}

private struct OpenLinkComputerKey: EnvironmentKey {
    static let defaultValue = OpenLinkComputerAction(open: {})
}

extension EnvironmentValues {
    var openSessionRoute: OpenSessionRouteAction {
        get { self[OpenSessionRouteKey.self] }
        set { self[OpenSessionRouteKey.self] = newValue }
    }

    var openLinkComputer: OpenLinkComputerAction {
        get { self[OpenLinkComputerKey.self] }
        set { self[OpenLinkComputerKey.self] = newValue }
    }
}
