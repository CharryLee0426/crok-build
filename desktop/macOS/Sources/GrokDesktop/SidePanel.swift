import AppKit
import SwiftUI

/// The tabs of the side panel beside the conversation.
enum SidePanelTab: String, CaseIterable, Identifiable {
    case files, sideChat, terminal, browser

    var id: String { rawValue }

    var title: String {
        switch self {
        case .files: return "Files"
        case .sideChat: return "Side chat"
        case .terminal: return "Terminal"
        case .browser: return "Browser"
        }
    }

    var symbol: String {
        switch self {
        case .files: return "folder"
        case .sideChat: return "bubble.left.and.text.bubble.right"
        case .terminal: return "terminal"
        case .browser: return "globe"
        }
    }
}

/// The panel on the right of the window: the project's files, side chats, a terminal, and a browser.
/// Drag its leading edge to resize it; double-click the edge to restore the default width.
struct SidePanelView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var files: FilesPanelModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The width of the detail area, which bounds how wide the panel may grow.
    let containerWidth: CGFloat
    @AppStorage("sidePanelWidth") private var width = SidePanelView.defaultWidth
    /// The width while a file is previewed beside the file tree, remembered separately.
    @AppStorage("sidePanelPreviewWidth") private var previewWidth = SidePanelView.defaultPreviewWidth
    /// The width while the browser shows, remembered separately: a page wants more room than a file tree.
    @AppStorage("sidePanelBrowserWidth") private var browserWidth = SidePanelView.defaultBrowserWidth

    static let defaultWidth = 400.0
    static let defaultPreviewWidth = 820.0
    static let defaultBrowserWidth = 520.0
    static let minimumWidth = 300.0
    /// Room the conversation keeps beside the panel.
    static let conversationRoom = 440.0
    /// While a file is previewed or a page is open, the conversation gives up more of the window.
    static let previewConversationRoom = 360.0

    /// What the panel shows decides how wide it wants to be.
    private enum Layout { case standard, preview, browser }

    /// The Files tab shows the tree and a file side by side, which needs a wider panel; so does a web page.
    private var layout: Layout {
        if store.sidePanelTab == .browser { return .browser }
        return store.sidePanelTab == .files && store.project != nil && files.selection != nil ? .preview : .standard
    }

    var body: some View {
        let layout = layout
        let room = layout == .standard ? Self.conversationRoom : Self.previewConversationRoom
        let maximum = max(Self.minimumWidth, min(layout == .standard ? 1_000 : 1_400, Double(containerWidth) - room))
        let binding = layout == .preview ? $previewWidth : layout == .browser ? $browserWidth : $width
        let defaultWidth = layout == .preview ? Self.defaultPreviewWidth : layout == .browser ? Self.defaultBrowserWidth : Self.defaultWidth
        let panelWidth = min(max(binding.wrappedValue, Self.minimumWidth), maximum)
        VStack(spacing: 0) {
            // Equatable: the store publishes every streamed chunk, and none of them changes the tab bar.
            SidePanelTabBar(selection: store.sidePanelTab, density: .fitting(barWidth: panelWidth), store: store).equatable()
            Divider().overlay(Theme.line.opacity(0.4))
            Group {
                switch store.sidePanelTab {
                case .files: FilesPanelView()
                case .sideChat: SideChatView()
                case .terminal: TerminalPanelView()
                case .browser: BrowserPanelView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: panelWidth)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: layout)
        .background { GlassBackdrop(role: .panel).ignoresSafeArea() }
        .overlay(alignment: .leading) {
            ResizeHandle(axis: .horizontal, value: binding, range: Self.minimumWidth...maximum,
                         defaultValue: defaultWidth, growsTowardStart: true,
                         label: "Side panel width")
                .offset(x: -4.5)
        }
    }
}

/// How the tab bar spends its width: every tab named, the names drawn closer, or only the selected tab named.
enum SidePanelTabDensity: Equatable {
    case regular, compact, icons

    var tabSpacing: Double { self == .compact ? 2 : 4 }
    var tabPadding: Double { self == .compact ? 6 : 10 }
    var labelSpacing: Double { self == .compact ? 5 : 6 }

    /// The roomiest density whose tabs fit a bar this wide. The widths come from the tabs' names and
    /// symbols, measured once, so the bar lays out one row instead of trying each and keeping the first that fits.
    static func fitting(barWidth: Double) -> SidePanelTabDensity {
        if barWidth >= minimumBarWidth(.regular) { return .regular }
        return barWidth >= minimumBarWidth(.compact) ? .compact : .icons
    }

    static func minimumBarWidth(_ density: SidePanelTabDensity) -> Double {
        switch density {
        case .regular: return namedWidths.regular
        case .compact: return namedWidths.compact
        case .icons: return 0
        }
    }

    /// The bar around the tabs: its padding, the gap before the close button, and the button.
    static let chrome = 20.0 + 4 + 4 + 4 + 26

