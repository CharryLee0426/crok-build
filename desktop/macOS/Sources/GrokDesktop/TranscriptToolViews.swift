import AppKit
import QuartzCore
import SwiftUI

// MARK: - Query field

/// A search field that reports the keys the transcript tools use: esc, return (and ⇧return),
/// ↑/↓, and tab. It takes the keyboard when it appears and whenever `focusRequest` changes.
struct TranscriptQueryField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var focusRequest = 0
    var onFocusChange: (Bool) -> Void = { _ in }
    var onEscape: () -> Void = {}
    var onSubmit: (_ backwards: Bool) -> Void = { _ in }
    var onMove: ((Int) -> Void)?
    var onTab: (() -> Void)?

    func makeNSView(context: Context) -> TranscriptQueryNSField {
        let field = TranscriptQueryNSField()
        field.delegate = context.coordinator
        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: 14)
        field.focusRingType = .none
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        if let cell = field.cell as? NSSearchFieldCell {
            cell.searchButtonCell = nil
            cell.cancelButtonCell = nil
        }
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.stringValue = text
        field.setAccessibilityLabel(placeholder)
        field.onFocus = { [weak coordinator = context.coordinator] in coordinator?.parent.onFocusChange(true) }
        return field
    }

    func updateNSView(_ field: TranscriptQueryNSField, context: Context) {
        context.coordinator.parent = self
        context.coordinator.isShowingText = true
        field.showText(text)
        context.coordinator.isShowingText = false
        field.placeholderString = placeholder
        if context.coordinator.focusRequest != focusRequest {
            context.coordinator.focusRequest = focusRequest
            field.focusAndSelectAll()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: TranscriptQueryField
        var focusRequest: Int
        var isShowingText = false
        init(_ parent: TranscriptQueryField) { self.parent = parent; focusRequest = parent.focusRequest }

        func controlTextDidEndEditing(_ notification: Notification) { parent.onFocusChange(false) }
        func controlTextDidChange(_ notification: Notification) {
            guard !isShowingText, let field = notification.object as? NSSearchField else { return }
            let text = (field.currentEditor() as? NSTextView)?.committedString ?? field.stringValue
            if parent.text != text { parent.text = text }
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.cancelOperation(_:)): parent.onEscape(); return true
            case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertLineBreak(_:)):
                parent.onSubmit(NSApp.currentEvent?.modifierFlags.contains(.shift) == true); return true
            case #selector(NSResponder.moveDown(_:)): guard let move = parent.onMove else { return false }; move(1); return true
            case #selector(NSResponder.moveUp(_:)): guard let move = parent.onMove else { return false }; move(-1); return true
            case #selector(NSResponder.insertTab(_:)): guard let tab = parent.onTab else { return false }; tab(); return true
            default: return false
            }
        }
    }
}

final class TranscriptQueryNSField: NSSearchField {
    var onFocus: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { DispatchQueue.main.async { [weak self] in self?.onFocus?() } }
        return accepted
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in self?.focusAndSelectAll() }
    }

    func focusAndSelectAll() {
        guard let window else { return }
        if window.firstResponder !== currentEditor() { window.makeFirstResponder(self) }
        currentEditor()?.selectAll(nil)
    }
}

/// The inset search surface used across the transcript tools, with room for a trailing status.
struct TranscriptQueryBox<Trailing: View>: View {
    @Binding var text: String
    var placeholder: String
    var focusRequest = 0
    var onEscape: () -> Void = {}
    var onSubmit: (_ backwards: Bool) -> Void = { _ in }
    var onMove: ((Int) -> Void)?
    var onTab: (() -> Void)?
    @ViewBuilder var trailing: () -> Trailing
    @State private var focused = false

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(Theme.muted).accessibilityHidden(true)
            TranscriptQueryField(text: $text, placeholder: placeholder, focusRequest: focusRequest, onFocusChange: { focused = $0 },
                                 onEscape: onEscape, onSubmit: onSubmit, onMove: onMove, onTab: onTab)
                .frame(height: 20)
            trailing()
        }
        .padding(.horizontal, 12).frame(minHeight: 36)
        .modifier(InputSurface(focused: focused))
    }
}

