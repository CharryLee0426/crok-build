import SwiftUI

/// Token counts for one model response or a whole session, in the harness's buckets
/// (`ResponseUsage`): `input` is the uncached part of the prompt, so the three prompt buckets add up.
struct TokenCounts: Equatable {
    var input = 0
    var output = 0
    var cacheRead = 0
    var cacheCreation = 0

    init(input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheCreation: Int = 0) {
        self.input = input; self.output = output; self.cacheRead = cacheRead; self.cacheCreation = cacheCreation
    }

    init(_ value: [String: Any]) {
        input = value["input_tokens"] as? Int ?? 0
        output = value["output_tokens"] as? Int ?? 0
        cacheRead = value["cache_read_input_tokens"] as? Int ?? 0
        cacheCreation = value["cache_creation_input_tokens"] as? Int ?? 0
    }

    /// Every prompt token sent, cached or not.
    var promptTokens: Int { input + cacheRead + cacheCreation }
    /// The share of the prompt served from the provider's cache; nil before any prompt is counted.
    var cacheHitRate: Double? { promptTokens > 0 ? Double(cacheRead) / Double(promptTokens) : nil }

    static func += (total: inout TokenCounts, call: TokenCounts) {
        total.input += call.input; total.output += call.output
        total.cacheRead += call.cacheRead; total.cacheCreation += call.cacheCreation
    }
}

/// A task's footer figures, saved with the task so it shows them at once when opened again,
/// after a restart too.
struct SavedTokenUsage: Codable, Equatable, Sendable {
    var input = 0
    var output = 0
    var cacheRead = 0
    var cacheCreation = 0
    /// The last response's measured speed.
    var tokensPerSecond: Double?
    /// The session's average speed, when only the harness's record was there to read.
    var averageTokensPerSecond: Double?

    init(_ counts: TokenCounts, tokensPerSecond: Double? = nil, averageTokensPerSecond: Double? = nil) {
        input = counts.input; output = counts.output; cacheRead = counts.cacheRead; cacheCreation = counts.cacheCreation
        self.tokensPerSecond = tokensPerSecond
        self.averageTokensPerSecond = averageTokensPerSecond
    }

    var counts: TokenCounts { TokenCounts(input: input, output: output, cacheRead: cacheRead, cacheCreation: cacheCreation) }

    /// The harness's own record of a session (`usage.json`), which adds up every turn whichever
    /// client ran it. Its `inputTokens` is the whole prompt, cached parts included.
    init?(harnessUsageFile data: Data) {
        guard let file = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let session = file["session"] as? [String: Any] else { return nil }
        let number = { (key: String) in max(0, (session[key] as? NSNumber)?.intValue ?? 0) }
        let prompt = number("inputTokens"), cacheRead = number("cachedReadTokens"), cacheCreation = number("cacheCreationTokens")
        guard number("modelCalls") > 0 || prompt > 0 || number("outputTokens") > 0 else { return nil }
        self.init(TokenCounts(input: max(0, prompt - cacheRead - cacheCreation), output: number("outputTokens"),
                              cacheRead: cacheRead, cacheCreation: cacheCreation))
        let decodeMilliseconds = number("decodeDurationMs"), decodedTokens = number("decodeOutputTokens")
        if decodeMilliseconds > 0, decodedTokens > 0 {
            averageTokensPerSecond = Double(decodedTokens) * 1000 / Double(decodeMilliseconds)
        }
    }

    /// Reads a session's `usage.json`; nil when the harness has not written one.
    static func harnessRecord(cwd: String, sessionID: String, home: URL = GrokPaths.home) -> SavedTokenUsage? {
        guard let directory = GrokPaths.sessionDirectory(cwd: cwd, sessionID: sessionID, home: home),
              let data = try? Data(contentsOf: directory.appendingPathComponent("usage.json")) else { return nil }
        return SavedTokenUsage(harnessUsageFile: data)
    }
}

/// A request that could not read all of what the request before it left in the provider's prompt
/// cache: the `cache_miss` of a `response_started` update, from Anthropic's cache diagnostics.
struct PromptCacheMiss: Equatable {
    enum Change: String { case model, system, tools, messages }