    private static let namedWidths: (regular: Double, compact: Double) = {
        // The selected tab's name is semibold, the widest it gets; every name is measured that way.
        let font = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
        let symbols = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        let content = SidePanelTab.allCases.reduce(0.0) { width, tab in
            let symbol = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: nil)?.withSymbolConfiguration(symbols)?.size.width ?? 18
            return width + ceil((tab.title as NSString).size(withAttributes: [.font: font]).width) + ceil(symbol)
        }
        func bar(_ density: SidePanelTabDensity) -> Double {
            let count = Double(SidePanelTab.allCases.count)
            // Four points to spare: text is laid out a little differently than it is measured.
            return content + count * (density.labelSpacing + 2 * density.tabPadding) + (count - 1) * density.tabSpacing + chrome + 4
        }
        return (bar(.regular), bar(.compact))
    }()
}

struct SidePanelTabBar: View, Equatable {
    let selection: SidePanelTab
    let density: SidePanelTabDensity
    /// Not observed: the bar only tells the store what was chosen.
    let store: AppStore

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.selection == rhs.selection && lhs.density == rhs.density }

    var body: some View {
        HStack(spacing: 4) {
            HStack(spacing: density.tabSpacing) {
                ForEach(SidePanelTab.allCases) { tab in
                    SidePanelTabButton(tab: tab, isSelected: selection == tab, showsTitle: density != .icons || selection == tab, density: density) {
                        store.sidePanelTab = tab
                    }
                }
            }
            Spacer(minLength: 4)
            IconButton(icon: "xmark", help: "Hide side panel · ⌘J", size: 26) {
                withAnimation(.easeInOut(duration: 0.18)) { store.showInspector = false }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
    }
}

private struct SidePanelTabButton: View {
    let tab: SidePanelTab
    let isSelected: Bool
    var showsTitle = true
    var density = SidePanelTabDensity.regular
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: density.labelSpacing) {
                Image(systemName: tab.symbol).font(.system(size: 12, weight: .medium))
                if showsTitle { Text(tab.title).font(.system(size: 12.5, weight: isSelected ? .semibold : .medium)).lineLimit(1).fixedSize() }
            }
            .foregroundStyle(isSelected ? Theme.ink : Theme.muted)
            .padding(.horizontal, density.tabPadding).frame(height: 28)
            .background(!isSelected && hovered ? Theme.hover.opacity(0.5) : .clear, in: Capsule())
            .modifier(SelectedTabGlass(isSelected: isSelected))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(showsTitle ? "" : tab.title)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

private struct SelectedTabGlass: ViewModifier {
    let isSelected: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isSelected { content.glassSurface(in: Capsule()) } else { content }
    }
}

/// A draggable divider that resizes the view beside it. With `growsTowardStart`, dragging toward
/// the leading (or top) edge makes the value larger, as for a panel on the trailing side.
struct ResizeHandle: View {
    enum Axis { case horizontal, vertical }

    let axis: Axis
    @Binding var value: Double
    let range: ClosedRange<Double>
    let defaultValue: Double
    var growsTowardStart = false
    var label: String
    @State private var dragStart: Double?
    @State private var hovered = false

    var body: some View {
        let active = hovered || dragStart != nil
        ZStack {
            Rectangle().fill(active ? Theme.accent.opacity(0.55) : Theme.line.opacity(0.45))
                .frame(width: axis == .horizontal ? (active ? 2 : 0.5) : nil, height: axis == .vertical ? (active ? 2 : 0.5) : nil)
        }
        .frame(width: axis == .horizontal ? 9 : nil, height: axis == .vertical ? 9 : nil)
        .frame(maxWidth: axis == .vertical ? .infinity : nil, maxHeight: axis == .horizontal ? .infinity : nil)
        .contentShape(Rectangle())
        .background(ResizeCursorArea(cursor: axis == .horizontal ? .resizeLeftRight : .resizeUpDown))
        .onHover { hovered = $0 }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { drag in
                    let start = dragStart ?? value
                    if dragStart == nil { dragStart = value }
                    let delta = Double(axis == .horizontal ? drag.translation.width : drag.translation.height)
                    value = min(max(start + (growsTowardStart ? -delta : delta), range.lowerBound), range.upperBound)
                }
                .onEnded { _ in dragStart = nil }
        )
        .onTapGesture(count: 2) { value = min(max(defaultValue, range.lowerBound), range.upperBound) }
        .animation(.easeOut(duration: 0.12), value: active)
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue("\(Int(value)) points")
        .accessibilityAdjustableAction { direction in
            let step = direction == .increment ? 24.0 : -24.0
            value = min(max(value + step, range.lowerBound), range.upperBound)
        }
    }
}

/// Shows a resize cursor over its frame without taking any clicks.
private struct ResizeCursorArea: NSViewRepresentable {
    let cursor: NSCursor

    func makeNSView(context: Context) -> CursorView { CursorView(cursor: cursor) }
    func updateNSView(_ view: CursorView, context: Context) {}

    final class CursorView: NSView {
        let cursor: NSCursor

        init(cursor: NSCursor) {
            self.cursor = cursor
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func resetCursorRects() { addCursorRect(bounds, cursor: cursor) }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            window?.invalidateCursorRects(for: self)
        }
    }
}
