import SwiftUI
import AppKit

/// The app's colours. Every accessor reads the active `ThemePalette`, which `/theme` swaps;
/// the main window rebuilds its views when it does (see `ExtrasFeatureModel.themeRevision`).
enum Theme {
    static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color { Color(nsColor: adaptiveNS(light, dark)) }
    static func adaptiveNS(_ light: UInt32, _ dark: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(name: nil) { appearance in
            (appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? rgb(dark) : rgb(light)).withAlphaComponent(alpha)
        }
    }
    /// Black in light mode and white in dark mode, at the given strengths: a fill that reads on any glass.
    static func tintNS(light: CGFloat, dark: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 1, alpha: dark) : NSColor(white: 0, alpha: light)
        }
    }
    static func rgb(_ value: UInt32) -> NSColor {
        NSColor(srgbRed: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255, alpha: 1)
    }

    /// Written on the main thread only, when a theme is applied or previewed.
    private(set) static var palette = ThemePalette.auto

    static func apply(_ theme: GrokTheme) { palette = ThemePalette.palette(for: theme) }

    static var canvas: Color { palette.canvas }
    static var sidebar: Color { palette.sidebar }
    static var sidebarBackground: Color { palette.sidebarBackground }
    static var surface: Color { palette.surface }
    static var input: Color { palette.input }
    static var hover: Color { palette.hover }
    static var line: Color { palette.line }
    static var ink: Color { palette.ink }
    static var muted: Color { palette.muted }
    static var accentNS: NSColor { palette.accentNS }
    static var greenNS: NSColor { palette.greenNS }
    static var redNS: NSColor { palette.redNS }
    static var accent: Color { palette.accent }
    static var green: Color { palette.green }
    static var red: Color { palette.red }
    static var codeBackgroundNS: NSColor { palette.codeBackgroundNS }
    static var inlineCodeNS: NSColor { palette.inlineCodeNS }
    static var tableHeaderNS: NSColor { palette.tableHeaderNS }
    static var codeBackground: Color { palette.codeBackground }
    static var inlineCode: Color { palette.inlineCode }
    static var tableHeader: Color { palette.tableHeader }
    static var tableStripe: Color { palette.tableStripe }
}

/// One theme's colours. A class, so reading a colour through `Theme` copies a single reference.
///
/// `canvas` and `sidebarBackground` are the opaque colours the window's glass is tinted with
/// (see `GlassBackdrop`). The default look's other roles are translucent tints, so cards, fields,
/// and highlights take on whatever the glass shows; the terminal palettes keep their opaque colours.
final class ThemePalette {
    let theme: GrokTheme
    /// The default look follows the system's materials; the terminal palettes tint the glass with their own colours.
    let usesSystemMaterials: Bool
    let canvasNS, sidebarNS, surfaceNS, inputNS, hoverNS, lineNS, inkNS, mutedNS: NSColor
    let accentNS, greenNS, redNS, codeBackgroundNS, inlineCodeNS, tableHeaderNS, tableStripeNS: NSColor
    let sidebarBackgroundNS: NSColor
    let canvas, sidebar, surface, input, hover, line, ink, muted: Color
    let accent, green, red, codeBackground, inlineCode, tableHeader, tableStripe: Color
    let sidebarBackground: Color

    init(theme: GrokTheme, usesSystemMaterials: Bool = false,
         canvas: NSColor, sidebar: NSColor, sidebarBackground: NSColor? = nil, surface: NSColor, input: NSColor, hover: NSColor, line: NSColor, ink: NSColor, muted: NSColor,
         accent: NSColor, green: NSColor, red: NSColor, codeBackground: NSColor, inlineCode: NSColor, tableHeader: NSColor, tableStripe: NSColor) {
        self.theme = theme
        self.usesSystemMaterials = usesSystemMaterials
        canvasNS = canvas; sidebarNS = sidebar; surfaceNS = surface; inputNS = input; hoverNS = hover; lineNS = line; inkNS = ink; mutedNS = muted
        accentNS = accent; greenNS = green; redNS = red; codeBackgroundNS = codeBackground; inlineCodeNS = inlineCode
        tableHeaderNS = tableHeader; tableStripeNS = tableStripe
        sidebarBackgroundNS = sidebarBackground ?? sidebar
        self.canvas = Color(nsColor: canvas); self.sidebar = Color(nsColor: sidebar); self.surface = Color(nsColor: surface)
        self.input = Color(nsColor: input); self.hover = Color(nsColor: hover); self.line = Color(nsColor: line)
        self.ink = Color(nsColor: ink); self.muted = Color(nsColor: muted); self.accent = Color(nsColor: accent)
        self.green = Color(nsColor: green); self.red = Color(nsColor: red); self.codeBackground = Color(nsColor: codeBackground)
        self.inlineCode = Color(nsColor: inlineCode); self.tableHeader = Color(nsColor: tableHeader); self.tableStripe = Color(nsColor: tableStripe)
        self.sidebarBackground = Color(nsColor: sidebarBackgroundNS)
    }

