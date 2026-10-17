import SwiftUI
import AppKit
import BorderBeamKit
import LibrariesDevSupport
import MetalFxKit
import ThinkingOrbsKit
import VoiceGlowKit

/// Crok Desktop's own look: obsidian and porcelain, machined edges, and liquid metal. The effects
/// come from Libraries.dev (vendored in third_party/LibrariesDev): liquid metal for the mark, the
/// greeting, and the send button; a border beam on the composer while a prompt waits for its
/// answer; a voice glow while dictating; thinking orbs wherever the app used to spin.
///
/// Every effect has a plain look it falls back to: when the shaders were not built into the app,
/// when the effects are switched off in Settings › Appearance, or under Reduce Motion (which also
/// stills the orbs). What each costs is measured by `EffectsPerformanceTests`: liquid metal holds a
/// still frame until the pointer comes near or the view first appears, the beam lights only the
/// wait for a turn's first output, and the orbs draw outside SwiftUI, so an idle window does no
/// work per frame and a working one little.
enum Atelier {
    // MARK: Type

    /// The display face for headlines: New York, the system serif.
    static func display(size: CGFloat, weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight, design: .serif) }

    /// Small capitals over a section, letter-spaced like an engraving.
    static let eyebrowSize: CGFloat = 10.5
    static let eyebrowTracking: CGFloat = 1.3

    // MARK: Edges

    /// A machined edge: lit along the top, shaded along the bottom, as light falls on a bevel.
    static func bevel(_ scheme: ColorScheme, strength: Double = 1) -> LinearGradient {
        let stops: [Gradient.Stop] = scheme == .dark
            ? [.init(color: .white.opacity(0.22 * strength), location: 0), .init(color: .white.opacity(0.07 * strength), location: 0.38),
               .init(color: .white.opacity(0.04 * strength), location: 0.7), .init(color: .white.opacity(0.11 * strength), location: 1)]
            : [.init(color: .white.opacity(0.95 * strength), location: 0), .init(color: .black.opacity(0.07 * strength), location: 0.4),
               .init(color: .black.opacity(0.09 * strength), location: 0.75), .init(color: .black.opacity(0.16 * strength), location: 1)]
        return LinearGradient(stops: stops, startPoint: .top, endPoint: .bottom)
    }

    /// The soft shadow a raised card casts.
    static func shadow(_ scheme: ColorScheme) -> Color { .black.opacity(scheme == .dark ? 0.45 : 0.10) }

    /// A static brushed-metal sweep, for the plain look of a metal ring when shaders are off.
    static func brushed(_ finish: MetalFinish) -> AngularGradient {
        AngularGradient(colors: finish.brushedColors + [finish.brushedColors[0]], center: .center, angle: .degrees(-35))
    }
}

// MARK: - Preferences

/// The metal every effect is made of. One finish for the whole window, as metal-fx asks.
enum MetalFinish: String, CaseIterable, Identifiable {
    case champagne, platinum, chromatic
    var id: String { rawValue }

    static let key = "metalFinish"
    static let defaultFinish = MetalFinish.champagne

    static var current: MetalFinish { UserDefaults.standard.string(forKey: key).flatMap(MetalFinish.init(rawValue:)) ?? defaultFinish }

    var displayName: String {
        switch self {
        case .champagne: return L10n.t("metal_finish_champagne", "Champagne")
        case .platinum: return L10n.t("metal_finish_platinum", "Platinum")
        case .chromatic: return L10n.t("metal_finish_chromatic", "Chromatic")
        }
    }

    var preset: MetalPreset {
        switch self {
        case .champagne: return .gold
        case .platinum: return .silver
        case .chromatic: return .chromatic
        }
    }

    var beam: BeamColorVariant {
        switch self {
        case .champagne: return .sunset
        case .platinum: return .mono
        case .chromatic: return .ocean
        }
    }

    var voice: VoiceGlowColorVariant {
        switch self {
        case .champagne: return .gold
        case .platinum: return .ice
        case .chromatic: return .colorful
        }
    }

