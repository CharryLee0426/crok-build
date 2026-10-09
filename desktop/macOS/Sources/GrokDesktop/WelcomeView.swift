import SwiftUI
import AppKit

/// A new task's empty conversation: the mark, a greeting for the time of day in a script hand,
/// starter prompts that roll up one after another, and the project the task will work in. Sizes
/// follow the room the conversation has, from a narrow column beside the side panel to full screen.
struct WelcomeView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        GeometryReader { proxy in
            let metrics = WelcomeMetrics(size: proxy.size)
            VStack(spacing: 0) {
                Spacer(minLength: 8)
                if metrics.showsMark {
                    GrokMark(size: metrics.markSize).padding(.bottom, metrics.markGap)
                }
                WelcomeGreeting(fontSize: metrics.greetingSize)
                StarterTicker(starters: WelcomeStarter.all, fontSize: metrics.tickerSize, enabled: store.project != nil) { starter in
                    store.draft = starter.prompt
                    NotificationCenter.default.post(name: .grokFocusComposer, object: nil)
                }
                .padding(.top, metrics.tickerGap)
                project.padding(.top, metrics.projectGap)
                Spacer(minLength: 8)
                // Sits a little above the middle, where the eye expects it.
                Spacer(minLength: 0).frame(maxHeight: metrics.greetingSize * 0.6)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .padding(.horizontal, 32)
    }

    @ViewBuilder private var project: some View {
        if let project = store.project {
            Menu {
                ForEach(store.state.projects) { item in
                    Button { store.selectProject(item.id) } label: {
                        if item.id == project.id { Label(item.name, systemImage: "checkmark") } else { Text(item.name) }
                    }
                }
                Divider()
                Button("Open Another Folder…", systemImage: "folder.badge.plus") { store.addProject() }
            } label: {
                HStack(spacing: 7) { Image(systemName: "folder"); Text(project.name); Image(systemName: "chevron.down").font(.system(size: 8)) }
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.muted).padding(.horizontal, 12).padding(.vertical, 8)
                    .glassSurface(in: Capsule(), interactive: true).contentShape(Capsule())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help(project.path).accessibilityLabel("Project: \(project.name)")
        } else {
            Button("Open a project") { store.addProject() }.buttonStyle(SubtleButtonStyle())
        }
    }
}

/// The welcome's sizes for the room it has. The greeting sets the scale; everything else follows it.
struct WelcomeMetrics: Equatable {
    var greetingSize: CGFloat
    var tickerSize: CGFloat
    var markSize: CGFloat
    var showsMark: Bool
    var markGap: CGFloat
    var tickerGap: CGFloat
    var projectGap: CGFloat

    static let greetingRange: ClosedRange<CGFloat> = 34...72
    static let tickerRange: ClosedRange<CGFloat> = 16...24

    init(size: CGSize) {
        let greeting = Self.clamp(min(size.width * 0.105, size.height * 0.13), to: Self.greetingRange)
        greetingSize = greeting.rounded()
        tickerSize = Self.clamp(greeting * 0.36, to: Self.tickerRange).rounded()
        // A short window keeps the words and lets the mark go.
        showsMark = size.height >= 340
        markSize = Self.clamp(greeting * 0.72, to: 32...47).rounded()
        markGap = (greeting * 0.32).rounded()
        tickerGap = (greeting * 0.1).rounded()
        projectGap = (greeting * 0.36).rounded()
    }

    private static func clamp(_ value: CGFloat, to range: ClosedRange<CGFloat>) -> CGFloat {
        min(range.upperBound, max(range.lowerBound, value.isFinite ? value : range.lowerBound))
    }
}

/// The script faces of the welcome: a formal hand for the greeting and a lighter, more legible one
/// under it. Both ship with macOS; a Mac without them gets an italic serif.
enum WelcomeHandwriting {
    static let greetingFaces = ["SnellRoundhand-Bold", "SnellRoundhand"]
    static let secondaryFaces = ["Apple-Chancery", "SnellRoundhand"]

    private static let greetingFace = installed(greetingFaces)
    private static let secondaryFace = installed(secondaryFaces)

    static func greeting(size: CGFloat) -> Font {
        greetingFace.map { .custom($0, fixedSize: size) } ?? .system(size: size, weight: .semibold, design: .serif).italic()
    }

    static func secondary(size: CGFloat) -> Font {
        secondaryFace.map { .custom($0, fixedSize: size) } ?? .system(size: size, design: .serif).italic()
    }

    private static func installed(_ names: [String]) -> String? {
        names.first { NSFont(name: $0, size: 12) != nil }
    }
}

