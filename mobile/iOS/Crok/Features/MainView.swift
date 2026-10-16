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
                        SessionScreen(sessionDocId: route.id)
                    }
            }
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

struct SessionRoute: Hashable {
    let id: DocID
}