    /// Terminal palettes are opaque colours from the pager's themes
    /// (`xai-grok-pager-render/src/theme/*.rs`), in the roles the desktop draws.
    private convenience init(_ theme: GrokTheme, canvas: UInt32, sidebar: UInt32, surface: UInt32, input: UInt32, hover: UInt32, line: UInt32,
                             ink: UInt32, muted: UInt32, accent: UInt32, green: UInt32, red: UInt32,
                             codeBackground: UInt32, inlineCode: UInt32, tableHeader: UInt32, tableStripe: UInt32) {
        self.init(theme: theme, canvas: Theme.rgb(canvas), sidebar: Theme.rgb(sidebar), surface: Theme.rgb(surface), input: Theme.rgb(input),
                  hover: Theme.rgb(hover), line: Theme.rgb(line), ink: Theme.rgb(ink), muted: Theme.rgb(muted), accent: Theme.rgb(accent),
                  green: Theme.rgb(green), red: Theme.rgb(red), codeBackground: Theme.rgb(codeBackground), inlineCode: Theme.rgb(inlineCode),
                  tableHeader: Theme.rgb(tableHeader), tableStripe: Theme.rgb(tableStripe))
    }

    /// The desktop's own look, following the system appearance: glass, with translucent fills.
    static let auto = ThemePalette(
        theme: .auto, usesSystemMaterials: true,
        canvas: Theme.adaptiveNS(0xFAFAFC, 0x1C1C1E), sidebar: Theme.tintNS(light: 0.05, dark: 0.07), sidebarBackground: Theme.adaptiveNS(0xF4F4F7, 0x1E1E21),
        surface: Theme.adaptiveNS(0xFFFFFF, 0x2C2C30, alpha: 0.66),
        input: Theme.tintNS(light: 0.04, dark: 0.06), hover: Theme.tintNS(light: 0.065, dark: 0.09), line: .separatorColor,
        ink: .labelColor, muted: .secondaryLabelColor, accent: Theme.adaptiveNS(0x41634C, 0xA1BFA8), green: Theme.adaptiveNS(0x3B7751, 0x91C5A1),
        red: Theme.adaptiveNS(0xB3261E, 0xF2877E), codeBackground: Theme.tintNS(light: 0.045, dark: 0.055), inlineCode: Theme.tintNS(light: 0.065, dark: 0.09),
        tableHeader: Theme.tintNS(light: 0.05, dark: 0.065), tableStripe: Theme.tintNS(light: 0.02, dark: 0.025))

    /// Grok Night: neutral grays with TokyoNight accents (groknight.rs).
    static let grokNight = ThemePalette(
        .groknight, canvas: 0x141414, sidebar: 0x111111, surface: 0x242424, input: 0x1C1C1C, hover: 0x2C2C2C, line: 0x323237,
        ink: 0xE1E1E1, muted: 0x787878, accent: 0xBB9AF7, green: 0x9ECE6A, red: 0xF7768E,
        codeBackground: 0x1C1C1C, inlineCode: 0x242424, tableHeader: 0x242424, tableStripe: 0x1C1C1C)

    /// Grok Day: the light counterpart (grokday.rs).
    static let grokDay = ThemePalette(
        .grokday, canvas: 0xEEEEEE, sidebar: 0xE4E4E4, surface: 0xF5F5F5, input: 0xEEEEEE, hover: 0xDEDEDE, line: 0xC8C8CD,
        ink: 0x262626, muted: 0x626262, accent: 0x7D4BC6, green: 0x378E23, red: 0xCD3048,
        codeBackground: 0xE4E4E4, inlineCode: 0xDEDEDE, tableHeader: 0xE4E4E4, tableStripe: 0xEAEAEA)

