import SwiftUI

/// A session: header with live status, the plan bar, the transcript (bottom-anchored, paged), and the composer.
struct SessionScreen: View {
    let sessionDocId: DocID
    @Environment(CrokEngine.self) private var engine
    @State private var model: SessionViewModel?

    var body: some View {
        Group {
            if let model {
                SessionContent(model: model)
            } else {
                Theme.canvas.ignoresSafeArea()
            }
        }
        .onAppear {
            if model == nil { model = SessionViewModel(sessionDocId: sessionDocId, engine: engine) }
            model?.appear()
        }
        .onDisappear {
            // Popped: stop every subscription. Coming back builds a fresh model.
            model?.tearDown()
            model = nil
        }
    }
}

private struct SessionContent: View {
    @Bindable var model: SessionViewModel
    @Environment(CrokEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss
    @State private var showsInfo = false
    @State private var planExpanded = false
    @FocusState private var composerFocused: Bool

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
                        .id(Self.bottomID)
                        .onAppear { model.bottomVisibility(true) }
                        .onDisappear { model.bottomVisibility(false) }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
                // A readable column on iPad and in landscape.
                .frame(maxWidth: Self.readableWidth)
                .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .simultaneousGesture(
                DragGesture(minimumDistance: 12).onChanged { drag in
                    // A finger moving down scrolls toward older items.
                    if drag.translation.height > 12 { model.userScrolledUp() }
                })
            .background(Theme.canvas.ignoresSafeArea())
            .overlay {
                if model.isRemoved {
                    ContentUnavailableView(
                        "Session removed", systemImage: "trash",
                        description: Text("This session is no longer on the relay. It is still on its computer."))
                } else if !model.initialLoaded && model.items.isEmpty {
                    ProgressView()
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if !model.isAtBottom && !model.items.isEmpty {
                    ScrollToBottomButton(count: model.newWhileAway) {
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
                    withAnimation(.snappy) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                }
            }
            .onChange(of: model.contentTick) { _, _ in
                if model.shouldFollowBottom { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
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
                    .onTapGesture { showsInfo = true }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showsInfo = true
                } label: {
                    Image(systemName: "info.circle")
                }
                .accessibilityLabel(Text("Session info"))
                .accessibilityIdentifier("sessionInfoButton")
            }
        }
        .toolbar(.hidden, for: .tabBar)
        .sheet(isPresented: $showsInfo) {
            SessionInfoView(sessionDocId: model.sessionDocId, onRemoved: { dismiss() })
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
    static let readableWidth: CGFloat = 760

    private func topSpacing(for item: TranscriptItem) -> CGFloat {
        switch item.kind {
        case .day: 14
        case .notice: 10
        default: item.position.startsGroup ? 12 : 3
        }
    }
}

/// "working…", "waiting for approval on <computer>", "idle · <computer>", "offline".
private struct SessionSubtitle: View {
    let model: SessionViewModel

    var body: some View {
        Group {
            if model.isRemoved {
                Text("removed")
            } else if !model.isOnline {
                Text("offline")
            } else {
                switch model.status {
                case .running:
                    WorkingIndicator(font: .caption)
                case .waiting:
                    Text("waiting for approval on \(model.computerName)")
                        .foregroundStyle(Theme.waiting)
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
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().strokeBorder(Theme.hairline))
                .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
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