    /// The accent the interface takes from the metal: selection, starters, the unread dot.
    var accentNS: NSColor {
        switch self {
        case .champagne: return Theme.adaptiveNS(0x8A6A2F, 0xD8BE8C)
        case .platinum: return Theme.adaptiveNS(0x56626F, 0xBCC6D0)
        case .chromatic: return Theme.adaptiveNS(0x3C62B5, 0x9DB9EC)
        }
    }

    /// The sweep a reasoning block's rim and bar run through while the model thinks (see
    /// `ThinkingEffects`): the metal's light travelling along it, ending as it begins.
    var sweepNS: [NSColor] {
        let stops: [UInt32]
        switch self {
        case .champagne: stops = [0x8C6B34, 0xE9D3A4, 0xFFF4DA, 0xC9A35E, 0xFFF4DA, 0xE9D3A4, 0x8C6B34]
        case .platinum: stops = [0x6E7884, 0xC9D1DA, 0xFFFFFF, 0x9AA6B3, 0xFFFFFF, 0xC9D1DA, 0x6E7884]
        case .chromatic: stops = [0x4E7BE0, 0x9FD0FF, 0xF2F7FF, 0xB59CFF, 0xF2F7FF, 0x9FD0FF, 0x4E7BE0]
        }
        return stops.map { Theme.rgb($0) }
    }

    /// Brushed metal, lit and shaded around a ring: the still look of a metal surface.
    var brushedHex: [UInt32] {
        switch self {
        case .champagne: return [0xF6E7C4, 0x9C7A3E, 0xE8D2A0, 0x6E5428, 0xD9BC82]
        case .platinum: return [0xF4F6F8, 0x8C96A2, 0xDDE2E8, 0x5D6670, 0xC3CAD2]
        case .chromatic: return [0xEAF3FF, 0x6F8FD8, 0xD8C8FF, 0x4B6AB0, 0xB7E0FF]
        }
    }

    fileprivate var brushedColors: [Color] { brushedHex.map { Color(nsColor: Theme.rgb($0)) } }
}

/// Settings › Appearance › Effects: the Libraries.dev effects on or off. Off, every effect draws
/// its plain look; the shaders not being built in has the same result.
enum EffectsPreference {
    static let key = "libraryEffects"
    static var enabled: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
    /// Whether the effects that need the compiled shaders can draw.
    static var shadersAvailable: Bool { LibrariesDevShaders.isAvailable }
}

// MARK: - Liveliness

/// Whether a metal surface moves: for a few seconds after it appears, and while the pointer is
/// over it, in the key window, without Reduce Motion. Otherwise it holds its last frame.
struct MetalLiveness: ViewModifier {
    /// For tests, whose windows are never active and never pointed at: metal always moves.
    nonisolated(unsafe) static var alwaysLive = false

    @Binding var live: Bool
    var settle: Double = 4
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appearsActive) private var appearsActive
    @State private var hovered = false
    @State private var introducing = true

    func body(content: Content) -> some View {
        content
            .onHover { hovered = $0; update() }
            .onChange(of: appearsActive) { _, _ in update() }
            .onChange(of: reduceMotion) { _, _ in update() }
            .task {
                update()
                try? await Task.sleep(for: .seconds(settle))
                introducing = false
                update()
            }
    }

    private func update() {
        let value = Self.alwaysLive || (!reduceMotion && appearsActive && (hovered || introducing))
        if live != value { live = value }
    }
}

/// Keeps the pointer's place in the window for metal that bends toward it (`source: .pointer`).
struct MetalPointerFollower: ViewModifier {
    func body(content: Content) -> some View {
        content.onContinuousHover(coordinateSpace: .global) { phase in
            switch phase {
            case .active(let location): MetalPointerSource.shared.location = location
            case .ended: MetalPointerSource.shared.location = nil
            }
        }
    }
}

// MARK: - Liquid metal

/// The Crok mark set in a ring of liquid metal, like a seal. The welcome page's emblem.
struct MetalMedallion: View {
    var size: CGFloat
    @AppStorage(EffectsPreference.key) private var effects = true
    @AppStorage(MetalFinish.key) private var finishName = MetalFinish.defaultFinish.rawValue
    @Environment(\.colorScheme) private var scheme
    @State private var live = false

    private var finish: MetalFinish { MetalFinish(rawValue: finishName) ?? .defaultFinish }
    private var ring: CGFloat { max(2, (size * 0.045).rounded()) }