    /// Tokyo Night Storm (tokyonight.rs).
    static let tokyoNight = ThemePalette(
        .tokyonight, canvas: 0x24283B, sidebar: 0x1F2335, surface: 0x292E42, input: 0x1F2335, hover: 0x283457, line: 0x3B4261,
        ink: 0xC0CAF5, muted: 0x737AA2, accent: 0xBB9AF7, green: 0x9ECE6A, red: 0xF7768E,
        codeBackground: 0x292E42, inlineCode: 0x292E42, tableHeader: 0x292E42, tableStripe: 0x1F2335)

    /// Rosé Pine Moon (rosepine.rs).
    static let rosePineMoon = ThemePalette(
        .rosepineMoon, canvas: 0x232136, sidebar: 0x2A273F, surface: 0x393552, input: 0x232136, hover: 0x44415A, line: 0x44415A,
        ink: 0xE0DEF4, muted: 0x908CAA, accent: 0xC4A7E7, green: 0x9CCFD8, red: 0xEB6F92,
        codeBackground: 0x2A273F, inlineCode: 0x393552, tableHeader: 0x393552, tableStripe: 0x2A283E)

    /// Oscura Midnight: near-black with purple hints (oscura.rs).
    static let oscuraMidnight = ThemePalette(
        .oscuraMidnight, canvas: 0x030304, sidebar: 0x0F1216, surface: 0x0F1216, input: 0x040507, hover: 0x242034, line: 0x343048,
        ink: 0xE4E4E4, muted: 0x81868F, accent: 0x9B7ECE, green: 0x50B48C, red: 0xDC5A64,
        codeBackground: 0x26292F, inlineCode: 0x26292F, tableHeader: 0x0F1216, tableStripe: 0x12101C)

    static func palette(for theme: GrokTheme) -> ThemePalette {
        switch theme {
        case .auto: return auto
        case .groknight: return grokNight
        case .grokday: return grokDay
        case .tokyonight: return tokyoNight
        case .rosepineMoon: return rosePineMoon
        case .oscuraMidnight: return oscuraMidnight
        }
    }
}

/// How much of the desktop shows through the windows: Settings › Appearance › Transparency.
enum GlassPreference {
    static let key = "windowTransparency"
    /// 0 paints solid colours; 1 is the clearest glass.
    static let defaultLevel = 0.8

    static var level: Double { UserDefaults.standard.object(forKey: key) as? Double ?? defaultLevel }

    /// How strongly a region's colour covers the blurred desktop, from 1 (solid) down.
    /// The sidebar clears first and is bare glass from the default level up; the conversation
    /// keeps enough colour to read comfortably; sheets stay the most solid.
    /// The terminal palettes keep more of their own colour so each stays recognisable.
    static func tintOpacity(for role: GlassBackdrop.Role, level: Double, systemLook: Bool) -> Double {
        let clarity = min(1, max(0, level)) * (systemLook ? 1 : 0.6)
        switch role {
        case .canvas: return 1 - 0.78 * clarity
        case .sidebar: return max(0, 1 - 1.15 * clarity)
        case .panel: return 1 - 0.9 * clarity
        case .sheet: return 1 - 0.5 * clarity
        }
    }
}

/// A window region's background: the blurred desktop behind the window, tinted with the theme's
/// colour at the strength the Transparency setting asks for. With Reduce Transparency, or the
/// setting at Solid, it is the solid colour.
struct GlassBackdrop: View {
    enum Role { case canvas, sidebar, panel, sheet }

    var role: Role
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage(GlassPreference.key) private var level = GlassPreference.defaultLevel

    var body: some View {
        let palette = Theme.palette
        let effectiveLevel = reduceTransparency ? 0 : level
        let opacity = GlassPreference.tintOpacity(for: role, level: effectiveLevel, systemLook: palette.usesSystemMaterials)
        ZStack {
            if opacity < 1 { BehindWindowBlur() }
            (role == .sidebar ? palette.sidebarBackground : palette.canvas).opacity(opacity)
        }
        .accessibilityHidden(true)
    }
}

