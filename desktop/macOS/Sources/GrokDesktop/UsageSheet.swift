import AppKit
import SwiftUI

// MARK: - State

/// A value a panel loads from the harness.
enum AccountLoad<Value> {
    case idle
    case loading
    case loaded(Value)
    case failed(String)
    /// Not applicable here, with the reason to show instead.
    case unavailable(String)

    var value: Value? { if case .loaded(let value) = self { return value }; return nil }
}

extension AccountLoad: Equatable where Value: Equatable {}

struct UsageSheetState {
    var context: AccountLoad<UsageContextSnapshot> = .idle
    var contextModel = "unknown"
    var sessionInfo: AccountLoad<[UsageSessionInfoRow]> = .idle
    var sessionUsage: AccountLoad<UsageSessionSummary> = .idle
}

// MARK: - Harness payloads

enum AccountJSON {
    static func uint(_ value: Any?) -> UInt64 {
        if let number = value as? NSNumber { return number.doubleValue <= 0 ? 0 : number.uint64Value }
        if let text = value as? String, let parsed = UInt64(text) { return parsed }
        return 0
    }

    static func int(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber { return number.int64Value }
        if let text = value as? String { return Int64(text) }
        return nil
    }

    static func string(_ value: Any?) -> String? {
        (value as? String).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
    }
}

/// The context window breakdown from `_x.ai/session/info`.
struct UsageContextSnapshot: Equatable {
    struct Category: Equatable, Identifiable {
        var id: String { label }
        let label: String
        let tokens: UInt64
        let detail: String?
    }

    var used: UInt64 = 0
    var total: UInt64 = 0
    var systemPromptTokens: UInt64 = 0
    var toolDefinitionsCount: UInt64 = 0
    var toolDefinitionsTokens: UInt64 = 0
    var compactionCount: UInt64 = 0
    var turnCount: UInt64 = 0
    var toolCallCount: UInt64 = 0
    var messageTokens: UInt64 = 0
    var usagePercent: UInt64 = 0
    var autoCompactThresholdPercent: UInt64 = 85
    var categories: [Category] = []

    init() {}

    init(_ context: [String: Any]) {
        used = AccountJSON.uint(context["used"])
        total = AccountJSON.uint(context["total"])
        systemPromptTokens = AccountJSON.uint(context["systemPromptTokens"])
        toolDefinitionsCount = AccountJSON.uint(context["toolDefinitionsCount"])
        toolDefinitionsTokens = AccountJSON.uint(context["toolDefinitionsTokens"])
        compactionCount = AccountJSON.uint(context["compactionCount"])
        turnCount = AccountJSON.uint(context["turnCount"])
        toolCallCount = AccountJSON.uint(context["toolCallCount"])
        messageTokens = AccountJSON.uint(context["messageTokens"])
        usagePercent = AccountJSON.uint(context["usagePct"])
        if context["autoCompactThresholdPercent"] != nil { autoCompactThresholdPercent = AccountJSON.uint(context["autoCompactThresholdPercent"]) }
        categories = (context["usageCategories"] as? [[String: Any]] ?? []).compactMap { entry in
            guard let label = AccountJSON.string(entry["label"]) else { return nil }
            return Category(label: label, tokens: AccountJSON.uint(entry["tokens"]), detail: AccountJSON.string(entry["detail"]))
        }
    }

    /// System prompt, messages, and overhead share the used part of the window; the rest is free.
    /// Reported parts can exceed what is used, and use can exceed the window.
    var window: (system: UInt64, messages: UInt64, overhead: UInt64, free: UInt64) {
        let clamped = min(used, total)
        let system = min(systemPromptTokens, clamped)
        let messages = min(messageTokens, clamped - system)
        return (system, messages, clamped - system - messages, total > used ? total - used : 0)
    }

    var summary: String {
        "\(UsageFormatting.tokensBig(used)) / \(UsageFormatting.tokensBig(total)) tokens (\(String(format: "%.2f", UsageFormatting.precisePercent(used, total)))%)"
    }

