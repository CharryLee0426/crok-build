import AppKit
import Foundation

/// The terminal's themes, with the names and aliases `/theme` accepts
/// (`ThemeKind` in `xai-grok-pager-render/src/theme/mod.rs`). The terminal-only `terminal`
/// theme is left out: it paints the terminal's own background, which a window does not have.
enum GrokTheme: String, CaseIterable, Identifiable {
    case auto
    case groknight
    case grokday
    case tokyonight
    case rosepineMoon = "rosepine-moon"
    case oscuraMidnight = "oscura-midnight"

    var id: String { rawValue }

    /// The themes bare `/theme` cycles through, in the terminal's order; `auto` is not one of them.
    static let concrete: [GrokTheme] = [.groknight, .grokday, .tokyonight, .rosepineMoon, .oscuraMidnight]

    var aliases: [String] {
        switch self {
        case .auto: return ["system"]
        case .groknight: return ["grok-night", "dark"]
        case .grokday: return ["grok-day", "light", "day"]
        case .tokyonight: return ["tokyo-night", "tokyo"]
        case .rosepineMoon: return ["rosepine", "rose-pine", "rose-pine-moon"]
        case .oscuraMidnight: return ["oscura"]
        }
    }

    /// Case-insensitive, like the terminal's `ThemeKind::from_name`.
    init?(name: String) {
        let lower = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let theme = Self.allCases.first(where: { $0.rawValue == lower || $0.aliases.contains(lower) }) else { return nil }
        self = theme
    }

    /// The name in confirmations, as the terminal's `display_name_for_canonical` spells it
    /// (which has no entry for Oscura Midnight and falls back to its config name).
    var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .groknight: return "Crok Night"
        case .grokday: return "Crok Day"
        case .tokyonight: return "Tokyo Night"
        case .rosepineMoon: return "Rose Pine Moon"
        case .oscuraMidnight: return "Oscura Midnight"
        }
    }

    /// The picker row label, as in the terminal's "Pick theme" list.
    var pickerLabel: String { self == .auto ? "auto (follow system)" : rawValue }

    var summary: String {
        switch self {
        case .auto: return "Crok Desktop's own look, light or dark with your Mac. The terminal stays dark."
        case .groknight: return "Neutral dark base with a magenta accent. The terminal's default."
        case .grokday: return "Light theme with deepened accents for bright rooms."
        case .tokyonight: return "Dark, blue-tinted backgrounds from the Tokyo Night palette."
        case .rosepineMoon: return "Muted dark palette with mauve accents, from the Rosé Pine family."
        case .oscuraMidnight: return "Deep near-black base with purple accents."
        }
    }

    /// The window appearance the theme needs: the `appearance` preference the app already honours.
    var appearance: String {
        switch self {
        case .auto: return "system"
        case .grokday: return "light"
        default: return "dark"
        }
    }

    /// What bare `/theme` switches to. `auto` counts as the theme the window currently looks
    /// like (Grok Night when dark, Grok Day when light); the terminal's `auto` is always dark.
    static func next(after current: GrokTheme, systemIsDark: Bool) -> GrokTheme {
        let resolved = current == .auto ? (systemIsDark ? .groknight : .grokday) : current
        let index = concrete.firstIndex(of: resolved) ?? 0
        return concrete[(index + 1) % concrete.count]
    }

    static func unknownMessage(_ name: String) -> String {
        "Unknown theme: \(name). Available: auto, " + concrete.map(\.rawValue).joined(separator: ", ")
    }
}

/// Where the chosen theme is kept: `[ui].theme` in `config.toml`, shared with the terminal, plus
/// UserDefaults (the theme, and the window `appearance` it implies) for the desktop itself.
struct GrokThemePreferences {
    static let themeKey = "theme"
    static let appearanceKey = "appearance"

    var defaults: UserDefaults = .standard
    var configURL: URL = GrokPaths.configFile

    /// The saved theme, or nil when none was ever chosen. The terminal's setting wins so both
    /// clients agree; a name only the terminal knows (such as `terminal`) is skipped.
    func savedTheme() -> GrokTheme? {
        let config = GrokConfig(url: configURL)
        if let name = config.string("theme", in: "ui"), let theme = GrokTheme(name: name) { return theme }
        // The terminal still reads a legacy top-level `theme = "…"`.
        if let name = Self.topLevelString("theme", in: config.text), let theme = GrokTheme(name: name) { return theme }
        return defaults.string(forKey: Self.themeKey).flatMap(GrokTheme.init(name:))
    }

    /// Records the choice for the desktop. `writeConfig` shares it with the terminal.
    func saveLocally(_ theme: GrokTheme) {
        defaults.set(theme.rawValue, forKey: Self.themeKey)
        defaults.set(theme.appearance, forKey: Self.appearanceKey)
    }

    /// Static so it can run off the main thread with nothing but the file's URL.
    static func writeConfig(_ theme: GrokTheme, to url: URL) throws {
        try GrokConfig.update(url: url) { try $0.set("theme", to: .string(theme.rawValue), in: "ui") }
    }

    private static func topLevelString(_ key: String, in text: String) -> String? {
        for line in text.components(separatedBy: "\n") {
            if GrokConfig.headerName(line) != nil || line.trimmingCharacters(in: .whitespaces).hasPrefix("[[") { break }
            if let (name, value) = GrokConfig.keyValue(line), name == key { return GrokConfig.unquote(value) }
        }
        return nil
    }
}
