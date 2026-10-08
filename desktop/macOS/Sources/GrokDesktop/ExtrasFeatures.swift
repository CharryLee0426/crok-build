import AppKit
import SwiftUI

/// Themes, guides, the tutorial, keyboard shortcuts, and GBOOM.
@MainActor
final class ExtrasFeatureModel: ObservableObject {
    weak var store: AppStore?
    /// Changes whenever the palette does; the main window rebuilds its views to pick it up.
    @Published var themeRevision = 0
    /// The chosen theme. A preview in the theme picker does not change it.
    @Published private(set) var activeTheme: GrokTheme
    /// The theme on screen while the picker previews one other than `activeTheme`.
    @Published private(set) var previewedTheme: GrokTheme?
    /// The guide the Docs window should show next. Each request is new, so repeating one still scrolls.
    @Published var guideRequest: GuideRequest?
    @Published private(set) var exploredTutorialTopics: Set<String> = []

    var themePreferences = GrokThemePreferences()
    var tutorialDefaults: UserDefaults = .standard { didSet { reloadTutorialProgress() } }
    var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }
    /// The `appearance` preference from before a preview, restored when it is cancelled.
    private var previewOrigin: String?
    /// `[ui].theme` as last read or written, to notice when the terminal changes it.
    private var lastConfigTheme: String?
    private var activationObserver: NSObjectProtocol?
    /// Serial, so the last theme chosen is the last one written.
    private let configWriter = DispatchQueue(label: "dev.chenli.crok.desktop.theme-config", qos: .utility)

    static let tutorialProgressKey = "tutorialExploredTopics"

    struct GuideRequest: Equatable {
        let id = UUID()
        /// Nil opens the browser without changing its selection.
        var fileName: String?
        var anchor: String?
    }

    init(store: AppStore) {
        self.store = store
        activeTheme = Theme.palette.theme
        reloadTutorialProgress()
        // The terminal may have switched themes while Crok Desktop was in the background.
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncThemeFromConfig() }
        }
    }

    deinit { if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) } }

    /// Return true to consume a harness notification (see `DesktopFeatures.handle`).
    func handle(method: String, params: [String: Any], update: [String: Any]?, conversationID: UUID) -> Bool { false }

    // MARK: Theme

    /// Applies the saved theme before the first window draws, reading `[ui].theme` so the
    /// terminal and the desktop agree. With no saved theme the default look and any existing
    /// `appearance` preference are left alone.
    static func restoreSavedTheme(_ preferences: GrokThemePreferences = GrokThemePreferences()) {
        guard let theme = preferences.savedTheme() else { return }
        Theme.apply(theme)
        preferences.saveLocally(theme)
    }

    /// `/theme [name]`, alias `/t`: bare cycles to the next theme, a name (or alias) applies it.
    func theme(_ arguments: String) {
        let name = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { setTheme(GrokTheme.next(after: activeTheme, systemIsDark: systemIsDark)); return }
        guard let theme = GrokTheme(name: name) else { store?.banner = GrokTheme.unknownMessage(name); return }
        setTheme(theme)
    }

    /// The "Pick theme" picker, from the command palette.
    func openThemePicker() { store?.sheet = .theme }

    /// Applies and saves a theme, locally and in `config.toml`.
    func setTheme(_ theme: GrokTheme) {
        previewOrigin = nil
        previewedTheme = nil
        activeTheme = theme
        themePreferences.saveLocally(theme)
        show(theme, appearance: theme.appearance)
        store?.banner = "✓ Theme: \(theme.displayName)"
        lastConfigTheme = theme.rawValue
        let url = themePreferences.configURL
        configWriter.async {
            do { try GrokThemePreferences.writeConfig(theme, to: url) }
            catch {
                let message = error.localizedDescription
                DispatchQueue.main.async { [weak self] in self?.store?.banner = "✓ Theme: \(theme.displayName) · not saved to config.toml: \(message)" }
            }
        }
    }

    /// Shows a theme without saving it, as the picker's selection moves.
    func previewTheme(_ theme: GrokTheme) {
        if previewOrigin == nil { previewOrigin = themePreferences.defaults.string(forKey: GrokThemePreferences.appearanceKey) ?? "system" }
        previewedTheme = theme == activeTheme ? nil : theme
        show(theme, appearance: theme.appearance)
    }

    /// Puts back the chosen theme after a preview.
    func cancelThemePreview() {
        guard let origin = previewOrigin else { return }
        previewOrigin = nil
        previewedTheme = nil
        show(activeTheme, appearance: origin)
    }

    /// Follows a `[ui].theme` the terminal wrote since it was last read. Reads are queued behind
    /// writes, so a choice made here is never mistaken for an outside change.
    func syncThemeFromConfig() {
        let url = themePreferences.configURL
        configWriter.async {
            let raw = GrokConfig(url: url).string("theme", in: "ui")
            DispatchQueue.main.async { [weak self] in self?.configThemeDidLoad(raw) }
        }
    }

    private func configThemeDidLoad(_ raw: String?) {
        defer { lastConfigTheme = raw }
        guard let raw, raw != lastConfigTheme, previewOrigin == nil, let theme = GrokTheme(name: raw), theme != activeTheme else { return }
        activeTheme = theme
        themePreferences.saveLocally(theme)
        show(theme, appearance: theme.appearance)
    }

    /// Waits for pending `config.toml` writes; for tests.
    func flushThemeWrites() { configWriter.sync {} }

    private func show(_ theme: GrokTheme, appearance: String) {
        Theme.apply(theme)
        let defaults = themePreferences.defaults
        if defaults.string(forKey: GrokThemePreferences.appearanceKey) != appearance {
            defaults.set(appearance, forKey: GrokThemePreferences.appearanceKey)
        }
        Self.applyWindowAppearance(appearance)
        themeRevision += 1
        // Sheets such as Settings sit outside the rebuilt window content and observe the store.
        store?.objectWillChange.send()
    }

    /// SwiftUI does not always hand a window back to the system appearance when
    /// `preferredColorScheme` returns to nil, so windows are set directly as well.
    private static func applyWindowAppearance(_ value: String) {
        guard let app = NSApp, app.isRunning else { return }
        let appearance = value == "dark" ? NSAppearance(named: .darkAqua) : value == "light" ? NSAppearance(named: .aqua) : nil
        for window in app.windows { window.appearance = appearance }
    }

    private var systemIsDark: Bool {
        switch themePreferences.defaults.string(forKey: GrokThemePreferences.appearanceKey) {
        case "dark": return true
        case "light": return false
        default:
            if let app = NSApp { return app.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
            return UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
        }
    }

    // MARK: Guides

    /// `/docs [web|title]`, aliases `/howto` and `/guides`.
    func openDocs(_ arguments: String) {
        switch GuideDocsTarget(arguments: arguments) {
        case .browse: guideRequest = GuideRequest(fileName: nil); store?.open(.docs)
        case .web: openURL(GuideDocsTarget.onlineURL)
        case .guide(let fileName): openGuide(fileName: fileName)
        case .unknown(let target): store?.banner = GuideDocsTarget.unknownMessage(target)
        }
    }

    func openGuide(fileName: String, anchor: String? = nil) {
        guideRequest = GuideRequest(fileName: fileName, anchor: anchor)
        store?.open(.docs)
    }

    /// Opens a guide by its title, as the tutorial's "Go deeper" names it.
    func openGuide(title: String) {
        guard let entry = GuideLibrary.entry(matching: title) else { openDocs(""); return }
        openGuide(fileName: entry.fileName)
    }

    // MARK: Tutorial

    /// `/tutorial`, aliases `/tour` and `/onboarding`.
    func openTutorial() { store?.open(.tutorial) }

    func markTutorialTopicExplored(_ id: String) {
        guard !exploredTutorialTopics.contains(id) else { return }
        exploredTutorialTopics.insert(id)
        tutorialDefaults.set(exploredTutorialTopics.sorted(), forKey: Self.tutorialProgressKey)
    }

    func resetTutorialProgress() {
        exploredTutorialTopics = []
        tutorialDefaults.removeObject(forKey: Self.tutorialProgressKey)
    }

    private func reloadTutorialProgress() {
        let known = Set(GrokTutorial.topics.map(\.id))
        exploredTutorialTopics = Set(tutorialDefaults.stringArray(forKey: Self.tutorialProgressKey) ?? []).intersection(known)
    }

    // MARK: Other

    /// Bare `/gboom`.
    func openGboom() { store?.open(.gboom) }
    /// Keyboard shortcuts reference, from `/help`.
    func openKeyboardShortcuts() { store?.sheet = .keyboardShortcuts }
}