    /// The auto-compact line, and whether it is a warning.
    var autoCompact: (text: String, warning: Bool)? {
        guard total > 0 else { return nil }
        let threshold = autoCompactThresholdPercent
        // Rounded up, so a tiny window never reads "~0 tokens remaining" before the threshold.
        let thresholdTokens = (total * threshold + 99) / 100
        if usagePercent >= threshold { return ("Auto-compact triggers next turn (at \(threshold)%)", true) }
        let remaining = thresholdTokens > used ? thresholdTokens - used : 0
        return ("Auto-compact at \(threshold)% · ~\(UsageFormatting.tokensBig(remaining)) tokens remaining", false)
    }

    var stats: String { "Turns: \(turnCount) · Tool calls: \(toolCallCount) · Compactions: \(compactionCount)" }

    /// Shown only between "getting close" (80%) and the auto-compact threshold.
    var showsCompactTip: Bool { usagePercent >= 80 && usagePercent < autoCompactThresholdPercent }
}

/// `_x.ai/session/info`: the session and its model, plus the context breakdown.
struct UsageSessionInfo {
    var sessionID = ""
    var cwd = ""
    var model: String?
    var modelDisplayName: String?
    var resolvedModelID: String?
    var modelFingerprint: String?
    var showModelFingerprint = false
    var apiBackend: String?
    var conversationID: String?
    var turnIndex: UInt64 = 0
    var context = UsageContextSnapshot()

    init(_ value: [String: Any]) {
        sessionID = value["sessionId"] as? String ?? ""
        cwd = value["cwd"] as? String ?? ""
        model = AccountJSON.string(value["model"])
        modelDisplayName = AccountJSON.string(value["modelDisplayName"])
        resolvedModelID = AccountJSON.string(value["resolvedModelId"])
        modelFingerprint = AccountJSON.string(value["modelFingerprint"])
        showModelFingerprint = value["showModelFingerprint"] as? Bool ?? false
        apiBackend = AccountJSON.string(value["apiBackend"])
        conversationID = AccountJSON.string(value["conversationId"])
        turnIndex = AccountJSON.uint(value["turnIndex"])
        context = UsageContextSnapshot(value["context"] as? [String: Any] ?? [:])
    }
}

struct UsageSessionInfoRow: Identifiable, Equatable {
    var id: String { label }
    let label: String
    let value: String
    var note: String?
    var monospaced = false
}

/// `_x.ai/session/usage`: token and cost totals since the session started or was last resumed.
struct UsageSessionSummary: Equatable {
    struct Row: Equatable, Identifiable {
        var id: String { label }
        let label: String
        let value: String
    }

    var emptyMessage: String?
    var rows: [Row] = []
    var models: [Row] = []
    var incomplete = false

    init(_ usage: [String: Any]) {
        incomplete = usage["usageIsIncomplete"] as? Bool ?? false
        let modelUsage = usage["modelUsage"] as? [String: [String: Any]] ?? [:]
        let calls = AccountJSON.uint(usage["modelCalls"])
        if calls == 0 && modelUsage.isEmpty {
            emptyMessage = incomplete
                ? "Session usage: none recorded, but tracking is incomplete and may under-count."
                : "Session usage: no model calls yet in this session."
            return
        }
        let group = UsageFormatting.groupThousands
        rows = [
            Row(label: "Input tokens", value: "\(group(AccountJSON.uint(usage["inputTokens"]))) (\(group(AccountJSON.uint(usage["cachedReadTokens"]))) cached)"),
            Row(label: "Output tokens", value: "\(group(AccountJSON.uint(usage["outputTokens"]))) (\(group(AccountJSON.uint(usage["reasoningTokens"]))) reasoning)"),
            Row(label: "Total tokens", value: group(AccountJSON.uint(usage["totalTokens"]))),
            Row(label: "Model calls", value: "\(group(calls)) · API time: \(UsageFormatting.duration(milliseconds: AccountJSON.uint(usage["apiDurationMs"])))"),
            Row(label: "Cost", value: UsageFormatting.cost(usage)),
        ]
        if modelUsage.count > 1 {
            models = modelUsage.keys.sorted().map { name in
                let model = modelUsage[name] ?? [:]
                return Row(label: name, value: "\(group(AccountJSON.uint(model["inputTokens"]))) in / \(group(AccountJSON.uint(model["outputTokens"]))) out · \(UsageFormatting.cost(model))")
            }
        }
    }