// MARK: - Find bar

/// `/find`: a bar over the top of the conversation with the match count and next/previous.
struct TranscriptFindBar: View {
    @EnvironmentObject var tools: TranscriptToolsModel

    var body: some View {
        let hasMatches = !tools.findMatches.isEmpty
        HStack(spacing: 4) {
            TranscriptQueryBox(text: $tools.findQuery, placeholder: "Find in conversation (regular expression)", focusRequest: tools.findFocusRequest,
                               onEscape: { tools.closeFind() }, onSubmit: { tools.submitFind(backwards: $0) }, onMove: { tools.moveFind($0) }) {
                if let status = tools.findStatus {
                    Text(status).font(.system(size: 12)).monospacedDigit()
                        .foregroundStyle(tools.findInvalid ? Color.red : Theme.muted)
                        .lineLimit(1).fixedSize()
                        .accessibilityLabel(tools.findInvalid ? "Invalid regular expression" : status)
                }
            }
            IconButton(icon: "chevron.up", help: "Previous match · ⇧↵", size: 30) { tools.moveFind(-1) }
                .disabled(!hasMatches).opacity(hasMatches ? 1 : 0.4)
            IconButton(icon: "chevron.down", help: "Next match · ↵", size: 30) { tools.moveFind(1) }
                .disabled(!hasMatches).opacity(hasMatches ? 1 : 0.4)
            IconButton(icon: "xmark", help: "Close · esc", size: 30) { tools.closeFind() }
        }
        .padding(5)
        .glassSurface(cornerRadius: 16)
        .frame(maxWidth: 620)
        .padding(.horizontal, 36).padding(.top, 10).padding(.bottom, 6)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Timeline

/// `/timeline`: one tick per turn beside the conversation, placed where the turn starts. The tick
/// for the turn at the top of the view is highlighted; hover previews a turn, click jumps to it.
struct TranscriptTimelineRail: View, Equatable {
    let ticks: [TranscriptTimelineTick]
    @ObservedObject var viewport: TranscriptViewportState
    let onSelect: @MainActor (TranscriptTurn) -> Void
    @State private var hovered: Int?

    private static let width: CGFloat = 30
    /// Room above and below the ticks for the previous/next turn buttons.
    private static let inset: CGFloat = 36

    init(ticks: [TranscriptTimelineTick], viewport: TranscriptViewportState, onSelect: @escaping @MainActor (TranscriptTurn) -> Void, hovered: Int? = nil) {
        self.ticks = ticks
        self.viewport = viewport
        self.onSelect = onSelect
        _hovered = State(initialValue: hovered)
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.ticks == rhs.ticks }

    private var active: Int? {
        guard let top = viewport.topMessageIndex, !ticks.isEmpty else { return nil }
        return ticks.lastIndex { $0.turn.messageIndex <= top } ?? 0
    }

    var body: some View {
        GeometryReader { geometry in
            let track = max(geometry.size.height - Self.inset * 2, 1)
            let active = self.active
            ZStack(alignment: .top) {
                Capsule().fill(Theme.line.opacity(0.7)).frame(width: 1, height: track).offset(y: Self.inset)
                ForEach(Array(ticks.enumerated()), id: \.element.id) { index, tick in
                    let isActive = index == active, isHovered = index == hovered
                    Capsule()
                        .fill(isActive ? Theme.accent : isHovered ? Theme.ink : Theme.muted.opacity(0.6))
                        .frame(width: isActive || isHovered ? 16 : 9, height: isActive ? 3 : 2)
                        .position(x: Self.width / 2, y: Self.inset + tick.position * track)
                }
                Color.clear
                    .frame(width: Self.width, height: track + 12)
                    .contentShape(Rectangle())
                    .offset(y: Self.inset - 6)
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let point): hovered = nearest(to: point.y - 6, track: track)
                        case .ended: hovered = nil
                        }
                    }
                    .onTapGesture { point in
                        if let index = nearest(to: point.y - 6, track: track) { onSelect(ticks[index].turn) }
                    }
                VStack(spacing: 0) {
                    IconButton(icon: "chevron.up", help: "Previous turn", size: 26) { step(-1, active: active) }
                        .disabled(ticks.isEmpty)
                    Spacer(minLength: 0)
                    IconButton(icon: "chevron.down", help: "Next turn", size: 26) { step(1, active: active) }
                        .disabled(ticks.isEmpty)
                }.padding(.vertical, 4)
            }
            .frame(width: Self.width, height: geometry.size.height)
            .overlay(alignment: .topTrailing) {
                if let hovered, ticks.indices.contains(hovered) {
                    TranscriptTimelinePreview(turn: ticks[hovered].turn, total: ticks.count)
                        .offset(x: -(Self.width + 4), y: max(4, min(Self.inset + ticks[hovered].position * track - 28, geometry.size.height - 96)))
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
        }
        .frame(width: Self.width)
        .padding(.trailing, 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Turn timeline, \(ticks.count) turns")
    }

    /// The tick nearest a point on the track, within reach of the pointer.
    private func nearest(to y: CGFloat, track: CGFloat) -> Int? {
        var best: (index: Int, distance: CGFloat)?
        for (index, tick) in ticks.enumerated() {
            let distance = abs(tick.position * track - y)
            if distance < (best?.distance ?? .infinity) { best = (index, distance) }
        }
        guard let best, best.distance <= max(8, track / CGFloat(max(ticks.count, 1)) / 2 + 2) else { return nil }
        return best.index
    }

    /// Previous goes first to the start of the turn being read, then to the turn before it.
    private func step(_ direction: Int, active: Int?) {
        guard !ticks.isEmpty else { return }
        let current = active ?? ticks.count - 1
        var target = current + direction
        if direction < 0, let top = viewport.topMessageIndex, ticks[current].turn.messageIndex < top { target = current }
        onSelect(ticks[min(max(target, 0), ticks.count - 1)].turn)
    }
}

private struct TranscriptTimelinePreview: View {
    let turn: TranscriptTurn
    let total: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text("Turn \(turn.number) of \(total)").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.muted)
                Spacer(minLength: 8)
                if let date = turn.date { Text(TranscriptTimestamp.label(date)).font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.muted) }
            }
            Text(turn.displayPreview).font(.system(size: 13)).foregroundStyle(turn.preview.isEmpty ? Theme.muted : Theme.ink)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(width: 270, alignment: .leading)
        .glassSurface(cornerRadius: 11)
    }
}