// MARK: - Theme picker

/// The terminal's "Pick theme" list: moving the selection previews the theme live, Apply saves
/// it, and Cancel (or Esc) puts the previous one back.
struct ThemeSheet: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var extras: ExtrasFeatureModel
    @State private var selection: GrokTheme?
    @State private var committed = false
    @FocusState private var focused: Bool

    private static let rows: [GrokTheme] = [.auto] + GrokTheme.concrete

    var body: some View {
        DesktopPanel(title: "Pick theme", subtitle: "Select a theme to preview it. Crok Build in the terminal shares this setting.", width: 620, onClose: cancel) {
            VStack(spacing: 4) {
                ForEach(Self.rows) { theme in
                    ThemePickerRow(theme: theme, isSelected: theme == current, isActive: theme == extras.activeTheme)
                        .onTapGesture { select(theme) }
                }
            }
            .padding(14)
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(.upArrow) { move(-1); return .handled }
            .onKeyPress(.downArrow) { move(1); return .handled }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Themes")
        } footer: {
            Text("↑↓ Preview   ↵ Apply   esc Cancel").font(.system(size: 11)).foregroundStyle(Theme.muted)
            Spacer()
            Button("Cancel", action: cancel)
            Button("Apply", action: apply).keyboardShortcut(.defaultAction)
        }
        .onAppear { focused = true }
        .onDisappear { if !committed { extras.cancelThemePreview() } }
    }

    private var current: GrokTheme { selection ?? extras.activeTheme }

    private func select(_ theme: GrokTheme) {
        selection = theme
        extras.previewTheme(theme)
    }

    private func move(_ delta: Int) {
        let index = Self.rows.firstIndex(of: current) ?? 0
        select(Self.rows[min(max(0, index + delta), Self.rows.count - 1)])
    }

    private func apply() {
        committed = true
        extras.setTheme(current)
        store.sheet = nil
    }

    private func cancel() {
        committed = true
        extras.cancelThemePreview()
        store.sheet = nil
    }
}