    /// The same block as text, as the terminal prints it.
    var text: String {
        if let emptyMessage { return emptyMessage }
        var lines = ["Session usage (since start or last resume):"] + rows.map { "  \($0.label): \($0.value)" }
        if !models.isEmpty { lines.append("  By model:"); lines += models.map { "    \($0.label): \($0.value)" } }
        if incomplete { lines.append("  Note: usage is incomplete and may under-count.") }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Formatting

enum UsageFormatting {
    /// `123`, `1.2k`, `999k`. Rounds to whole thousands from 99,500 so `99.9k` never jumps to `100.0k`.
    static func tokens(_ value: UInt64) -> String {
        if value >= 99_500 { return "\((value + 500) / 1000)k" }
        if value >= 1_000 { return String(format: "%.1fk", Double(value) / 1000) }
        return "\(value)"
    }

    /// Like `tokens`, rolling over to `1.0m` at a million.
    static func tokensBig(_ value: UInt64) -> String {
        value >= 1_000_000 ? String(format: "%.1fm", Double(value) / 1_000_000) : tokens(value)
    }

    static func precisePercent(_ used: UInt64, _ total: UInt64) -> Double {
        total == 0 ? 0 : Double(used) / Double(total) * 100
    }

    /// A part's share of the window; tiny nonzero shares show as 0.1%.
    static func percentOfWindow(_ part: UInt64, _ total: UInt64) -> String {
        guard total > 0 else { return "-" }
        let percent = max(Double(part) / Double(total) * 100, part > 0 ? 0.1 : 0)
        return percent < 10 ? String(format: "%.1f%%", percent) : String(format: "%.0f%%", percent)
    }

    static func groupThousands(_ value: UInt64) -> String {
        let digits = String(value)
        var result = ""
        for (index, character) in digits.enumerated() {
            if index > 0 && (digits.count - index) % 3 == 0 { result.append(",") }
            result.append(character)
        }
        return result
    }

    /// `5.2s`, `32s`, `2m5s`, `1h2m`.
    static func duration(milliseconds: UInt64) -> String {
        let seconds = milliseconds / 1000
        if seconds < 10 { return String(format: "%.1fs", Double(milliseconds) / 1000) }
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m\(seconds % 60)s" }
        return "\(minutes / 60)h\(minutes % 60)m"
    }

    /// Cost in USD from `costUsdTicks` (10^10 ticks per dollar). An absent cost is unknown, never free.
    static func cost(_ usage: [String: Any]) -> String {
        if let ticks = AccountJSON.int(usage["costUsdTicks"]) { return String(format: "$%.4f", Double(ticks) / 10_000_000_000) }
        return usage["costIsPartial"] as? Bool == true ? "not available (not reported for some calls)" : "not available (not reported)"
    }

    static func countDetail(_ count: UInt64, _ noun: String) -> String { "\(count) \(noun)\(count == 1 ? "" : "s")" }

    static func parseDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    /// The catalog name when there is one; otherwise the model, with the resolved slug when shown.
    static func modelName(display: String?, model: String, resolved: String?, showResolved: Bool) -> String {
        if let display { return display }
        if showResolved, let resolved, resolved != model { return "\(model) (\(resolved))" }
        return model
    }

    static func sessionInfoRows(_ info: UsageSessionInfo, title: String?, shellVersion: String?, auth: AccountAuthDescription,
                                showResolvedModel: Bool) -> [UsageSessionInfoRow] {
        var rows: [UsageSessionInfoRow] = []
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty { rows.append(.init(label: "Title", value: title)) }
        rows.append(.init(label: "Shell version", value: shellVersion ?? "unknown"))
        rows.append(.init(label: "Auth method", value: auth.method, note: auth.note))
        rows.append(.init(label: "Session ID", value: info.sessionID, monospaced: true))
        if let conversation = info.conversationID { rows.append(.init(label: "Conversation ID", value: conversation, monospaced: true)) }
        rows.append(.init(label: "Working directory", value: info.cwd, monospaced: true))
        let model = info.model ?? "unknown"
        rows.append(.init(label: "Model", value: modelName(display: info.modelDisplayName, model: model, resolved: info.resolvedModelID, showResolved: showResolvedModel)))
        if info.showModelFingerprint, let fingerprint = info.modelFingerprint { rows.append(.init(label: "Model Hash", value: fingerprint, monospaced: true)) }
        if let backend = info.apiBackend { rows.append(.init(label: "API Backend", value: backend)) }
        rows.append(.init(label: "Turn", value: String(info.turnIndex)))
        let context = info.context
        rows.append(.init(label: "Context", value: "\(groupThousands(context.used)) / \(groupThousands(context.total)) tokens (\(context.usagePercent)%)"))
        return rows
    }

    static func copyText(_ rows: [UsageSessionInfoRow]) -> String {
        rows.map { "\($0.label): \($0.value)" }.joined(separator: "\n")
    }
}

// MARK: - Views

/// `/usage`, `/context`, and `/session-info`: one sheet with the terminal's three tabs.
struct UsageSheet: View {
    let initialTab: UsageTab
    /// Snapshot tests show a prepared state instead of loading.
    var loadsOnAppear = true
    @EnvironmentObject var account: AccountFeatureModel

    var body: some View {
        DesktopPanel(title: "Usage", subtitle: "Context window, token usage, and details for the current task.",
                     width: 680, height: 700, onClose: close) {
            VStack(spacing: 0) {
                Picker("Section", selection: $account.usageTab) {
                    ForEach(UsageTab.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().controlSize(.large)
                .padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 6)
                ScrollView {
                    tabContent
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(24)
                }
            }
        } footer: {
            footer
        }
        .onAppear {
            account.usageTab = initialTab
            if loadsOnAppear { account.refreshUsage() }
        }
    }

    private func close() { account.store?.sheet = nil }

    @ViewBuilder private var tabContent: some View {
        switch account.usageTab {
        case .context: contextTab
        case .usage: usageTotalsTab
        case .session: sessionTab
        }
    }

    @ViewBuilder private var contextTab: some View {
        switch account.usage.context {
        case .idle, .loading: UsageStatusLine(text: "Loading context usage…", loading: true)
        case .unavailable(let reason):
            UsageEmptyState(symbol: "gauge.with.dots.needle.0percent", title: reason,
                            detail: "Select a task to see how much of the model's context window it uses.")
        case .failed(let error): UsageStatusLine(text: "Couldn't load context usage: \(error)", isError: true)
        case .loaded(let snapshot): UsageContextBreakdown(snapshot: snapshot, model: account.usage.contextModel)
        }
    }

    @ViewBuilder private var usageTotalsTab: some View {
        switch account.usage.sessionUsage {
        case .unavailable(let reason):
            UsageEmptyState(symbol: "chart.bar", title: reason, detail: "Select a task to see the tokens and cost it has used.")
        default:
            sessionTotals
        }
    }

    private var sessionTotals: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Session usage").font(.system(size: 15, weight: .semibold))
            Text("Since the session started or was last resumed.").font(.system(size: 12)).foregroundStyle(Theme.muted)
            switch account.usage.sessionUsage {
            case .idle, .loading: UsageStatusLine(text: "Loading session usage…", loading: true)
            case .failed(let error): UsageStatusLine(text: "Couldn't load session usage: \(error)", isError: true)
            case .unavailable(let reason): UsageStatusLine(text: reason)
            case .loaded(let summary): UsageSessionTotals(summary: summary)
            }
        }
        .usageCard()
    }

    @ViewBuilder private var sessionTab: some View {
        switch account.usage.sessionInfo {
        case .idle, .loading: UsageStatusLine(text: "Loading session info…", loading: true)
        case .unavailable(let reason):
            UsageEmptyState(symbol: "info.circle", title: reason, detail: "Select a task to see its session, model, and working directory.")
        case .failed(let error): UsageStatusLine(text: "Couldn't load session info: \(error)", isError: true)
        case .loaded(let rows):
            VStack(alignment: .leading, spacing: 10) {
                Text("Click a value to copy it.").font(.system(size: 12)).foregroundStyle(Theme.muted)
                VStack(spacing: 2) { ForEach(rows) { UsageCopyRow(row: $0) } }
                    .padding(6).usageCard(padding: 0)
            }
        }
    }

    @ViewBuilder private var footer: some View {
        switch account.usageTab {
        case .session:
            let rows = account.usage.sessionInfo.value ?? []
            Button("Copy all") { UsagePasteboard.copy(UsageFormatting.copyText(rows)) }.disabled(rows.isEmpty)
            Button("Copy session ID") {
                if let id = rows.first(where: { $0.label == "Session ID" })?.value { UsagePasteboard.copy(id) }
            }.disabled(rows.isEmpty)
        default:
            EmptyView()
        }
        Spacer(minLength: 0)
        Button("Refresh") { account.refreshUsage() }
        Button("Done", action: close).keyboardShortcut(.defaultAction)
    }
}

enum UsagePasteboard {
    @MainActor static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

extension View {
    /// The quiet rounded card used across the usage and feedback panels.
    func usageCard(padding: CGFloat = 18) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.canvas.opacity(0.8), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line.opacity(0.3), lineWidth: 0.5))
    }
}