    var body: some View {
        Group {
            if effects && EffectsPreference.shadersAvailable {
                MetalFx(variant: .circle, preset: finish.preset, theme: .auto, strength: 1, shaderScale: 1.1, ringWidth: ring,
                        innerShadow: true, glow: true, glowGain: 0.8, paused: !live, tilt: false, source: live ? .pointer : .none,
                        bendConfig: MetalBendConfig.default.scaled(Double(size / 40)), fill: face, reflection: 0) {
                    emblem
                }
                .modifier(MetalLiveness(live: $live))
            } else {
                emblem
                    .background(Circle().fill(face))
                    .overlay(Circle().strokeBorder(Atelier.brushed(finish), lineWidth: ring))
            }
        }
        .shadow(color: Atelier.shadow(scheme), radius: size * 0.18, y: size * 0.08)
        .accessibilityElement()
        .accessibilityLabel("Crok")
        .accessibilityAddTraits(.isImage)
    }

    private var face: Color { Color(nsColor: Theme.adaptiveNS(0xFBFAF7, 0x141518)) }

    private var emblem: some View {
        ZStack {
            Circle().fill(RadialGradient(colors: [Theme.ink.opacity(scheme == .dark ? 0.08 : 0.0), .clear], center: .top, startRadius: 0, endRadius: size * 0.7))
            GrokSymbol().fill(Theme.ink).frame(width: size * 0.58, height: size * 0.58)
        }
        .frame(width: size, height: size)
    }
}

/// A headline with liquid metal inside its letters, in the display face.
struct MetalHeadline: View {
    var text: String
    var size: CGFloat
    var weight: Font.Weight = .regular
    @AppStorage(EffectsPreference.key) private var effects = true
    @AppStorage(MetalFinish.key) private var finishName = MetalFinish.defaultFinish.rawValue
    @Environment(\.colorScheme) private var scheme
    @State private var live = false

    private var finish: MetalFinish { MetalFinish(rawValue: finishName) ?? .defaultFinish }

    var body: some View {
        if effects && EffectsPreference.shadersAvailable {
            MetalText(text, font: Atelier.display(size: size, weight: weight), color: Theme.ink, preset: finish.preset, theme: .auto,
                      strength: 1, metalOpacity: scheme == .dark ? 0.72 : 0.58, shaderScale: 3.4, innerShadow: true, glow: false,
                      paused: !live)
                .modifier(MetalLiveness(live: $live, settle: 5))
                .accessibilityElement()
                .accessibilityLabel(text)
                .accessibilityAddTraits(.isHeader)
        } else {
            Text(text).font(Atelier.display(size: size, weight: weight)).foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
        }
    }
}

/// The composer's send button: a ring of liquid metal that bends toward the pointer.
struct MetalSendButton: View {
    var symbol: String
    var enabled: Bool
    var help: String
    var label: String
    var action: () -> Void
    @AppStorage(EffectsPreference.key) private var effects = true
    @AppStorage(MetalFinish.key) private var finishName = MetalFinish.defaultFinish.rawValue
    @State private var live = false

    private var finish: MetalFinish { MetalFinish(rawValue: finishName) ?? .defaultFinish }
    static let diameter: CGFloat = 30

    var body: some View {
        Button(action: action) {
            if effects && EffectsPreference.shadersAvailable {
                MetalFx(variant: .circle, preset: finish.preset, theme: .auto, strength: enabled ? 1 : 0.45, ringWidth: 2,
                        innerShadow: true, glow: false, paused: !live || !enabled, tilt: false,
                        source: live && enabled ? .pointer : .none, fill: Theme.ink, reflection: 0) {
                    glyph
                }
                .modifier(MetalLiveness(live: $live, settle: 2.5))
            } else {
                glyph.background(enabled ? Theme.ink : Theme.muted.opacity(0.35), in: Circle())
                    .overlay(Circle().strokeBorder(Atelier.brushed(finish).opacity(enabled ? 1 : 0.4), lineWidth: 1.5))
            }
        }
        .buttonStyle(.plain).disabled(!enabled)
        .opacity(enabled ? 1 : 0.7)
        .help(help)
        .accessibilityLabel(label)
    }

