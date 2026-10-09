import SwiftUI
import AppKit
import QuartzCore

/// The live look of a reasoning block while the model thinks: a band of colour that sweeps across
/// the block and back, drawn as a thin loading bar along its bottom edge, a liquid rim and glow
/// around it, and a soft wash inside it.
///
/// The sweeps are Core Animation layers with autoreversing, repeating animations, so the window
/// server moves them and the app does no work per frame. (SwiftUI's repeating animations evaluate
/// the view graph on the main thread every frame, which cost about ten points of CPU while
/// reasoning streamed.) Nothing animates once the block stops streaming. With Reduce Motion the
/// colours stay still.
enum ThinkingPalette {
    /// Cool to warm and back, so the band's two ends meet the same colour as it reverses.
    static let nsColors: [NSColor] = [
        NSColor(srgbRed: 0.35, green: 0.55, blue: 1.00, alpha: 1),
        NSColor(srgbRed: 0.62, green: 0.42, blue: 1.00, alpha: 1),
        NSColor(srgbRed: 0.98, green: 0.40, blue: 0.72, alpha: 1),
        NSColor(srgbRed: 1.00, green: 0.62, blue: 0.32, alpha: 1),
        NSColor(srgbRed: 0.98, green: 0.40, blue: 0.72, alpha: 1),
        NSColor(srgbRed: 0.62, green: 0.42, blue: 1.00, alpha: 1),
        NSColor(srgbRed: 0.35, green: 0.55, blue: 1.00, alpha: 1),
    ]
    static var gradient: LinearGradient {
        LinearGradient(colors: nsColors.map { Color(nsColor: $0) }, startPoint: .leading, endPoint: .trailing)
    }
}

/// A running tool call's colours: the same sweep as reasoning's, in blues, ending where it starts.
enum ExecutingPalette {
    static let nsColors: [NSColor] = [
        NSColor(srgbRed: 0.20, green: 0.40, blue: 1.00, alpha: 1),
        NSColor(srgbRed: 0.10, green: 0.62, blue: 1.00, alpha: 1),
        NSColor(srgbRed: 0.28, green: 0.86, blue: 0.98, alpha: 1),
        NSColor(srgbRed: 0.10, green: 0.62, blue: 1.00, alpha: 1),
        NSColor(srgbRed: 0.20, green: 0.40, blue: 1.00, alpha: 1),
    ]
    /// The spinner and the status beside it.
    static let tint = Theme.adaptiveNS(0x2868E8, 0x5FA8FF)
}

/// The thin indeterminate bar: a short colourful segment that runs to one end, turns, and runs back.
struct ThinkingProgressBar: View {
    var height: CGFloat = 2
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ThinkingLayers(kind: .bar, animated: !reduceMotion).frame(height: height)
    }
}

extension View {
    /// The reasoning block's live treatment, drawn behind its content: a coloured wash inside, a
    /// rim, and a glow just outside, all sweeping back and forth. Off, the view is left as it is.
    @ViewBuilder
    func thinkingLiquid(_ active: Bool, cornerRadius: CGFloat) -> some View {
        if active { modifier(ThinkingLiquid(cornerRadius: cornerRadius)) } else { self }
    }
}

private struct ThinkingLiquid: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.background {
            ThinkingLayers(kind: .card(cornerRadius: cornerRadius), animated: !reduceMotion)
                .padding(-ThinkingLayerView.glowRoom)
        }
    }
}

/// Hosts the Core Animation layers of one effect.
private struct ThinkingLayers: NSViewRepresentable {
    let kind: ThinkingLayerView.Kind
    let animated: Bool

    func makeNSView(context: Context) -> ThinkingLayerView { ThinkingLayerView(kind: kind, animated: animated) }

    func updateNSView(_ view: ThinkingLayerView, context: Context) { view.setAnimated(animated) }
}

final class ThinkingLayerView: NSView {
    enum Kind: Equatable {
        case bar
        case card(cornerRadius: CGFloat)
    }

    /// Space around a card for its glow; the view extends this far past the card on every side.
    static let glowRoom: CGFloat = 10

    private let kind: Kind
    private var animated: Bool
    private let colors: [NSColor]
    /// Each sweep is a gradient wider than what shows of it, sliding inside a clipping container.
    private var sweeps: [(gradient: CAGradientLayer, span: CGFloat, period: CFTimeInterval)] = []
    // Bar
    private let track = CALayer()
    private let segmentHolder = CALayer()
    private let segmentClip = CALayer()
    // Card
    private let wash = CALayer(), washMask = CAShapeLayer()
    private let rim = CALayer(), rimMask = CAShapeLayer()
    private let glow = CALayer(), glowMask = CAShapeLayer()
    private var laidOut: CGSize = .zero