enum UsagePalette {
    static let system = Theme.adaptive(0x9A9AA2, 0x8E8E96)
    static let messages = Theme.accent
    static let overhead = Theme.adaptive(0x7A62C9, 0xB3A3EE)
    static let free = Theme.adaptive(0xE3E3E8, 0x3A3A3E)
    static let counted = Theme.adaptive(0x2F8480, 0x7DCBC5)
    static let warning = Theme.adaptive(0xB25E09, 0xF0A64B)
    static let error = Theme.adaptive(0xB3261E, 0xF2877F)
}

struct UsageStatusLine: View {
    let text: String
    var loading = false
    var isError = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if loading { ProgressView().controlSize(.small) }
            else if isError { Image(systemName: "exclamationmark.circle").foregroundStyle(UsagePalette.error) }
            Text(text).font(.system(size: 13)).foregroundStyle(isError ? Theme.ink : Theme.muted)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }
}

struct UsageEmptyState: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 28, weight: .light)).foregroundStyle(Theme.muted).accessibilityHidden(true)
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(detail).font(.system(size: 13)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 60).padding(.horizontal, 40)
    }
}

/// The Context tab: the window as a stacked bar with a legend, then what is already inside it.
struct UsageContextBreakdown: View {
    let snapshot: UsageContextSnapshot
    let model: String

