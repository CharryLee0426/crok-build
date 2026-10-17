import SwiftUI

/// Signed in: Sessions and Settings.
struct MainView: View {
    @Environment(CrokEngine.self) private var engine
    @State private var tab: MainTab = .sessions
    @State private var sessionsPath = NavigationPath()

    enum MainTab: Hashable { case sessions, settings }

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack(path: $sessionsPath) {
                SessionsListView()
                    .navigationDestination(for: SessionRoute.self) { route in
                        SessionScreen(route: route)
                    }
            }
            .environment(\.openSessionRoute, OpenSessionRouteAction { route in sessionsPath.append(route) })
            .tabItem { Label("Sessions", systemImage: "bubble.left.and.bubble.right") }
            .badge(engine.unreadTotal)
            .tag(MainTab.sessions)

            NavigationStack {
                SettingsView()
            }
            .tabItem { Label("Settings", systemImage: "gearshape") }
            .tag(MainTab.settings)
        }
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

extension EnvironmentValues {
    var openSessionRoute: OpenSessionRouteAction {
        get { self[OpenSessionRouteKey.self] }
        set { self[OpenSessionRouteKey.self] = newValue }
    }
}