    /// `colors` run from one end of the sweep to the other and should end as they begin.
    init(kind: Kind, animated: Bool, colors: [NSColor] = ThinkingPalette.nsColors) {
        self.kind = kind
        self.animated = animated
        self.colors = colors
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        guard let layer else { return }
        layer.masksToBounds = false
        switch kind {
        case .bar:
            layer.addSublayer(track)
            segmentHolder.shadowColor = colors[min(1, colors.count - 1)].cgColor
            segmentHolder.shadowOpacity = 0.75
            segmentHolder.shadowRadius = 3
            segmentHolder.shadowOffset = .zero
            segmentClip.masksToBounds = true
            segmentHolder.addSublayer(segmentClip)
            layer.addSublayer(segmentHolder)
            sweeps = [(Self.gradientLayer(), 2.2, 1.9)]
            segmentClip.addSublayer(sweeps[0].gradient)
        case .card:
            // A faint wash inside, a glow outside (a blurred rim: the mask's shadow feathers it), and a crisp rim.
            wash.opacity = 0.13
            wash.mask = washMask
            glow.opacity = 0.5
            glowMask.fillColor = nil
            glowMask.strokeColor = NSColor.black.cgColor
            glowMask.lineWidth = 2
            glowMask.shadowColor = NSColor.black.cgColor
            glowMask.shadowOpacity = 1
            glowMask.shadowRadius = 6
            glowMask.shadowOffset = .zero
            glow.mask = glowMask
            rimMask.fillColor = nil
            rimMask.strokeColor = NSColor.black.cgColor
            rimMask.lineWidth = 1.1
            rim.opacity = 0.9
            rim.mask = rimMask
            for container in [wash, glow, rim] {
                let gradient = Self.gradientLayer()
                container.addSublayer(gradient)
                sweeps.append((gradient, 2.6, 3.4))
                layer.addSublayer(container)
            }
        }
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isOpaque: Bool { false }

    func setAnimated(_ value: Bool) {
        guard value != animated else { return }
        animated = value
        restartAnimations()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    /// Core Animation drops a window's animations when the layer tree is rebuilt, so moving to a
    /// window starts them again.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { restartAnimations() }
    }

    override func layout() {
        super.layout()
        guard bounds.size != laidOut else { return }
        laidOut = bounds.size
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        switch kind {
        case .bar: layoutBar()
        case .card(let radius): layoutCard(radius: radius)
        }
        CATransaction.commit()
        restartAnimations()
    }

    private var segmentWidth: CGFloat { max(min(bounds.width * 0.36, 260), 36) }

    private func layoutBar() {
        let height = bounds.height
        track.frame = bounds
        track.cornerRadius = height / 2
        let width = animated ? segmentWidth : bounds.width
        segmentHolder.frame = CGRect(x: 0, y: 0, width: width, height: height)
        segmentClip.frame = segmentHolder.bounds
        segmentClip.cornerRadius = height / 2
        sweeps[0].gradient.frame = CGRect(x: 0, y: 0, width: width * sweeps[0].span, height: height)
    }

    private func layoutCard(radius: CGFloat) {
        let card = bounds.insetBy(dx: Self.glowRoom, dy: Self.glowRoom)
        guard card.width > 0, card.height > 0 else { return }
        let fill = CGPath(roundedRect: card, cornerWidth: radius, cornerHeight: radius, transform: nil)
        // Strokes are centred on their path; inset by half the width so the rim sits inside the card.
        func stroke(_ width: CGFloat) -> CGPath {
            let rect = card.insetBy(dx: width / 2, dy: width / 2)
            let r = max(0, radius - width / 2)
            return CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
        }
        washMask.path = fill
        rimMask.path = stroke(rimMask.lineWidth)
        glowMask.path = stroke(glowMask.lineWidth)
        for (index, container) in [wash, glow, rim].enumerated() {
            container.frame = bounds
            [washMask, glowMask, rimMask][index].frame = bounds
            // The gradient spans the card's width, starting at the card's leading edge.
            let span = sweeps[index].span
            sweeps[index].gradient.frame = CGRect(x: card.minX - Self.glowRoom, y: 0, width: (card.width + 2 * Self.glowRoom) * span, height: bounds.height)
        }
    }

    private func restartAnimations() {
        for sweep in sweeps { sweep.gradient.removeAllAnimations() }
        segmentHolder.removeAllAnimations()
        guard animated, window != nil, bounds.width > 1 else { return }
        for sweep in sweeps {
            let visible = sweep.gradient.bounds.width / sweep.span
            sweep.gradient.add(Self.backAndForth("transform.translation.x", to: -visible * (sweep.span - 1), period: sweep.period), forKey: "sweep")
        }
        if kind == .bar {
            segmentHolder.add(Self.backAndForth("transform.translation.x", to: bounds.width - segmentWidth, period: 1.25), forKey: "run")
        }
    }

    private func updateColors() {
        let colors = self.colors.map(\.cgColor)
        for sweep in sweeps { sweep.gradient.colors = colors }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            track.backgroundColor = Theme.palette.mutedNS.withAlphaComponent(0.14).cgColor
        }
    }

