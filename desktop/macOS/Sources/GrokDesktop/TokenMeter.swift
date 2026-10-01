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

enum TokenRate: Equatable {
    /// The harness's figure for the last completed response.
    case measured(Double)
    /// From the text streamed so far.
    case estimated(Double)

    var tokensPerSecond: Double {
        switch self {
        case .measured(let rate), .estimated(let rate): return rate
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

/// A task's token counts: what the harness has counted, plus an estimate for the response still
/// streaming. The harness reports exact figures once per model response; between those reports
/// the meter estimates from the text that has arrived, and the next report replaces the estimate.
struct TokenMeter: Equatable {
    /// The same bytes-per-token heuristic the harness and terminal use.
    static let bytesPerToken = 4
    /// A stream has to run this long before its rate is shown; a rate over a few chunks swings wildly.
    static let minimumRateWindow: TimeInterval = 1

    private(set) var session: TokenCounts?
    private(set) var lastRate: Double?
    private var live: LiveResponse?

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

    /// One model response finished. `sessionUsage` is the harness's own total; a harness that
    /// sends none has its per-response `usage` summed instead.
    mutating func completeResponse(usage: TokenCounts?, sessionUsage: TokenCounts?, tokensPerSecond: Double?) {
        live = nil
        if let sessionUsage {
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
        guard session != nil || live != nil else { return nil }
        let session = session ?? TokenCounts()
        return TokenReadout(
            inputTokens: session.promptTokens,
            outputTokens: session.output + (live?.estimatedTokens ?? 0),
            cachedTokens: session.cacheRead,
            cacheHitRate: session.cacheHitRate,
            rate: live?.rate.map(TokenRate.estimated) ?? lastRate.map(TokenRate.measured))
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
        case .measured(let value): return "\(Self.rate(value)) tok/s"
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
}

/// Each task's token meter, fed from the harness's notifications. Its own object, so a reply
/// streaming redraws the footer's figures and nothing else.
@MainActor
final class TokenMeterModel: ObservableObject {
    weak var store: AppStore?
    /// What the footer shows. While a reply streams it trails `current` by at most `publishInterval`.
    @Published private(set) var meters: [UUID: TokenMeter] = [:]
    /// Every chunk lands here; chunks can arrive hundreds of times a second.
    private var current: [UUID: TokenMeter] = [:]
    private var publish: Task<Void, Never>?
    var clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    static let publishInterval: UInt64 = 250_000_000

    init(store: AppStore) { self.store = store }

    /// Watches a task's notifications without consuming any: the transcript and the other
    /// feature models still need them.
    func observe(params: [String: Any], update: [String: Any]?, conversationID id: UUID) {
        guard let update, let kind = update["sessionUpdate"] as? String else { return }
        let meta = params["_meta"] as? [String: Any]
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
            current[id, default: TokenMeter()].completeResponse(
                usage: (update["usage"] as? [String: Any]).map(TokenCounts.init),
                sessionUsage: (update["session_usage"] as? [String: Any]).map(TokenCounts.init),
                tokensPerSecond: update["tokens_per_sec"] as? Double)
            publishNow()
        case "turn_completed":
            guard current[id] != nil else { return }
            current[id]?.endStream()
            publishNow()
        default: break
        }
    }

    /// A new harness process counts from zero, so the figures of the one before it no longer hold.
    func harnessDidStart(conversationID id: UUID) {
        guard current.removeValue(forKey: id) != nil else { return }
        publishNow()
    }

    private func noteStream(bytes: Int, promptID: String?, id: UUID) {
        current[id, default: TokenMeter()].noteStream(bytes: bytes, promptID: promptID, at: clock())
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