// MARK: - Host probe

/// An invisible view behind the transcript that tells the model which window and area it
/// occupies, for vim keys and clicks.
struct TranscriptHostProbe: NSViewRepresentable {
    let tools: TranscriptToolsModel

    func makeNSView(context: Context) -> TranscriptHostProbeView {
        let view = TranscriptHostProbeView()
        view.tools = tools
        return view
    }

    func updateNSView(_ view: TranscriptHostProbeView, context: Context) { view.tools = tools }

    static func dismantleNSView(_ view: TranscriptHostProbeView, coordinator: ()) { view.detach() }
}

final class TranscriptHostProbeView: NSView {
    weak var tools: TranscriptToolsModel?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { tools?.hostView = self } else { detach() }
    }

    func detach() { if tools?.hostView === self { tools?.hostView = nil } }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - Debug overlays

/// Developer overlays drawn above the conversation (`/debug`).
struct DebugOverlay: View {
    @EnvironmentObject var tools: TranscriptToolsModel

    var body: some View {
        if tools.debugScroll || tools.debugFPS || tools.scrollLogURL != nil {
            TranscriptDebugPanels(hud: tools.debugHUD, showScroll: tools.debugScroll, showFPS: tools.debugFPS, logURL: tools.scrollLogURL)
                .padding(.top, 10).padding(.trailing, 12)
                .allowsHitTesting(false)
        }
    }
}

