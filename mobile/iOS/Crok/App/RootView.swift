import SwiftUI

/// Signed out, nothing but the sign-in flow is reachable.
struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            switch model.phase {
            case .welcome:
                WelcomeView()
                    .transition(.opacity)
            case .waiting:
                WaitingView()
                    .transition(.opacity)
            case .signedIn:
                if let engine = model.engine {
                    MainView()
                        .environment(engine)
                        .id(engine.credentials.deviceId)
                        .transition(.opacity)
                }
            }
        }
        .animation(.default, value: model.phase)
    }
}