    var changed: Change
    /// About how many input tokens came after the change. An estimate, not a billed amount.
    var missedInputTokens: Int

    init?(_ value: Any?) {
        guard let value = value as? [String: Any], let changed = (value["changed"] as? String).flatMap(Change.init) else { return nil }
        self.changed = changed
        missedInputTokens = value["missed_input_tokens"] as? Int ?? 0
    }

    /// The line the transcript shows, in the interface language.
    var text: String {
        let change: String
        switch changed {
        case .model: change = L10n.t("cache_miss_model", "Prompt cache: the model changed since the previous request.")
        case .system: change = L10n.t("cache_miss_system", "Prompt cache: the system prompt changed since the previous request.")
        case .tools: change = L10n.t("cache_miss_tools", "Prompt cache: the tool list changed since the previous request.")
        case .messages: change = L10n.t("cache_miss_messages", "Prompt cache: earlier messages changed since the previous request.")
        }
        guard missedInputTokens > 0 else { return change }
        return L10n.t("cache_miss_tokens", "{change} About {tokens} input tokens after the change were not read from the cache.",
                      ["change": change, "tokens": missedInputTokens.formatted()])
    }
}

enum TokenRate: Equatable {
    /// The harness's figure for the last completed response.
    case measured(Double)
    /// From the text streamed so far.
    case estimated(Double)
    /// The session's average, from the harness's record, for a task with no response measured here.
    case average(Double)

    var tokensPerSecond: Double {
        switch self {
        case .measured(let rate), .estimated(let rate), .average(let rate): return rate
        }
    }
}

/// What the composer footer draws.
struct TokenReadout: Equatable {
    var inputTokens: Int
    /// Includes the estimate for a response in flight.
    var outputTokens: Int
    var cachedTokens: Int
    var cacheHitRate: Double?
    var rate: TokenRate?
}

/// How full a task's context window is: the tokens its next request carries, and the window's size.
struct ContextUsage: Equatable {
    var used: Int
    /// Nil while the window's size is unknown.
    var window: Int?

    /// The share of the window in use; past 1 when the context has outgrown it.
    var fraction: Double? { window.map { Double(used) / Double(max(1, $0)) } }
}

/// A task's token counts: what the harness has counted, plus an estimate for the response still
/// streaming. The harness reports exact figures once per model response; between those reports
/// the meter estimates from the text that has arrived, and the next report replaces the estimate.
struct TokenMeter: Equatable {
    /// The same bytes-per-token heuristic the harness and terminal use.
    static let bytesPerToken = 4
    /// A stream has to run this long before its rate is shown; a rate over a few chunks swings wildly.
    static let minimumRateWindow: TimeInterval = 1

    /// What was counted before the current harness process reported: the figures the task was
    /// opened with, shown until the harness's own session total replaces them.
    private(set) var carried: TokenCounts?
    /// What the current harness process has counted.
    private(set) var session: TokenCounts?
    private(set) var lastRate: Double?
    private(set) var averageRate: Double?
    private var live: LiveResponse?

    init() {}

    init(saved: SavedTokenUsage) {
        carried = saved.counts
        lastRate = saved.tokensPerSecond.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        averageRate = saved.averageTokensPerSecond.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    }

    /// Everything counted for the task, across harness processes.
    var totals: TokenCounts? {
        guard carried != nil || session != nil else { return nil }
        var total = carried ?? TokenCounts()
        if let session { total += session }
        return total
    }

    /// What is saved with the task.
    var saved: SavedTokenUsage? {
        totals.map { SavedTokenUsage($0, tokensPerSecond: lastRate, averageTokensPerSecond: lastRate == nil ? averageRate : nil) }
    }

    /// A new harness process starts. What was counted so far stays on screen until it reports.
    mutating func carryOver() {
        carried = totals
        session = nil
        live = nil
    }

    /// One response's stream, from its first chunk.
    private struct LiveResponse: Equatable {
        /// Tells a new turn's stream from one a stopped turn left behind, which no completion closed.
        var promptID: String?
        var firstChunkAt: TimeInterval
        var lastChunkAt: TimeInterval
        var bytes: Int
        /// Generated before the clock started, so left out of the rate.
        var firstChunkBytes: Int