/// "Good morning", "Good afternoon", "Good evening", or "Good night", by this Mac's clock. It
/// changes at the hour it should even when the window is left open.
struct WelcomeGreeting: View {
    let fontSize: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    static func text(at date: Date, calendar: Calendar = .current) -> String {
        switch calendar.component(.hour, from: date) {
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        case 17..<22: return "Good evening"
        default: return "Good night"
        }
    }

    var body: some View {
        TimelineView(.everyMinute) { context in
            Text(Self.text(at: context.date))
                .font(WelcomeHandwriting.greeting(size: fontSize))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                // Script capitals and descenders reach past the line; this keeps them clear of their neighbours.
                .padding(.horizontal, fontSize * 0.12)
                .padding(.vertical, fontSize * 0.04)
                .accessibilityAddTraits(.isHeader)
        }
        .opacity(shown ? 1 : 0)
        .offset(y: shown || reduceMotion ? 0 : fontSize * 0.12)
        .onAppear { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.5)) { shown = true } }
    }
}

/// A starter prompt on the welcome page.
struct WelcomeStarter: Identifiable, Equatable {
    var id: String { title }
    let title: String
    let symbol: String
    let prompt: String

    static let all = [
        WelcomeStarter(title: "Explore the codebase", symbol: "square.stack.3d.up",
                       prompt: "Explore this codebase. Explain its architecture, the main entry points, and how to run it."),
        WelcomeStarter(title: "Build something", symbol: "hammer",
                       prompt: "I'd like to build a new feature in this project. First, inspect the codebase and ask me what I want to create."),
        WelcomeStarter(title: "Review changes", symbol: "checkmark.bubble",
                       prompt: "Review the current uncommitted changes for bugs, regressions, and missing edge cases. Give concrete findings with file references."),
    ]
}

/// One starter at a time, each rolling up out of sight as the next rises in its place. Pointing at
/// it holds it still; a click puts its prompt in the composer. With Reduce Motion they cross-fade.
struct StarterTicker: View {
    let starters: [WelcomeStarter]
    let fontSize: CGFloat
    let enabled: Bool
    var choose: (WelcomeStarter) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var index = 0
    @State private var hovered = false

    /// How long each starter stays before the next rolls in.
    static let dwell: UInt64 = 3_200_000_000

    private var height: CGFloat { (fontSize * 2.3).rounded() }

    var body: some View {
        let starter = starters[index % max(1, starters.count)]
        ZStack {
            row(starter)
                .id(starter.id)
                .transition(transition)
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .mask {
            // The rows fade out at the top and in at the bottom as they roll.
            LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.2),
                                   .init(color: .black, location: 0.8), .init(color: .clear, location: 1)],
                           startPoint: .top, endPoint: .bottom)
        }
        .onHover { hovered = $0 }
        .task(id: starters.count) { await roll() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Suggestion: \(starter.title)")
        .accessibilityHint(enabled ? "Puts this prompt in the composer" : "Open a project first")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { if enabled { choose(starter) } }
        .accessibilityActions {
            ForEach(starters) { item in
                Button(item.title) { if enabled { choose(item) } }
            }
        }
    }

    private func row(_ starter: WelcomeStarter) -> some View {
        Button { choose(starter) } label: {
            HStack(spacing: (fontSize * 0.45).rounded()) {
                Image(systemName: starter.symbol)
                    .font(.system(size: (fontSize * 0.62).rounded(), weight: .regular))
                    .foregroundStyle(Theme.accent)
                Text(starter.title)
                    .font(WelcomeHandwriting.secondary(size: fontSize))
                    .foregroundStyle(hovered && enabled ? Theme.ink : Theme.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .padding(.horizontal, (fontSize * 0.75).rounded())
            .padding(.vertical, (fontSize * 0.2).rounded())
            .background(hovered && enabled ? Theme.hover.opacity(0.75) : .clear, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.55)
        .help(enabled ? starter.prompt : "Open a project to start a task")
        .animation(.easeOut(duration: 0.15), value: hovered)
    }

    private var transition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        let travel = height * 0.55
        return .asymmetric(insertion: .offset(y: travel).combined(with: .opacity),
                           removal: .offset(y: -travel).combined(with: .opacity))
    }

    private func roll() async {
        guard starters.count > 1 else { return }
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: Self.dwell)
            guard !Task.isCancelled else { return }
            if hovered { continue }
            withAnimation(reduceMotion ? .easeInOut(duration: 0.35) : .smooth(duration: 0.6)) {
                index = (index + 1) % starters.count
            }
        }
    }
}