/// The terminal's debug chrome: theme-agnostic dark panels with monospaced numbers.
struct TranscriptDebugPanels: View {
    @ObservedObject var hud: TranscriptDebugHUD
    let showScroll: Bool
    let showFPS: Bool
    let logURL: URL?

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if showFPS {
                panel("fps debug  (/debug fps)", [hud.frameLine])
                    .background(TranscriptFrameProbe(hud: hud))
            }
            if showScroll { panel("scroll debug  (/debug scroll)", hud.scrollLines) }
            if let logURL {
                panel("scroll log  (/debug log)", [logURL.lastPathComponent], recording: true).help(logURL.path)
            }
        }
        .environment(\.colorScheme, .dark)
        .task {
            while !Task.isCancelled {
                hud.refresh()
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    private func panel(_ title: String, _ lines: [String], recording: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if recording { Circle().fill(Color.red).frame(width: 7, height: 7).accessibilityLabel("Recording") }
                Text(title).foregroundStyle(.white.opacity(0.55))
            }
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in Text(line).foregroundStyle(.white) }
        }
        .font(.system(size: 11, design: .monospaced))
        .lineLimit(1)
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(width: 270, alignment: .leading)
        .background(Color.black.opacity(0.9), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
    }
}

/// Samples display refreshes while the FPS HUD is on. A frame that arrives late means the main
/// thread was busy, which is what makes scrolling and streaming stutter.
private struct TranscriptFrameProbe: NSViewRepresentable {
    let hud: TranscriptDebugHUD

    func makeNSView(context: Context) -> TranscriptFrameProbeView {
        let view = TranscriptFrameProbeView()
        view.hud = hud
        return view
    }

    func updateNSView(_ view: TranscriptFrameProbeView, context: Context) { view.hud = hud }

    static func dismantleNSView(_ view: TranscriptFrameProbeView, coordinator: ()) { view.stop() }
}

final class TranscriptFrameProbeView: NSView {
    weak var hud: TranscriptDebugHUD?
    private var link: CADisplayLink?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stop()
        guard window != nil else { return }
        let link = displayLink(target: self, selector: #selector(frame(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func frame(_ link: CADisplayLink) { hud?.recordFrame(timestamp: link.timestamp) }

    func stop() {
        link?.invalidate()
        link = nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - Settings

/// Conversation display preferences in Settings.
struct DisplaySettingsSection: View {
    @ObservedObject private var language = L10n.state
    @EnvironmentObject var tools: TranscriptToolsModel
    @AppStorage("compactConversation") private var compactConversation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(L10n.t("conversation", "Conversation"), systemImage: "text.bubble").font(.system(size: 15, weight: .semibold))
            VStack(spacing: 0) {
                row(L10n.t("display_timestamps", "Timestamps"), detail: L10n.t("display_timestamps_detail", "Show when each message was sent."), symbol: "clock",
                    isOn: Binding(get: { tools.showTimestamps }, set: { tools.setTimestamps($0) }))
                Divider().padding(.leading, 46)
                row(L10n.t("display_timeline", "Turn timeline"), detail: L10n.t("display_timeline_detail", "A rail beside the conversation for jumping between turns."),
                    symbol: "list.bullet.below.rectangle", isOn: Binding(get: { tools.showTimeline }, set: { tools.setTimeline($0) }))
                Divider().padding(.leading, 46)
                row(L10n.t("display_vim_keys", "Vim-style keys"), detail: L10n.t("display_vim_keys_detail", "j and k move between messages; y copies. Press esc in an empty prompt to start."),
                    symbol: "keyboard", isOn: Binding(get: { tools.vimMode }, set: { tools.setVimMode($0) }))
                Divider().padding(.leading, 46)
                row(L10n.t("display_compact", "Compact conversation"), detail: L10n.t("display_compact_detail", "Less space between messages."), symbol: "rectangle.compress.vertical", isOn: $compactConversation)
            }
        }
        .settingsCard()
        .onAppear { tools.loadPreferencesIfNeeded() }
    }

    private func row(_ title: String, detail: String, symbol: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 17)).foregroundStyle(Theme.muted)
                .frame(width: 34, height: 22).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Toggle(title, isOn: isOn).toggleStyle(.switch).labelsHidden().controlSize(.small)
        }
        .padding(.vertical, 10)
    }
}
