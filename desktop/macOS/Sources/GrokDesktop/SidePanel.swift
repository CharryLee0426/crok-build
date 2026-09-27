import AppKit
import SwiftUI

/// The tabs of the side panel beside the conversation.
enum SidePanelTab: String, CaseIterable, Identifiable {
    case files, sideChat, terminal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .files: return "Files"
        case .sideChat: return "Side chat"
        case .terminal: return "Terminal"
        }
    }

    var symbol: String {
        switch self {
        case .files: return "folder"
        case .sideChat: return "bubble.left.and.text.bubble.right"
        case .terminal: return "terminal"
        }
    }
}

/// The panel on the right of the window: the project's files, side chats, and a terminal.
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

    static let defaultWidth = 400.0
    static let defaultPreviewWidth = 820.0
    static let minimumWidth = 300.0
    /// Room the conversation keeps beside the panel.
    static let conversationRoom = 440.0
    /// While a file is previewed, the conversation gives up more of the window.
    static let previewConversationRoom = 360.0

    /// The Files tab shows the tree and a file side by side, which needs a wider panel.
    private var isPreviewing: Bool { store.sidePanelTab == .files && store.project != nil && files.selection != nil }

    var body: some View {
        let previewing = isPreviewing
        let room = previewing ? Self.previewConversationRoom : Self.conversationRoom
        let maximum = max(Self.minimumWidth, min(previewing ? 1_400 : 1_000, Double(containerWidth) - room))
        let binding = previewing ? $previewWidth : $width
        VStack(spacing: 0) {
            SidePanelTabBar(selection: $store.sidePanelTab) {
                withAnimation(.easeInOut(duration: 0.18)) { store.showInspector = false }
            }
            Divider().overlay(Theme.line.opacity(0.4))
            Group {
                switch store.sidePanelTab {
                case .files: FilesPanelView()
                case .sideChat: SideChatView()
                case .terminal: TerminalPanelView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: min(max(binding.wrappedValue, Self.minimumWidth), maximum))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: previewing)
        .background { GlassBackdrop(role: .panel).ignoresSafeArea() }
        .overlay(alignment: .leading) {
            ResizeHandle(axis: .horizontal, value: binding, range: Self.minimumWidth...maximum,
                         defaultValue: previewing ? Self.defaultPreviewWidth : Self.defaultWidth, growsTowardStart: true,
                         label: "Side panel width")
                .offset(x: -4.5)
        }
    }
}

private struct SidePanelTabBar: View {
    @Binding var selection: SidePanelTab
    var onClose: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(SidePanelTab.allCases) { tab in
                SidePanelTabButton(tab: tab, isSelected: selection == tab) { selection = tab }
            }
            Spacer(minLength: 4)
            IconButton(icon: "xmark", help: "Hide side panel · ⌘J", size: 26, action: onClose)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
    }
}

private struct SidePanelTabButton: View {
    let tab: SidePanelTab
    let isSelected: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: tab.symbol).font(.system(size: 12, weight: .medium))
                Text(tab.title).font(.system(size: 12.5, weight: isSelected ? .semibold : .medium)).lineLimit(1)
            }
            .foregroundStyle(isSelected ? Theme.ink : Theme.muted)
            .padding(.horizontal, 10).frame(height: 28)
            .background(!isSelected && hovered ? Theme.hover.opacity(0.5) : .clear, in: Capsule())
            .modifier(SelectedTabGlass(isSelected: isSelected))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
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