private struct ThemePickerRow: View {
    let theme: GrokTheme
    let isSelected: Bool
    let isActive: Bool
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 14) {
            ThemeSwatch(theme: theme).frame(width: 92, height: 58)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(theme.pickerLabel).font(.system(size: 14, weight: .semibold))
                    if isActive { Text("(active)").font(.system(size: 13)).foregroundStyle(Theme.muted) }
                }
                Text(theme == .auto ? theme.summary : "\(theme.displayName) · \(theme.summary)")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Image(systemName: "checkmark").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accent)
                .opacity(isSelected ? 1 : 0).accessibilityHidden(true)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(isSelected ? Theme.hover : hovered ? Theme.hover.opacity(0.5) : .clear, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(isSelected ? Theme.accent.opacity(0.7) : .clear, lineWidth: 1.5))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(theme.displayName)\(isActive ? ", active" : "")")
        .accessibilityValue(theme.summary)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// A miniature window painted in a theme's colours. Auto shows its light and dark halves.
struct ThemeSwatch: View {
    let theme: GrokTheme

    var body: some View {
        let palette = ThemePalette.palette(for: theme)
        Group {
            if theme == .auto {
                ZStack {
                    ThemeSwatchCanvas(colors: .init(palette, dark: false))
                    ThemeSwatchCanvas(colors: .init(palette, dark: true))
                        .mask(GeometryReader { geometry in
                            Path { path in
                                path.move(to: CGPoint(x: geometry.size.width * 0.62, y: 0))
                                path.addLine(to: CGPoint(x: geometry.size.width, y: 0))
                                path.addLine(to: CGPoint(x: geometry.size.width, y: geometry.size.height))
                                path.addLine(to: CGPoint(x: geometry.size.width * 0.38, y: geometry.size.height))
                            }
                        })
                }
            } else {
                ThemeSwatchCanvas(colors: .init(palette, dark: theme.appearance == "dark"))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.14), lineWidth: 1))
        .accessibilityHidden(true)
    }
}

private struct ThemeSwatchCanvas: View {
    struct Colors {
        var canvas, sidebar, surface, hover, line, ink, muted, accent, green: Color