/// The desktop behind the window, blurred. Stays live while the window is inactive.
private struct BehindWindowBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// Frosted glass under the window's title and toolbar, so the conversation blurs as it scrolls
/// beneath them instead of running into the title. It fades out below the toolbar, like the
/// system's soft scroll edge. In full screen the system's own title bar background is cleared
/// (see `FullScreenTitlebar`), so this same glass shows there too.
struct TitleBarGlass: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var chrome = WindowChrome()
    /// How far below the toolbar the blur fades out.
    static let fade: CGFloat = 18

    var body: some View {
        // The conversation runs under the toolbar, so the safe area can't say how tall the title
        // bar is; the window can.
        ZStack(alignment: .top) {
            Color.clear
            let inset = chrome.titleBarHeight
            if inset > 0 {
                let height = inset + Self.fade
                let palette = Theme.palette
                ZStack {
                    if reduceTransparency {
                        palette.canvas
                    } else {
                        WithinWindowBlur()
                        // The terminal palettes tint the glass with their own colour.
                        palette.canvas.opacity(palette.usesSystemMaterials ? 0.18 : 0.55)
                    }
                }
                .mask {
                    LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: inset / height * 0.8),
                                           .init(color: .black.opacity(0.55), location: inset / height), .init(color: .clear, location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                }
                .overlay(alignment: .top) {
                    // A hairline where the toolbar ends, like the edge of a glass pane.
                    Rectangle().fill(Color.white.opacity(0.08)).frame(height: 0.5).offset(y: inset)
                }
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea(edges: .top)
        .background(WindowChromeReader(chrome: $chrome))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// What the window's own chrome takes up.
struct WindowChrome: Equatable {
    var isFullScreen = false
    /// The title bar and toolbar above the content layout area.
    var titleBarHeight: CGFloat = 0
}

/// The window's content behind this view, blurred.
private struct WithinWindowBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = PassthroughEffectView()
        view.material = .headerView
        view.blendingMode = .withinWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}

    /// Decoration only: clicks and scrolls go to the content underneath.
    private final class PassthroughEffectView: NSVisualEffectView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// Reports whether the hosting window is in full screen, and how tall its title bar is.
struct WindowChromeReader: NSViewRepresentable {
    @Binding var chrome: WindowChrome

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onChange = { value in if chrome != value { chrome = value } }
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) {
        view.onChange = { value in if chrome != value { chrome = value } }
    }

    final class ReaderView: NSView {
        var onChange: ((WindowChrome) -> Void)?
        private var observers: [NSObjectProtocol] = []
        private var reported: WindowChrome?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            reported = nil
            guard let window else { return }
            // "Will enter" hides the glass before the full-screen animation; "will exit" brings it back as the window returns.
            let transitions: [(NSNotification.Name, Bool?)] = [
                (NSWindow.willEnterFullScreenNotification, true), (NSWindow.didEnterFullScreenNotification, true),
                (NSWindow.willExitFullScreenNotification, false), (NSWindow.didExitFullScreenNotification, false),
                (NSWindow.didResizeNotification, nil),
            ]
            for (name, fullScreen) in transitions {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.report(fullScreen: fullScreen) }
                })
            }
            DispatchQueue.main.async { [weak self] in self?.report(fullScreen: nil) }
        }

        /// The toolbar showing or hiding lays the content out again.
        override func layout() {
            super.layout()
            DispatchQueue.main.async { [weak self] in self?.report(fullScreen: nil) }
        }

        private func report(fullScreen: Bool?) {
            guard let window else { return }
            let isFullScreen = fullScreen ?? window.styleMask.contains(.fullScreen)
            if isFullScreen {
                FullScreenTitlebar.clear()
                // The toolbar moves into its own window during the transition; catch it once it has settled.
                if fullScreen == true {
                    for delay in [0.15, 0.7] { DispatchQueue.main.asyncAfter(deadline: .now() + delay) { FullScreenTitlebar.clear() } }
                }
            }
            let height = max(0, window.frame.height - window.contentLayoutRect.height)
            let chrome = WindowChrome(isFullScreen: isFullScreen, titleBarHeight: height)
            guard chrome != reported else { return }
            reported = chrome
            onChange?(chrome)
        }

        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }
}