    private var glyph: some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.canvas)
            .frame(width: Self.diameter, height: Self.diameter)
            .contentShape(Circle())
    }
}

// MARK: - Light on the composer

extension View {
    /// A beam of light travelling the composer's edge while its prompt waits for an answer (border-beam's `line`).
    func workingBeam(_ active: Bool, cornerRadius: CGFloat) -> some View { modifier(WorkingBeam(active: active, cornerRadius: cornerRadius)) }

    /// The glow that rises from the composer's lower edge with the dictating voice (voice-glow).
    func dictationGlow(_ active: Bool, cornerRadius: CGFloat, level: @escaping () -> Double) -> some View {
        modifier(DictationGlow(active: active, cornerRadius: cornerRadius, level: level))
    }
}

/// The beam redraws three card-sized shader layers and a blur every frame, which costs most of a
/// core, so it lights only the wait for a turn's first output (`ComposerView.awaitingFirstOutput`),
/// at 30 fps, and only while the window is active. The thinking orbs say a task works the rest of
/// the time, for next to nothing.
struct WorkingBeam: ViewModifier {
    var active: Bool
    var cornerRadius: CGFloat
    @AppStorage(EffectsPreference.key) private var effects = true
    @AppStorage(MetalFinish.key) private var finishName = MetalFinish.defaultFinish.rawValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appearsActive) private var appearsActive

    func body(content: Content) -> some View {
        if effects && EffectsPreference.shadersAvailable {
            let finish = MetalFinish(rawValue: finishName) ?? .defaultFinish
            content.borderBeam(.line, colorVariant: finish.beam, theme: .auto, staticColors: reduceMotion,
                               active: active && !reduceMotion && (appearsActive || Self.runsInactive), borderRadius: cornerRadius, strength: 0.85)
        } else {
            content
        }
    }

    /// For tests, whose windows are never active.
    nonisolated(unsafe) static var runsInactive = false
}

private struct DictationGlow: ViewModifier {
    var active: Bool
    var cornerRadius: CGFloat
    var level: () -> Double
    @AppStorage(EffectsPreference.key) private var effects = true
    @AppStorage(MetalFinish.key) private var finishName = MetalFinish.defaultFinish.rawValue

    func body(content: Content) -> some View {
        if effects && EffectsPreference.shadersAvailable {
            let finish = MetalFinish(rawValue: finishName) ?? .defaultFinish
            content.voiceGlow(type: .standard, levelProvider: level, active: active, colorVariant: finish.voice, theme: .auto,
                              cornerRadius: Double(cornerRadius))
        } else {
            content
        }
    }
}

// MARK: - Thinking orbs

/// What a turn is doing, as a thinking orb shows it.
enum AgentActivity: Equatable {
    case thinking, working, searching, writing, connecting, listening

    var orb: OrbState {
        switch self {
        case .thinking: return .breathing
        case .working: return .working
        case .searching: return .searching
        case .writing: return .composing
        case .connecting: return .connecting
        case .listening: return .listening
        }
    }

    /// The orb for a run's phase ("Thinking", "Reading files", …).
    static func phase(_ phase: String) -> AgentActivity {
        let text = phase.lowercased()
        if text.contains("think") || text.contains("reason") { return .thinking }
        if text.contains("search") || text.contains("read") || text.contains("look") || text.contains("find") { return .searching }
        if text.contains("writ") || text.contains("edit") || text.contains("compos") { return .writing }
        if text.contains("connect") || text.contains("load") || text.contains("start") { return .connecting }
        return .working
    }
}

/// A thinking orb where the app used to show a spinner: dots that think while the agent works.
/// Drawn by `AgentOrbView`; needs no shaders, and holds still under Reduce Motion.
struct AgentOrb: View {
    var activity: AgentActivity = .working
    var size: CGFloat = 14

    var body: some View {
        AgentOrbRepresentable(activity: activity, size: size)
            .frame(width: size, height: size)
            .accessibilityElement()
            .accessibilityLabel(L10n.t("working_ellipsis", "Working…"))
            .accessibilityAddTraits(.isImage)
    }
}

private struct AgentOrbRepresentable: NSViewRepresentable {
    var activity: AgentActivity
    var size: CGFloat