        var estimatedTokens: Int { bytes / TokenMeter.bytesPerToken }
        var rate: Double? {
            let window = lastChunkAt - firstChunkAt
            guard window >= TokenMeter.minimumRateWindow else { return nil }
            return Double(bytes - firstChunkBytes) / Double(TokenMeter.bytesPerToken) / window
        }
    }

    /// Streamed model output: reply text, reasoning, or a tool call's arguments. A tool call's
    /// chunks carry no prompt ID, so only two IDs that differ start a new stream.
    mutating func noteStream(bytes: Int, promptID: String?, at now: TimeInterval) {
        guard bytes > 0 else { return }
        if var current = live, promptID == nil || current.promptID == nil || current.promptID == promptID {
            current.bytes += bytes
            current.lastChunkAt = now
            if current.promptID == nil { current.promptID = promptID }
            live = current
        } else {
            live = LiveResponse(promptID: promptID, firstChunkAt: now, lastChunkAt: now, bytes: bytes, firstChunkBytes: bytes)
        }
    }

    /// The turn ended. A response it cut short never completes, so its stream is dropped here.
    mutating func endStream() { live = nil }

    /// One model response finished. `sessionUsage` is the harness's own total for the session
    /// since it began, earlier processes included, so it replaces whatever was carried; a harness
    /// that sends none has its per-response `usage` summed instead.
    mutating func completeResponse(usage: TokenCounts?, sessionUsage: TokenCounts?, tokensPerSecond: Double?) {
        live = nil
        if let sessionUsage {
            carried = nil
            session = sessionUsage
        } else if let usage {
            var total = session ?? TokenCounts()
            total += usage
            session = total
        }
        if let rate = tokensPerSecond, rate.isFinite, rate > 0 { lastRate = rate }
    }

    /// Nil until something has been counted, so a new task draws no zeros. `turnRunning` is false
    /// once a turn ends; a stream it left open no longer counts.
    func readout(turnRunning: Bool) -> TokenReadout? {
        let live = turnRunning ? live : nil
        let totals = totals
        guard totals != nil || live != nil else { return nil }
        let counted = totals ?? TokenCounts()
        return TokenReadout(
            inputTokens: counted.promptTokens,
            outputTokens: counted.output + (live?.estimatedTokens ?? 0),
            cachedTokens: counted.cacheRead,
            cacheHitRate: counted.cacheHitRate,
            rate: live?.rate.map(TokenRate.estimated) ?? lastRate.map(TokenRate.measured) ?? averageRate.map(TokenRate.average))
    }
}

enum TokenFormat {
    /// `999`, `1.2K`, `45K`, `1.2M`, `12M`: four characters at most, as the terminal writes them.
    static func count(_ value: Int) -> String {
        switch value {
        case ..<1_000: return String(max(0, value))
        case ..<10_000: return String(format: "%.1fK", Double(value) / 1_000)
        case ..<1_000_000: return "\(value / 1_000)K"
        case ..<10_000_000: return String(format: "%.1fM", Double(value) / 1_000_000)
        default: return "\(value / 1_000_000)M"
        }
    }

    /// `8.4` under ten tokens a second, where the tenth is the signal; whole numbers above.
    static func rate(_ tokensPerSecond: Double) -> String {
        let rate = min(max(0, tokensPerSecond), 9_999)
        return String(format: rate < 9.95 ? "%.1f" : "%.0f", rate)
    }

    static func percent(_ fraction: Double) -> String { "\(Int((fraction * 100).rounded()))%" }

    static func rate(_ rate: TokenRate) -> String {
        switch rate {
        case .measured(let value), .average(let value): return "\(Self.rate(value)) tok/s"
        case .estimated(let value): return "~\(Self.rate(value)) tok/s"
        }
    }

