import SwiftUI

/// A session: header with live status, the plan bar, the transcript (bottom-anchored, paged), and the composer. For a
/// new session (the list's "+", the compose button, `/new`), first the new-session screen, which becomes the session
/// once `sessions:create` answers.
struct SessionScreen: View {
    let route: SessionRoute
    @Environment(CrokEngine.self) private var engine
    @Environment(\.openSessionRoute) private var openRoute
    @State private var model: SessionViewModel?
    @State private var newModel: NewSessionModel?
    /// The session a new-session entry turned into.
    @State private var createdId: DocID?

    var body: some View {
        // Read while the view is installed; `/new` uses it later, from a closure.
        let openRoute = self.openRoute
        return Group {
            if let model {
                SessionContent(model: model)
            } else if let newModel {
                NewSessionContent(model: newModel)
            } else {
                SessionBackgroundView().ignoresSafeArea()
            }
        }
        .onAppear {
            if model == nil { setUp(openRoute) }
            model?.appear()
        }
        .onDisappear {
            // Popped or covered: stop every subscription. Coming back builds a fresh model.
            model?.tearDown()
            model = nil
        }
    }

    private func setUp(_ openRoute: OpenSessionRouteAction) {
        switch route {
        case .session(let id):
            open(id, openRoute)
        case .new(let new):
            if let id = createdId ?? engine.startedSessions[new.clientId] {
                open(id, openRoute)
                return
            }
            guard newModel == nil else { return }
            let created = NewSessionModel(target: new.target, engine: engine, draft: new.prompt ?? "", clientId: new.clientId)
            created.onCreated = { id in
                createdId = id
                open(id, openRoute)
                model?.appear()
                newModel = nil
            }
            newModel = created
            if let prompt = new.prompt, !prompt.isEmpty {
                // `/new <prompt>`: at once.
                Task { await created.send() }
            }
        }
    }

    private func open(_ id: DocID, _ openRoute: OpenSessionRouteAction) {
        let session = SessionViewModel(sessionDocId: id, engine: engine)
        session.onNewSession = { target, prompt in
            openRoute(.new(NewSessionRoute(target: target, prompt: prompt)))
        }
        model = session
    }
}