    func makeNSView(context: Context) -> AgentOrbView { AgentOrbView(activity: activity, size: size) }
    func updateNSView(_ view: AgentOrbView, context: Context) { view.activity = activity }
}

/// A thinking orb painted straight into its layer: thinking-orbs' engine (`orbFrame`) gives the
/// dots and lines for the moment, and Core Graphics paints them in its ink, as the kit's
/// `ThinkingOrb` does in a Canvas, 30 times a second from a display link tied to this view.
/// No SwiftUI view updates per frame, and no frames at all while the window is hidden or covered
/// or the orb is out of a window, which a spinner-sized indicator that may run for an hour needs.
final class AgentOrbView: NSView {
    var activity: AgentActivity {
        didSet {
            guard activity != oldValue else { return }
            preset = resolvePreset(activity.orb, .px20)
            needsDisplay = true
        }
    }

    private let side: CGFloat
    private var preset: ResolvedPreset
    private var link: CADisplayLink?
    private var observers: [NSObjectProtocol] = []
    /// The kit's reduced-motion instant (`OrbSpec.reducedMotionT`).
    private static let stillTime = 0.6
    /// Thinking orbs' presets are tuned on a 20 pt grid.
    private static let grid = Double(OrbSize.px20.rawValue)

    init(activity: AgentActivity, size: CGFloat) {
        self.activity = activity
        side = size
        preset = resolvePreset(activity.orb, .px20)
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(L10n.t("working_ellipsis", "Working…"))
    }

    required init?(coder: NSCoder) { nil }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var intrinsicContentSize: NSSize { NSSize(width: side, height: side) }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        if let window {
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.updateLink() }
                })
            }
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateLink() }
            })
        }
        updateLink()
    }

    override func viewDidHide() { super.viewDidHide(); updateLink() }
    override func viewDidUnhide() { super.viewDidUnhide(); updateLink() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// For tests, whose windows sit under the desktop and so count as covered.
    nonisolated(unsafe) static var animatesWhenCovered = false

    /// Runs the display link only while the orb can be seen and should move.
    private func updateLink() {
        let visible = window.map { ($0.occlusionState.contains(.visible) || Self.animatesWhenCovered) && !$0.isMiniaturized } ?? false
        let moving = visible && !isHiddenOrHasHiddenAncestor && !reduceMotion
        if moving, link == nil {
            let link = displayLink(target: self, selector: #selector(step))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
            link.add(to: .main, forMode: .common)
            self.link = link
        } else if !moving, let link {
            link.invalidate()
            self.link = nil
        }
        needsDisplay = true
    }

    @objc private func step(_ link: CADisplayLink) { needsDisplay = true }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let scale = window?.backingScaleFactor ?? 2
        layer?.contentsScale = scale
        layer?.contents = render(scale: scale)
    }

    private func render(scale: CGFloat) -> CGImage? {
        let pixels = max(1, Int((side * scale).rounded(.up)))
        guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // The engine draws y-down on a 20 pt square.
        let zoom = CGFloat(pixels) / Self.grid
        context.translateBy(x: 0, y: CGFloat(pixels))
        context.scaleBy(x: zoom, y: -zoom)
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let time = link == nil ? Self.stillTime * preset.speed : CACurrentMediaTime() * preset.speed
        let frame = orbFrame(preset, size: Self.grid, t: time)
        func ink(_ white: Double, _ alpha: Double) -> CGColor {
            let w = min(1, max(0, white))
            let grey = ((dark ? 1 - w : w) * 255).rounded(.toNearestOrAwayFromZero) / 255
            return CGColor(srgbRed: grey, green: grey, blue: grey, alpha: alpha)
        }
        // Lines first, so the dots sit on top of their edges; the dots come z-sorted.
        for line in frame.lines {
            context.setStrokeColor(ink(line.white, line.a))
            context.setLineWidth(line.w)
            context.strokeLineSegments(between: [CGPoint(x: line.x1, y: line.y1), CGPoint(x: line.x2, y: line.y2)])
        }
        for dot in frame.dots {
            context.setFillColor(ink(dot.white, dot.a))
            context.fillEllipse(in: CGRect(x: dot.x - dot.r, y: dot.y - dot.r, width: dot.r * 2, height: dot.r * 2))
        }
        return context.makeImage()
    }
}