    private static func gradientLayer() -> CAGradientLayer {
        let gradient = CAGradientLayer()
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        return gradient
    }

    private static func backAndForth(_ keyPath: String, to value: CGFloat, period: CFTimeInterval) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = 0
        animation.toValue = value
        animation.duration = period
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        animation.isRemovedOnCompletion = false
        return animation
    }
}

/// Endless turns about a layer's centre, clockwise on screen, for the effects that spin in place.
/// Like the sweeps, the window server runs them and the app does no work per frame.
private enum Turning {
    /// For a sublayer of a view that is not flipped: AppKit lays such a view's layers out up the
    /// screen, wherever the view is, so a negative angle turns clockwise. The layers' flags are
    /// not settled yet when the view joins its window, so they cannot be asked.
    static func animation(period: CFTimeInterval) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: "transform.rotation.z")
        animation.fromValue = 0
        animation.toValue = -2 * CGFloat.pi
        animation.duration = period
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        animation.isRemovedOnCompletion = false
        return animation
    }

    static var allowed: Bool { !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}

/// A short arc turning over a faint ring, in place of a tool call's status icon while it runs.
/// With Reduce Motion it stands still.
final class SpinnerLayerView: NSView {
    private let track = CAShapeLayer()
    private let arc = CAShapeLayer()
    private let lineWidth: CGFloat
    var color: NSColor { didSet { updateColors() } }

    init(color: NSColor, lineWidth: CGFloat = 1.8) {
        self.color = color
        self.lineWidth = lineWidth
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        for shape in [track, arc] {
            shape.fillColor = nil
            shape.lineWidth = lineWidth
            shape.lineCap = .round
            layer?.addSublayer(shape)
        }
        arc.strokeEnd = 0.68
        updateColors()
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isOpaque: Bool { false }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        guard changed else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let side = min(newSize.width, newSize.height)
        let square = CGRect(x: 0, y: 0, width: side, height: side)
        let path = CGPath(ellipseIn: square.insetBy(dx: lineWidth / 2, dy: lineWidth / 2), transform: nil)
        for shape in [track, arc] {
            shape.bounds = square
            shape.position = CGPoint(x: newSize.width / 2, y: newSize.height / 2)
            shape.path = path
        }
        CATransaction.commit()
        restart()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { restart() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func restart() {
        arc.removeAllAnimations()
        guard window != nil, bounds.width > 1, Turning.allowed else { return }
        arc.add(Turning.animation(period: 0.9), forKey: "turn")
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            track.strokeColor = color.withAlphaComponent(0.2).cgColor
            arc.strokeColor = color.cgColor
        }
    }
}

/// An SF Symbol filled with a colour, or with colours running across it, that can turn in place:
/// the reasoning block's sparkle while the model thinks.
final class TurningSymbolView: NSView {
    private let turner = CALayer()
    private let fill = CAGradientLayer()
    private let shape = CALayer()
    private let image: NSImage
    /// One colour fills the symbol; more run across it, leading to trailing.
    var colors: [NSColor] = [.secondaryLabelColor] { didSet { updateColors() } }
    var turns = false { didSet { if turns != oldValue { restart() } } }
    /// Seconds for one full turn.
    var period: CFTimeInterval = 2.8

    init(image: NSImage) {
        self.image = image
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        fill.startPoint = CGPoint(x: 0, y: 0.5)
        fill.endPoint = CGPoint(x: 1, y: 0.5)
        shape.contentsGravity = .resizeAspect
        fill.mask = shape
        turner.addSublayer(fill)
        layer?.addSublayer(turner)
        updateColors()
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isOpaque: Bool { false }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        guard changed else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        turner.bounds = CGRect(origin: .zero, size: newSize)
        turner.position = CGPoint(x: newSize.width / 2, y: newSize.height / 2)
        fill.frame = turner.bounds
        shape.frame = fill.bounds
        CATransaction.commit()
        updateContents()
        restart()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        updateContents()
        restart()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateContents()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateContents() {
        let scale = window?.backingScaleFactor ?? 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.contentsScale = scale
        shape.contents = image.layerContents(forContentsScale: scale)
        CATransaction.commit()
    }

    private func restart() {
        turner.removeAllAnimations()
        guard turns, window != nil, bounds.width > 1, Turning.allowed else { return }
        turner.add(Turning.animation(period: period), forKey: "turn")
    }

    private func updateColors() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let resolved = colors.map(\.cgColor)
            fill.colors = resolved.count == 1 ? [resolved[0], resolved[0]] : resolved
        }
        CATransaction.commit()
    }
}