    /// The hover text: the same figures in full, and what a click does.
    static func help(_ readout: TokenReadout) -> String {
        var lines = ["Input: \(readout.inputTokens.formatted()) tokens this session"]
        if let hit = readout.cacheHitRate {
            lines.append("Cache hit rate: \(percent(hit)) (\(readout.cachedTokens.formatted()) tokens read from cache)")
        }
        lines.append("Output: \(readout.outputTokens.formatted()) tokens")
        switch readout.rate {
        case .measured(let rate)?: lines.append("Speed: \(Self.rate(rate)) tokens per second in the last response")
        case .estimated(let rate)?: lines.append("Speed: about \(Self.rate(rate)) tokens per second, estimated while the reply streams")
        case .average(let rate)?: lines.append("Speed: \(Self.rate(rate)) tokens per second on average this session")
        case nil: break
        }
        lines.append("Click for session usage · /usage")
        return lines.joined(separator: "\n")
    }

    static func accessibilityLabel(_ readout: TokenReadout) -> String {
        var parts = ["\(readout.inputTokens.formatted()) input tokens", "\(readout.outputTokens.formatted()) output tokens"]
        if let hit = readout.cacheHitRate { parts.append("\(percent(hit)) cache hit rate") }
        if let rate = readout.rate { parts.append("\(Self.rate(rate.tokensPerSecond)) tokens per second") }
        return "Token usage: " + parts.joined(separator: ", ") + ". Show session usage"
    }

    /// The context ring's hover text: how full the window is, and what a click does.
    static func contextHelp(_ usage: ContextUsage?) -> String {
        var lines = ["Context window: not measured yet"]
        if let usage, let window = usage.window, let fraction = usage.fraction {
            lines = ["Context window: \(percent(fraction)) full",
                     "\(usage.used.formatted()) of \(window.formatted()) tokens used, \(max(0, window - usage.used).formatted()) free"]
        } else if let usage {
            lines = ["Context window: \(usage.used.formatted()) tokens used"]
        }
        lines.append("Click to see how it is allocated")
        return lines.joined(separator: "\n")
    }

    static func contextAccessibilityValue(_ usage: ContextUsage?) -> String {
        guard let usage else { return "Not measured yet" }
        guard let window = usage.window, let fraction = usage.fraction else { return "\(usage.used.formatted()) tokens used" }
        return "\(percent(fraction)) full, \(usage.used.formatted()) of \(window.formatted()) tokens"
    }
}

/// Each task's token meter and context window use, fed from the harness's notifications. Its own
/// object, so a reply streaming redraws the composer's figures and nothing else.
@MainActor
final class TokenMeterModel: ObservableObject {
    weak var store: AppStore?
    /// What the footer shows. While a reply streams it trails `current` by at most `publishInterval`.
    @Published private(set) var meters: [UUID: TokenMeter] = [:]
    /// Every chunk lands here; chunks can arrive hundreds of times a second.
    private var current: [UUID: TokenMeter] = [:]
    /// What the context ring shows, published as `meters` is. It outlives a harness restart: the
    /// next process loads the same conversation.
    @Published private(set) var contexts: [UUID: ContextUsage] = [:]
    private var currentContexts: [UUID: ContextUsage] = [:]
    private var publish: Task<Void, Never>?
    var clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    static let publishInterval: UInt64 = 250_000_000

    init(store: AppStore) { self.store = store }