    private struct Segment: Identifiable {
        var id: String { label }
        let label: String
        let tokens: UInt64
        let color: Color
        var hollow = false
        var detail: String?
    }

    private var segments: [Segment] {
        let window = snapshot.window
        var list = [Segment(label: "System prompt", tokens: window.system, color: UsagePalette.system),
                    Segment(label: "Messages", tokens: window.messages, color: UsagePalette.messages)]
        if window.overhead > 0 { list.append(Segment(label: "Reasoning/overhead", tokens: window.overhead, color: UsagePalette.overhead)) }
        list.append(Segment(label: "Free", tokens: window.free, color: UsagePalette.free, hollow: true))
        return list
    }

    private var counted: [Segment] {
        [Segment(label: "Tool definitions", tokens: snapshot.toolDefinitionsTokens, color: UsagePalette.counted,
                 detail: UsageFormatting.countDetail(snapshot.toolDefinitionsCount, "tool"))]
            + snapshot.categories.map { Segment(label: $0.label, tokens: $0.tokens, color: UsagePalette.counted, detail: $0.detail) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Context").font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Text(model).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.muted)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
                Text(snapshot.summary).font(.system(size: 18, weight: .semibold)).monospacedDigit()
                    .accessibilityLabel("Context used: \(snapshot.summary)")
                bar
                legend(segments)
                Divider().padding(.vertical, 2)
                VStack(alignment: .leading, spacing: 6) {
                    if let line = snapshot.autoCompact {
                        Label(line.text, systemImage: line.warning ? "exclamationmark.triangle" : "arrow.down.right.and.arrow.up.left")
                            .foregroundStyle(line.warning ? UsagePalette.warning : Theme.muted)
                    }
                    Text(snapshot.stats).foregroundStyle(Theme.muted)
                    if snapshot.showsCompactTip {
                        Label("Tip: run /compact to free up context space.", systemImage: "lightbulb")
                            .foregroundStyle(UsagePalette.warning)
                    }
                }
                .font(.system(size: 12.5))
            }
            .usageCard()

            VStack(alignment: .leading, spacing: 10) {
                Text("Already counted above").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.muted)
                legend(counted)
            }
            .usageCard()
        }
    }

    private var bar: some View {
        GeometryReader { proxy in
            let visible = segments.filter { $0.tokens > 0 }
            let total = max(Double(snapshot.total), 1)
            let gaps = CGFloat(max(visible.count - 1, 0)) * 2
            HStack(spacing: 2) {
                ForEach(visible) { segment in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(segment.color)
                        .frame(width: max(3, (proxy.size.width - gaps) * CGFloat(Double(segment.tokens) / total)))
                }
            }
            .frame(width: proxy.size.width, alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .frame(height: 14)
        .accessibilityHidden(true)
    }

    private func legend(_ rows: [Segment]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 7) {
            ForEach(rows) { row in
                GridRow {
                    HStack(spacing: 9) {
                        Group {
                            if row.hollow { RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.muted.opacity(0.7), lineWidth: 1) }
                            else { RoundedRectangle(cornerRadius: 3).fill(row.color) }
                        }
                        .frame(width: 11, height: 11)
                        Text(row.label).font(.system(size: 13))
                    }
                    Text("\(UsageFormatting.tokens(row.tokens)) tokens").font(.system(size: 13)).monospacedDigit()
                        .gridColumnAlignment(.trailing)
                    Text(UsageFormatting.percentOfWindow(row.tokens, snapshot.total)).font(.system(size: 13)).monospacedDigit()
                        .foregroundStyle(Theme.muted).gridColumnAlignment(.trailing)
                    Text(row.detail ?? "").font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

struct UsageSessionTotals: View {
    let summary: UsageSessionSummary

    var body: some View {
        if let empty = summary.emptyMessage {
            Text(empty).font(.system(size: 13)).foregroundStyle(Theme.muted)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                    ForEach(summary.rows) { row in
                        GridRow {
                            Text(row.label).foregroundStyle(Theme.muted)
                            Text(row.value).monospacedDigit().textSelection(.enabled)
                        }
                    }
                }
                .font(.system(size: 13))
                if !summary.models.isEmpty {
                    Text("By model").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.muted).padding(.top, 2)
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                        ForEach(summary.models) { row in
                            GridRow {
                                Text(row.label).font(.system(size: 12, design: .monospaced))
                                Text(row.value).font(.system(size: 12)).monospacedDigit().foregroundStyle(Theme.muted)
                            }
                        }
                    }
                }
                if summary.incomplete {
                    Label("Usage is incomplete and may under-count.", systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12)).foregroundStyle(UsagePalette.warning)
                }
            }
            .contextMenu { Button("Copy Session Usage") { UsagePasteboard.copy(summary.text) } }
        }
    }
}

/// A Session-info row; clicking copies the value, as in the terminal.
struct UsageCopyRow: View {
    let row: UsageSessionInfoRow
    @State private var hovered = false
    @State private var copied = false

    var body: some View {
        Button {
            UsagePasteboard.copy(row.value)
            copied = true
            Task { try? await Task.sleep(nanoseconds: 1_200_000_000); copied = false }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text(row.label).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.muted)
                    .frame(width: 128, alignment: .leading)
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.value)
                        .font(row.monospaced ? .system(size: 12.5, design: .monospaced) : .system(size: 13))
                        .lineLimit(2).truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let note = row.note { Text(note).font(.system(size: 11.5)).foregroundStyle(Theme.muted) }
                }
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(copied ? Theme.green : Theme.muted)
                    .opacity(hovered || copied ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(hovered ? Theme.hover.opacity(0.6) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help("Copy \(row.label.lowercased())")
        .accessibilityLabel("\(row.label): \(row.value)")
        .accessibilityHint("Copies the value")
    }
}
