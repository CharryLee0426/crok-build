import AppKit

/// Which artwork the Dock shows. The window `appearance` decides; `system`, the auto theme's
/// appearance, follows the system's light or dark mode.
enum AppIconVariant: Equatable {
    case light, dark

    init(appearance: String?, systemIsDark: Bool) {
        switch appearance {
        case "dark": self = .dark
        case "light": self = .light
        default: self = systemIsDark ? .dark : .light
        }
    }

    /// The Info.plist key naming this variant's icon file; build-app.sh writes both.
    var infoKey: String {
        switch self {
        case .light: return "CFBundleIconFile"
        case .dark: return "GrokDesktopDarkIconFile"
        }
    }
}

/// Keeps the running app's Dock icon on the artwork for the current appearance. The bundle's own
/// icon, which Finder and the Dock show while the app is not running, is the light-mode one.
@MainActor
final class AppIconController {
    private let bundle: Bundle
    private let defaults: UserDefaults
    private let apply: @MainActor (NSImage) -> Void
    private var images: [AppIconVariant: NSImage] = [:]
    private(set) var shown: AppIconVariant?
    private var defaultsObserver: NSObjectProtocol?
    private var systemObservation: NSKeyValueObservation?

    init(bundle: Bundle = .main, defaults: UserDefaults = .standard,
         apply: @escaping @MainActor (NSImage) -> Void = { NSApp.applicationIconImage = $0 }) {
        self.bundle = bundle
        self.defaults = defaults
        self.apply = apply
    }

    deinit { if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) } }

    func start() {
        // Themes and Settings change the `appearance` preference; the system's mode changes NSApp's appearance.
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: defaults, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        systemObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.refresh() } }
        }
        refresh()
    }

    func refresh() {
        let systemIsDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let variant = AppIconVariant(appearance: defaults.string(forKey: GrokThemePreferences.appearanceKey), systemIsDark: systemIsDark)
        guard variant != shown, let image = image(for: variant) ?? image(for: .light) else { return }
        shown = variant
        apply(image)
    }

    /// Loads the shipped artwork directly so an in-place rebuild cannot leave the running Dock tile
    /// displaying an older Icon Services cache entry.
    func image(for variant: AppIconVariant) -> NSImage? {
        if let image = images[variant] { return image }
        guard let name = bundle.object(forInfoDictionaryKey: variant.infoKey) as? String,
              let resources = bundle.resourceURL else { return nil }
        let fileName = (name as NSString).pathExtension.isEmpty ? name + ".icns" : name
        let image = NSImage(contentsOf: resources.appendingPathComponent(fileName))
        images[variant] = image
        return image
    }
}
