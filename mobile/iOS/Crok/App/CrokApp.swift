import SwiftUI

@main
struct CrokApp: App {
    @State private var model: AppModel
    @AppStorage("crok.appearance") private var appearance = Appearance.system.rawValue
    private let forcedAppearance: Appearance?

    init() {
        let options = LaunchOptions.current()
        let environment: any AppEnvironment
        if options.demo {
            environment = DemoEnvironment(signedIn: !options.demoSignIn, approveAfter: options.demoApproveAfter)
        } else {
            environment = LiveEnvironment(opensBrowserAutomatically: !options.noBrowser)
        }
        if options.resetState && !options.demo {
            environment.store.wipe()
            environment.drafts.removeAll()
            environment.sessionCache?.clear()
        }
        forcedAppearance = options.appearance.flatMap(Appearance.init(rawValue:))
        let model = AppModel(
            environment: environment, defaultDeviceName: AppInfo.defaultDeviceName, platform: AppInfo.platform)
        model.restore()
        _model = State(initialValue: model)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme((forcedAppearance ?? Appearance(rawValue: appearance) ?? .system).colorScheme)
                .tint(Theme.accent)
        }
    }
}

/// Settings › Appearance.
enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}