/// In full screen AppKit moves the title bar and toolbar into a window of their own. That window
/// can't see the conversation beneath it, so its scroll-edge background falls back to an opaque
/// bar in a different colour from the window. Clearing it lets the window's own glass
/// (`GlassBackdrop` and `TitleBarGlass`) show through, as it does outside full screen.
@MainActor
enum FullScreenTitlebar {
    /// The title bar's backgrounds, by class name: an opaque fill with the scroll-edge pocket, the
    /// separator, and the sidebar's piece of glass inside. They are private classes, so a macOS
    /// that renames them just keeps its own bar.
    private static let backgrounds: Set<String> = ["NSTitlebarBackgroundView"]

    static func clear() {
        for window in NSApp.windows where String(describing: type(of: window)) == "NSToolbarFullScreenWindow" {
            window.backgroundColor = .clear
            if let frame = window.contentView?.superview { clear(frame) }
        }
    }

    private static func clear(_ view: NSView) {
        if backgrounds.contains(String(describing: type(of: view))) {
            if view.alphaValue != 0 { view.alphaValue = 0 }
            return
        }
        for subview in view.subviews { clear(subview) }
    }
}

extension View {
    /// Liquid Glass belongs to controls above content, rather than the transcript itself.
    func glassSurface(cornerRadius: CGFloat = 16, interactive: Bool = false) -> some View {
        modifier(GlassSurface(shape: RoundedRectangle(cornerRadius: cornerRadius), interactive: interactive))
    }

    func glassSurface<S: InsettableShape>(in shape: S, interactive: Bool = false) -> some View {
        modifier(GlassSurface(shape: shape, interactive: interactive))
    }

    /// The window toolbar draws no background of its own, so the window's glass runs under it.
    func themedToolbarBackground() -> some View {
        toolbarBackground(.hidden, for: .windowToolbar)
    }

    /// A sheet's background: glass over the window behind it.
    func glassSheetBackground() -> some View {
        background { GlassBackdrop(role: .sheet).ignoresSafeArea() }
    }

    /// A secondary window's background, the same glass as the main window's conversation.
    func glassWindowBackground() -> some View {
        background { GlassBackdrop(role: .canvas).ignoresSafeArea() }
    }
}

private struct GlassSurface<S: InsettableShape>: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var shape: S
    var interactive: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Theme.surface, in: shape)
                .overlay(shape.strokeBorder(Theme.line, lineWidth: 1))
        } else {
            // SwiftUI 7 is the macOS 26 SDK; a Swift 6.2 compiler can still build against an older SDK without glass.
            #if canImport(SwiftUI, _version: 7)
            if #available(macOS 26.0, *) {
                // The system tints its glass; a terminal palette's glass takes the palette's surface colour.
                let tint: Color? = Theme.palette.usesSystemMaterials ? nil : Theme.surface.opacity(0.55)
                content.glassEffect(interactive ? .regular.tint(tint).interactive() : .regular.tint(tint), in: shape)
            } else {
                materialSurface(content)
            }
            #else
            materialSurface(content)
            #endif
        }
    }

    private func materialSurface(_ content: Content) -> some View {
        content.background(Theme.palette.usesSystemMaterials ? AnyShapeStyle(.thinMaterial) : AnyShapeStyle(Theme.surface.opacity(0.85)), in: shape)
            .overlay(shape.strokeBorder(Theme.line.opacity(0.6), lineWidth: 0.5))
    }
}

/// The sidebar's glass, the most transparent part of the window.
struct SidebarMaterial: View {
    var body: some View { GlassBackdrop(role: .sidebar) }
}

struct IconButton: View {
    var icon: String
    var help: String
    var size: CGFloat = 32
    var action: () -> Void
    @State private var isHovered = false
    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: size * 0.47, weight: .medium)).frame(width: size, height: size)
                .background(isHovered ? Theme.hover.opacity(0.8) : .clear, in: RoundedRectangle(cornerRadius: size / 4))
                .contentShape(Rectangle())
        }
            .buttonStyle(.plain).foregroundStyle(Theme.muted).help(help).accessibilityLabel(help)
            .onHover { isHovered = $0 }
    }
}

struct GrokMark: View {
    var size: CGFloat = 28
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.29).fill(Theme.ink)
            GrokSymbol().fill(Theme.canvas).frame(width: size * 0.76, height: size * 0.76)
        }.frame(width: size, height: size).accessibilityLabel("Crok")
    }
}

struct SubtleButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.padding(.horizontal, 13).padding(.vertical, 8)
            .background(configuration.isPressed || hovered ? Theme.hover : Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.line, lineWidth: 0.5))
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { hovered = $0 }
    }
}