    /// Watches a task's notifications without consuming any: the transcript and the other
    /// feature models still need them.
    func observe(params: [String: Any], update: [String: Any]?, conversationID id: UUID) {
        guard let update, let kind = update["sessionUpdate"] as? String else { return }
        let meta = params["_meta"] as? [String: Any]
        // Every `session/update` carries what the context holds. Replayed ones too: they arrive in order and end at the latest.
        if let used = meta?["totalTokens"] as? Int { noteContextUsed(used, id: id) }
        // A replayed history is not a stream, and its responses were counted by an earlier harness.
        let replayed = meta?["isReplay"] as? Bool == true || store?.replaying.contains(id) == true || store?.importing.contains(id) == true
        switch kind {
        case "agent_message_chunk", "agent_thought_chunk":
            guard !replayed, let text = (update["content"] as? [String: Any])?["text"] as? String else { return }
            noteStream(bytes: text.utf8.count, promptID: meta?["promptId"] as? String, id: id)
        case "tool_call_delta_chunk":
            guard !replayed, let delta = update["arguments_delta"] as? String else { return }
            noteStream(bytes: delta.utf8.count, promptID: meta?["promptId"] as? String, id: id)
        case "response_completed":
            guard !replayed else { return }
            if current[id] == nil, let meter = savedMeter(id) { current[id] = meter }
            current[id, default: TokenMeter()].completeResponse(
                usage: (update["usage"] as? [String: Any]).map(TokenCounts.init),
                sessionUsage: (update["session_usage"] as? [String: Any]).map(TokenCounts.init),
                tokensPerSecond: update["tokens_per_sec"] as? Double)
            publishNow()
            if let saved = current[id]?.saved { store?.saveTokenUsage(saved, for: id) }
        case "turn_completed":
            guard current[id] != nil else { return }
            current[id]?.endStream()
            publishNow()
        case "auto_compact_completed":
            // xAI notifications carry no `totalTokens`, and after `/compact` nothing else reports until the next prompt.
            guard let used = update["tokens_after"] as? Int else { return }
            noteContextUsed(used, id: id)
            publishNow()
        default: break
        }
    }

    /// A new harness process starts: the task's figures stay until it reports its session total.
    func harnessDidStart(conversationID id: UUID) {
        guard var meter = current[id] ?? savedMeter(id) else { return }
        meter.carryOver()
        current[id] = meter
        publishNow()
    }

    /// Shows a task's figures when nothing has been counted for it since the app opened.
    func restore(conversationID id: UUID) {
        guard current[id] == nil, let meter = savedMeter(id) else { return }
        current[id] = meter
        publishNow()
    }

    /// Where a task's own record is: the session's `usage.json`. Tests point it elsewhere.
    var harnessRecord: (_ cwd: String, _ sessionID: String) -> SavedTokenUsage? = { cwd, sessionID in
        SavedTokenUsage.harnessRecord(cwd: cwd, sessionID: sessionID)
    }

    /// The figures saved with the task, or the harness's record of its session when that counted
    /// more: the terminal may have gone on with it, and older tasks saved none.
    private func savedMeter(_ id: UUID) -> TokenMeter? {
        guard let store, let task = store.task(id) else { return nil }
        let saved = task.tokenUsage
        let recorded = task.sessionID.flatMap { session in
            store.projectRecord(task.projectID).flatMap { harnessRecord($0.path, session) }
        }
        guard var chosen = saved ?? recorded else { return nil }
        if let recorded, recorded.output > chosen.output {
            chosen = recorded
            chosen.tokensPerSecond = saved?.tokensPerSecond
        }
        if chosen.tokensPerSecond == nil, chosen.averageTokensPerSecond == nil { chosen.averageTokensPerSecond = recorded?.averageTokensPerSecond }
        return TokenMeter(saved: chosen)
    }

    /// What Context (`_x.ai/session/info`) measured. It also sizes the window for a model the
    /// catalog does not list.
    func noteContext(_ context: UsageContextSnapshot, conversationID id: UUID) {
        // A harness that sent no breakdown reports a zero window.
        guard context.total > 0 else { return }
        currentContexts[id] = ContextUsage(used: Int(clamping: context.used), window: Int(clamping: context.total))
        publishNow()
    }

    private func noteContextUsed(_ used: Int, id: UUID) {
        guard currentContexts[id]?.used != used else { return }
        currentContexts[id] = ContextUsage(used: used, window: currentContexts[id]?.window)
        schedulePublish()
    }

    private func noteStream(bytes: Int, promptID: String?, id: UUID) {
        current[id, default: TokenMeter()].noteStream(bytes: bytes, promptID: promptID, at: clock())
        schedulePublish()
    }

    private func schedulePublish() {
        guard publish == nil else { return }
        publish = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.publishInterval)
            guard !Task.isCancelled else { return }
            self?.publishNow()
        }
    }

    private func publishNow() {
        publish?.cancel(); publish = nil
        if meters != current { meters = current }
        if contexts != currentContexts { contexts = currentContexts }
    }
}

