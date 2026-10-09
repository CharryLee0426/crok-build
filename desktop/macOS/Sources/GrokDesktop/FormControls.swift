import AppKit
import SwiftUI

/// The same quiet, inset surface is used for search, short answers, and forms.
struct InputSurface: ViewModifier {
    var focused: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false

    func body(content: Content) -> some View {
        content
            .background(Theme.input, in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(focused ? Theme.accent.opacity(0.65) : Theme.line.opacity(hovered ? 0.6 : 0.3), lineWidth: focused ? 1.5 : 1)
            }
            .opacity(isEnabled ? 1 : 0.55)
            .onHover { hovered = $0 }
            .animation(.easeOut(duration: 0.15), value: focused)
    }
}

struct DesktopTextField: View {
    let placeholder: String
    @Binding var text: String
    var title: String?
    var symbol: String?
    var hint: String?
    var multiline: Bool
    @FocusState private var focused: Bool

    init(_ placeholder: String, text: Binding<String>, title: String? = nil, symbol: String? = nil, hint: String? = nil, multiline: Bool = false) {
        self.placeholder = placeholder
        _text = text
        self.title = title
        self.symbol = symbol
        self.hint = hint
        self.multiline = multiline
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title { Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.muted) }
            HStack(alignment: multiline ? .top : .center, spacing: 10) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 15)).foregroundStyle(Theme.muted)
                        .frame(width: 18, height: 20)
                        .accessibilityHidden(true)
                }
                Group {
                    if multiline {
                        TextField(placeholder, text: $text, axis: .vertical).lineLimit(3...6)
                    } else {
                        TextField(placeholder, text: $text)
                    }
                }
                .textFieldStyle(.plain).font(.system(size: 14)).foregroundStyle(Theme.ink)
                .tint(Theme.accent).focused($focused).accessibilityLabel(title ?? placeholder)
            }
            .padding(.horizontal, 13).padding(.vertical, 12)
            .frame(minHeight: multiline ? 86 : 44, alignment: .topLeading)
            .modifier(InputSurface(focused: focused))
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .onTapGesture { focused = true }
            if let hint { Text(hint).font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

struct ComposerControlLabel: View {
    let title: String
    var symbol: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(Theme.muted)
                    .frame(width: 16).accessibilityHidden(true)
            }
            Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(Theme.muted)
                .accessibilityHidden(true)
        }.padding(.horizontal, 10).frame(height: 30).contentShape(Capsule())
    }
}

struct ComposerControlStyle: ButtonStyle {
    var filled = false
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Theme.ink)
            .background(Theme.hover.opacity(configuration.isPressed ? 1 : hovered ? 0.85 : filled ? 0.55 : 0), in: Capsule())
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { hovered = $0 }
            .animation(.easeOut(duration: 0.12), value: hovered)
    }
}

struct PopoverRowStyle: ButtonStyle {
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovered || configuration.isPressed ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 9))
            .contentShape(RoundedRectangle(cornerRadius: 9))
            .onHover { hovered = $0 }
    }
}

/// How folds open and close, everywhere: the content is laid out once at its full height and
/// uncovered from the top by a clip that grows with it, while whatever sits below slides down.
/// Nothing is laid out again during the animation, so long streamed content folds smoothly too.
enum FoldMotion {
    static let animation = Animation.smooth(duration: 0.26)

    /// The fold animation, or none with Reduce Motion.
    static var current: Animation? { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : animation }

    /// Makes a fold's state change animated, or immediate with Reduce Motion.
    static func toggle(_ change: () -> Void) {
        withAnimation(current, change)
    }
}

/// A header and the content it folds. Closing covers the content in place and removes it only
/// once covered, so it animates in layout like opening does and what sits below follows it.
struct Fold<Header: View, Content: View>: View {
    @Binding var isExpanded: Bool
    var spacing: CGFloat = 0
    /// Given the fold's action and whether it shows as open, which it stops doing as it starts to close.
    @ViewBuilder var header: (_ toggle: @escaping () -> Void, _ isOpen: Bool) -> Header
    @ViewBuilder var content: () -> Content
    @State private var closing = false

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            header(toggle, isExpanded && !closing)
            if isExpanded {
                VStack(alignment: .leading, spacing: 0) { content() }
                    .modifier(FoldReveal(progress: closing ? 0 : 1))
                    .transition(.fold)
            }
        }
    }

    private func toggle() {
        let animation = FoldMotion.current
        if closing {
            withAnimation(animation) { closing = false }
        } else if !isExpanded {
            withAnimation(animation) { isExpanded = true }
        } else if animation == nil {
            isExpanded = false
        } else {
            withAnimation(animation) { closing = true } completion: {
                // Opened again before it finished closing.
                guard closing else { return }
                var quiet = Transaction()
                quiet.disablesAnimations = true
                withTransaction(quiet) {
                    isExpanded = false
                    closing = false
                }
            }
        }
    }
}

extension AnyTransition {
    /// Folded content: uncovered from the top as it opens, and fading in.
    static var fold: AnyTransition {
        .modifier(active: FoldReveal(progress: 0), identity: FoldReveal(progress: 1))
    }
}

struct FoldReveal: ViewModifier {
    var progress: CGFloat

    func body(content: Content) -> some View {
        RevealLayout(progress: progress) { VStack(alignment: .leading, spacing: 0) { content } }
            .clipped()
            .opacity(progress)
    }
}

/// Takes the top `progress` of its content's height; the content keeps its full size beneath the clip.
struct RevealLayout: Layout {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let size = content.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: size.width, height: size.height * min(1, max(0, progress)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let content = subviews.first else { return }
        let size = content.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
        content.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: size.height))
    }
}

/// A collapsible section whose whole header row is the click target. It opens and closes
/// with `FoldMotion`, the chevron turning as the content unfolds.
struct FoldableSection<Header: View, Content: View>: View {
    @Binding var isExpanded: Bool
    @ViewBuilder var header: () -> Header
    @ViewBuilder var content: () -> Content

    var body: some View {
        Fold(isExpanded: $isExpanded) { toggle, isOpen in
            Button(action: toggle) {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.muted)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .frame(width: 20, height: 20)
                        .accessibilityHidden(true)
                    header()
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(FoldHeaderStyle())
            .accessibilityValue(isOpen ? "Expanded" : "Collapsed")
            .accessibilityHint(isOpen ? "Collapse" : "Expand")
        } content: {
            content()
        }
    }
}

struct FoldHeaderStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { FoldHeaderBackground(configuration: configuration) }
}

private struct FoldHeaderBackground: View {
    let configuration: ButtonStyleConfiguration
    @State private var hovered = false

    var body: some View {
        configuration.label
            .background(Theme.hover.opacity(configuration.isPressed ? 0.9 : hovered ? 0.55 : 0), in: RoundedRectangle(cornerRadius: 9))
            .onHover { hovered = $0 }
    }
}