private struct SessionContent: View {
    @Bindable var model: SessionViewModel
    @Environment(CrokEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss
    @State private var planExpanded = false
    @FocusState private var composerFocused: Bool
    @AppStorage(SessionTheme.storageKey) private var themeID = SessionTheme.noneID
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if model.hasOlder {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                        .padding(.vertical, 12)
                        .onAppear { model.loadOlder() }
                    }
                    ForEach(model.items) { item in
                        TranscriptRow(item: item, model: model)
                            .padding(.top, topSpacing(for: item))
                            .id(item.id)
                    }
                    Color.clear
                        .frame(height: 1)
                        .modifier(BottomSentinel(model: model, endPadding: Self.endPadding))
                        // Outermost, so the lazy stack finds it for `scrollTo` before it has laid it out.
                        .id(Self.bottomID)
                }
                .padding(.horizontal, 10)
                .padding(.bottom, Self.endPadding)
                // A readable column on iPad and in landscape.
                .frame(maxWidth: Self.readableWidth)
                .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .modifier(BottomTracking(model: model))
            .background(SessionBackgroundView().ignoresSafeArea())
            .environment(\.sessionPalette, SessionPalette.make(SessionTheme.named(themeID), dark: colorScheme == .dark))
            .overlay {
                if model.isRemoved {
                    ContentUnavailableView(
                        "Session removed", systemImage: "trash",
                        description: Text("This session is no longer on the relay. It is still on its computer."))
                } else if model.awaitsHistory {
                    HistoryPlaceholder(computerName: model.computerName, computerOnline: model.isComputerOnline)
                } else if !model.initialLoaded && model.items.isEmpty {
                    ProgressView()
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if !model.isAtBottom && !model.items.isEmpty {
                    ScrollToBottomButton(count: model.newWhileAway) {
                        model.followBottom()
                        withAnimation(.snappy) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                    }
                    .padding(.trailing, 14)
                    .padding(.bottom, 12)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if let summary = PlanSummary.make(model.plan) {
                    PlanBar(summary: summary, plan: model.plan, expanded: $planExpanded)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ComposerView(model: model, focused: $composerFocused) {
                    model.followBottom()
                    withAnimation(.snappy) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                }
                .modifier(VisibleBottomEdge(model: model))
            }
            .onChange(of: model.contentTick) { _, _ in
                if model.shouldFollowBottom { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
            }
            .onChange(of: model.pinTick) { _, _ in
                proxy.scrollTo(Self.bottomID, anchor: .bottom)
            }
            .onChange(of: composerFocused) { _, focused in
                guard focused, model.shouldFollowBottom else { return }
                // After the keyboard has moved the composer up.
                Task {
                    try? await Task.sleep(for: .milliseconds(350))
                    withAnimation(.snappy) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                ConnectionTitleView(
                    title: model.title, connection: engine.connection, subtitle: AnyView(SessionSubtitle(model: model)))
                    .onTapGesture { model.showsInfo = true }
            }
            ToolbarItem(placement: .topBarTrailing) {
                // The topic's icon, where Telegram shows the chat's avatar; a tap opens the session's info.
                Button {
                    model.showsInfo = true
                } label: {
                    TopicIconView(sessionDocId: model.sessionDocId, title: model.title, size: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Session info"))
                .accessibilityIdentifier("sessionInfoButton")
            }
        }
        .toolbar(.hidden, for: .tabBar)
        .sheet(isPresented: $model.showsInfo) {
            SessionInfoView(sessionDocId: model.sessionDocId, session: model, onRemoved: { dismiss() })
                .environment(engine)
        }
        .onChange(of: engine.localPrompts[model.sessionDocId]) { _, _ in model.rebuild() }
        .alert(
            "Couldn't do that",
            isPresented: Binding(get: { model.actionError != nil }, set: { if !$0 { model.actionError = nil } }),
            presenting: model.actionError
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { error in
            Text(error.message)
        }
    }

    static let bottomID = "transcript-bottom"
    /// Space under the last row, after the bottom sentinel.
    static let endPadding: CGFloat = 10
    static let readableWidth: CGFloat = 760

    private func topSpacing(for item: TranscriptItem) -> CGFloat {
        switch item.kind {
        case .day: 14
        case .notice: 10
        default: item.position.startsGroup ? 12 : 3
        }
    }
}

/// "working…", "waiting for approval on <computer>" ("Needs approval" while the card above the composer can answer it),
/// "idle · <computer>" (also for a session nobody runs on an online computer), "offline" (the computer is).
private struct SessionSubtitle: View {
    let model: SessionViewModel

    var body: some View {
        Group {
            if model.isRemoved {
                Text("removed")
            } else if model.isStarting && model.isComputerOnline {
                Text("starting on \(model.computerName)…")
            } else {
                switch model.presence {
                case .offline:
                    Text("offline")
                case .running:
                    WorkingIndicator(font: .caption)
                case .waiting:
                    if model.pendingRequest != nil {
                        Text("Needs approval")
                            .foregroundStyle(Theme.waiting)
                    } else {
                        Text("waiting for approval on \(model.computerName)")
                            .foregroundStyle(Theme.waiting)
                    }
                case .error:
                    Text("error · \(model.computerName)")
                        .foregroundStyle(Theme.danger)
                case .idle:
                    Text("idle · \(model.computerName)")
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .accessibilityIdentifier("sessionSubtitle")
    }
}

/// A session listed from its computer's disk, before its transcript arrives: "Loading from <computer>…" while the
/// computer is online (opening the session asked a crok there for it), else why nothing can show yet.
private struct HistoryPlaceholder: View {
    let computerName: String
    let computerOnline: Bool

    var body: some View {
        VStack(spacing: 14) {
            if computerOnline {
                ProgressView()
                Text("Loading from \(computerName)…")
            } else {
                Image(systemName: "desktopcomputer")
                    .font(.title2)
                Text("\(computerName) is offline. This session's history shows once crok runs there again.")
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 320)
        .padding(24)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(computerOnline ? "historyLoading" : "historyOffline")
    }
}

/// Where the transcript's end is and who moves it. iOS 18+: from the scroll view's geometry and phase, for
/// `BottomFollower`; exact inside a reply taller than the screen too. iOS 17: from the bottom sentinel coming and going
/// (`BottomSentinel`) and the drag that scrolls toward older items.
private struct BottomTracking: ViewModifier {
    let model: SessionViewModel

    struct Geometry: Equatable {
        /// How far the content's end is below the visible bottom edge; 0 when it all fits.
        var distance: Double
        var overflows: Bool
    }

    func body(content: Content) -> some View {
        if #available(iOS 18, *) {
            content
                .onScrollGeometryChange(for: Geometry.self) { geometry in
                    // `containerSize` is the visible area: the scroll view less its safe areas (the bars above, the
                    // composer below). Content shorter than that is all in sight: `defaultScrollAnchor` bottom-aligns it
                    // by adding to the top inset. Taller content: the top inset is the bars, and the visible area ends
                    // at offset + top inset + its height.
                    let content = geometry.contentSize.height, visible = geometry.containerSize.height
                    guard content > visible else { return Geometry(distance: 0, overflows: false) }
                    let distance = content - (geometry.contentOffset.y + geometry.contentInsets.top + visible)
                    return Geometry(distance: distance.rounded(), overflows: true)
                } action: { _, geometry in
                    model.scrollGeometryChanged(distanceFromBottom: geometry.distance, overflows: geometry.overflows)
                }
                .onScrollPhaseChange { _, phase in
                    model.scrollPhaseChanged(BottomFollower.Phase(phase))
                }
        } else {
            content.simultaneousGesture(
                DragGesture(minimumDistance: 12).onChanged { drag in
                    // A finger moving down scrolls toward older items.
                    if drag.translation.height > 12 { model.userScrolledUp() }
                })
        }
    }
}

/// The 1 pt view after the last row. iOS 18+: reports where the last row really ends on screen (it, plus the stack's
/// bottom padding), which `VisibleBottomEdge` compares with the composer's top to catch a blank stretch under the end
/// that the scroll geometry cannot see. iOS 17: tells the model when it comes and goes; a lazy stack keeps it a while
/// after it leaves the screen, so inside a tall last reply this still reads as at the bottom.
private struct BottomSentinel: ViewModifier {
    let model: SessionViewModel
    let endPadding: CGFloat

    func body(content: Content) -> some View {
        if #available(iOS 18, *) {
            content
                .onGeometryChange(for: Double.self) { ($0.frame(in: .global).maxY + endPadding).rounded() } action: {
                    model.sentinelMoved(to: $0)
                }
                .onDisappear { model.sentinelMoved(to: nil) }
        } else {
            content
                .onAppear { model.bottomVisibility(true) }
                .onDisappear { model.bottomVisibility(false) }
        }
    }
}

/// iOS 18+: the composer's top, where the visible part of the transcript ends on screen.
private struct VisibleBottomEdge: ViewModifier {
    let model: SessionViewModel

    func body(content: Content) -> some View {
        if #available(iOS 18, *) {
            content.onGeometryChange(for: Double.self) { $0.frame(in: .global).minY.rounded() } action: {
                model.visibleBottomMoved(to: $0)
            }
        } else {
            content
        }
    }
}

@available(iOS 18, *)
extension BottomFollower.Phase {
    init(_ phase: ScrollPhase) {
        switch phase {
        case .idle: self = .idle
        case .tracking, .interacting, .decelerating: self = .user
        case .animating: self = .animating
        @unknown default: self = .idle
        }
    }
}

/// Telegram's page-down button, with the number of items that arrived while scrolled up.
private struct ScrollToBottomButton: View {
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.down")
                .font(.body.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 42, height: 42)
                .glassSurface(in: Circle(), interactive: true)
                .overlay {
                    if !hasLiquidGlass { Circle().strokeBorder(Theme.hairline) }
                }
                .shadow(color: .black.opacity(hasLiquidGlass ? 0 : 0.12), radius: 6, y: 2)
                .overlay(alignment: .top) {
                    if count > 0 {
                        UnreadBadge(count: count)
                            .offset(y: -12)
                    }
                }
        }
        .accessibilityLabel(Text("Scroll to the latest message"))
        .accessibilityIdentifier("scrollToBottom")
    }
}

/// The pinned plan bar: "Plan 3/7 · <item in progress>"; tap for the whole list.
struct PlanBar: View {
    let summary: PlanSummary
    let plan: [PlanEntry]
    @Binding var expanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy) { expanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Theme.accent)
                        .frame(width: 3, height: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Plan \(summary.done)/\(summary.total)")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.accent)
                        Text(summary.current ?? String(localized: "All steps done"))
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("planBar")
            if expanded {
                if plan.count > 7 {
                    ScrollView { planList }
                        .frame(height: 260)
                } else {
                    planList
                }
            }
        }
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var planList: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(plan.enumerated()), id: \.offset) { _, entry in
                PlanEntryRow(entry: entry)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 2)
        .padding(.bottom, 10)
        .accessibilityIdentifier("planList")
    }
}

struct PlanEntryRow: View {
    let entry: PlanEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            switch PlanItemState(entry.status) {
            case .completed:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
            case .inProgress:
                Image(systemName: "circle.dotted.circle").foregroundStyle(Theme.accent)
            case .pending, .other:
                Image(systemName: "circle").foregroundStyle(.secondary)
            }
            Text(entry.content)
                .font(.subheadline)
                .strikethrough(PlanItemState(entry.status) == .completed, color: .secondary)
                .foregroundStyle(PlanItemState(entry.status) == .completed ? Color.secondary : Color.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