        /// Resolves dynamic system colours for one appearance, so the swatch never follows the window.
        init(_ palette: ThemePalette, dark: Bool) {
            func resolve(_ color: NSColor) -> Color {
                var result = color
                NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
                    result = color.usingColorSpace(.sRGB) ?? color
                }
                return Color(nsColor: result)
            }
            canvas = resolve(palette.canvasNS); sidebar = resolve(palette.sidebarNS); surface = resolve(palette.surfaceNS)
            hover = resolve(palette.hoverNS); line = resolve(palette.lineNS); ink = resolve(palette.inkNS)
            muted = resolve(palette.mutedNS); accent = resolve(palette.accentNS); green = resolve(palette.greenNS)
        }
    }

    let colors: Colors

    var body: some View {
        Canvas { context, size in
            let w = size.width, h = size.height
            func bar(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, _ color: Color) {
                context.fill(Path(roundedRect: CGRect(x: x, y: y, width: width, height: height), cornerRadius: height / 2), with: .color(color))
            }
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(colors.canvas))
            let sidebarWidth = w * 0.28
            context.fill(Path(CGRect(x: 0, y: 0, width: sidebarWidth, height: h)), with: .color(colors.sidebar))
            context.fill(Path(CGRect(x: sidebarWidth, y: 0, width: 0.75, height: h)), with: .color(colors.line))
            context.fill(Path(roundedRect: CGRect(x: w * 0.03, y: h * 0.26, width: sidebarWidth - w * 0.06, height: h * 0.13), cornerRadius: 2), with: .color(colors.hover))
            for (index, fraction) in [0.62, 0.7, 0.5, 0.58].enumerated() {
                bar(w * 0.06, h * (0.12 + 0.16 * CGFloat(index)) + h * 0.03, (sidebarWidth - w * 0.1) * fraction, h * 0.055, colors.muted.opacity(0.75))
            }
            let left = sidebarWidth + w * 0.07
            bar(left + w * 0.24, h * 0.12, w * 0.33, h * 0.09, colors.hover)
            bar(left, h * 0.3, w * 0.5, h * 0.06, colors.ink.opacity(0.85))
            bar(left, h * 0.41, w * 0.38, h * 0.06, colors.muted)
            bar(left, h * 0.52, w * 0.17, h * 0.06, colors.accent)
            bar(left + w * 0.19, h * 0.52, w * 0.12, h * 0.06, colors.green)
            let composer = CGRect(x: left - w * 0.02, y: h * 0.68, width: w - left - w * 0.04, height: h * 0.22)
            context.fill(Path(roundedRect: composer, cornerRadius: 4), with: .color(colors.surface))
            context.stroke(Path(roundedRect: composer, cornerRadius: 4), with: .color(colors.line), lineWidth: 0.75)
            let dot = h * 0.11
            context.fill(Path(ellipseIn: CGRect(x: composer.maxX - dot - w * 0.025, y: composer.midY - dot / 2, width: dot, height: dot)), with: .color(colors.accent))
        }
    }
}

// MARK: - Settings

/// Theme preferences in Settings: the same themes as `/theme`, applied as soon as one is clicked,
/// and how transparent the windows' glass is.
struct AppearanceSettingsSection: View {
    @EnvironmentObject var extras: ExtrasFeatureModel
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage(GlassPreference.key) private var transparency = GlassPreference.defaultLevel

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Theme", systemImage: "paintpalette").font(.system(size: 15, weight: .semibold))
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach([GrokTheme.auto] + GrokTheme.concrete) { theme in
                    ThemeSettingsCard(theme: theme, isActive: theme == extras.activeTheme) { extras.setTheme(theme) }
                }
            }
            Divider().padding(.vertical, 4)
            HStack(spacing: 12) {
                Label("Transparency", systemImage: "circle.lefthalf.filled").font(.system(size: 13, weight: .medium))
                    .frame(width: 130, alignment: .leading)
                Text("Solid").font(.system(size: 11)).foregroundStyle(Theme.muted)
                Slider(value: $transparency, in: 0...1).controlSize(.small)
                    .accessibilityLabel("Window transparency")
                    .accessibilityValue("\(Int((transparency * 100).rounded())) percent")
                Text("Clear").font(.system(size: 11)).foregroundStyle(Theme.muted)
            }
            .disabled(reduceTransparency)
            if reduceTransparency {
                Text("Windows stay solid while Reduce Transparency is on.")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct ThemeSettingsCard: View {
    let theme: GrokTheme
    let isActive: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                ThemeSwatch(theme: theme).frame(height: 64)
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(isActive ? Theme.accent : .clear, lineWidth: 2))
                HStack(spacing: 5) {
                    Text(theme == .auto ? "Auto" : theme.displayName).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Spacer(minLength: 2)
                    if isActive { Image(systemName: "checkmark.circle.fill").font(.system(size: 13)).foregroundStyle(Theme.accent) }
                }
            }
            .padding(8)
            .background(hovered ? Theme.hover.opacity(0.6) : .clear, in: RoundedRectangle(cornerRadius: 11))
            .contentShape(RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(theme.summary)
        .accessibilityLabel("\(theme.displayName) theme")
        .accessibilityValue(isActive ? "Active" : "")
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}