/// In the composer footer, right of Git Graph: the task's input and output tokens, cache hit
/// rate, and output speed. Opens Session usage. Drops figures, rate first, when the footer is narrow.
struct ComposerTokenStats: View {
    @EnvironmentObject var account: AccountFeatureModel
    let readout: TokenReadout

    var body: some View {
        Button { account.usage("") } label: {
            ViewThatFits(in: .horizontal) {
                figures(cache: true, rate: true)
                figures(cache: true, rate: false)
                figures(cache: false, rate: false)
            }
        }
        .buttonStyle(FooterChipStyle())
        .help(TokenFormat.help(readout))
        .accessibilityLabel(TokenFormat.accessibilityLabel(readout))
    }

    /// Spaced like the footer's chips, whose padding leaves 14 points between one label and the next.
    private func figures(cache: Bool, rate: Bool) -> some View {
        HStack(spacing: 14) {
            figure("arrow.up", TokenFormat.count(readout.inputTokens))
            figure("arrow.down", TokenFormat.count(readout.outputTokens))
            if cache, let hit = readout.cacheHitRate { figure("bolt", "\(TokenFormat.percent(hit)) cached") }
            if rate, let speed = readout.rate { figure("speedometer", TokenFormat.rate(speed)) }
        }
        .fixedSize()
    }

    private func figure(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
            // Digits of one width, so a count ticking up does not shift its neighbours.
            Text(text).fontWeight(.medium).monospacedDigit()
        }
    }
}

extension TokenMeterModel {
    /// What a task's context ring shows. `catalogWindow`, the selected model's window, follows a
    /// model switch before the harness reports again.
    func contextUsage(_ id: UUID, catalogWindow: Int?) -> ContextUsage? {
        guard var usage = contexts[id] else { return nil }
        if let catalogWindow { usage.window = catalogWindow }
        return usage
    }
}

/// Left of the microphone: how full the task's context window is, as a ring that fills clockwise.
/// Hover for the figures; a click opens a popover that shows how the window is allocated, and
/// measures a task that has not reported since the app opened.
struct ComposerContextRing: View {
    @EnvironmentObject var tokens: TokenMeterModel
    @EnvironmentObject var account: AccountFeatureModel
    let conversationID: UUID
    let catalogWindow: Int?
    @State private var showsDetails = false

    var body: some View {
        let usage = tokens.contextUsage(conversationID, catalogWindow: catalogWindow)
        Button {
            if !showsDetails { account.refreshContextBreakdown(conversationID: conversationID) }
            showsDetails.toggle()
        } label: {
            ring(usage?.fraction)
                .frame(width: 15, height: 15)
                .frame(width: 26, height: 30).contentShape(Capsule())
        }
        .buttonStyle(ComposerControlStyle())
        .help(TokenFormat.contextHelp(usage))
        .accessibilityLabel("Context window")
        .accessibilityValue(TokenFormat.contextAccessibilityValue(usage))
        .accessibilityHint("Shows how the context window is allocated")
        // Popovers do not reliably carry the window's environment objects, so the models are handed over.
        .popover(isPresented: $showsDetails, arrowEdge: .top) {
            ContextWindowPopover(tokens: tokens, account: account, conversationID: conversationID, catalogWindow: catalogWindow) {
                showsDetails = false
                DispatchQueue.main.async { account.openContext() }
            }
        }
        .onChange(of: conversationID) { _, _ in showsDetails = false }
    }

    /// Dashed while the share is unknown.
    @ViewBuilder private func ring(_ fraction: Double?) -> some View {
        if let fraction {
            ZStack {
                Circle().inset(by: 1).stroke(Theme.muted.opacity(0.3), lineWidth: 2)
                Circle().inset(by: 1).trim(from: 0, to: min(1, fraction))
                    .stroke(Self.tint(fraction), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        } else {
            Circle().inset(by: 1).stroke(Theme.muted.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [2, 2]))
        }
    }

    /// As the terminal's context meter: the warning colour from 75%, the error colour from 95%.
    static func tint(_ fraction: Double) -> Color {
        fraction >= 0.95 ? Theme.red : fraction >= 0.75 ? ComposerPalette.warning : Theme.ink.opacity(0.7)
    }
}
