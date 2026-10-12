import Foundation

/// A user-facing refusal from a composer command, worded as the terminal words it.
struct ComposerCommandMessage: Error, Equatable {
    let text: String
    init(_ text: String) { self.text = text }
}

/// `/model <name> [effort]` and `/effort <level>` argument resolution, following the terminal's
/// rules (P/slash/commands/model.rs, effort.rs; P/acp/model_state.rs).
enum ComposerModelArguments {
    struct Choice: Equatable {
        let modelID: String
        /// The effort menu id, when the command named one.
        let effortID: String?
    }

    /// The standard reasoning levels, strongest last.
    static let standardEfforts = ["none", "minimal", "low", "medium", "high", "xhigh", "max"]
    /// The terminal's labels for the standard levels.
    static let standardLabels = ["none": "None", "minimal": "Minimal", "low": "Low", "medium": "Medium", "high": "High", "xhigh": "X-High", "max": "Max"]

    /// Resolves `/model` arguments against the model catalog. An exact (case-insensitive) name
    /// or id wins; otherwise the longest reasoning-capable name or id that prefixes the text,
    /// followed by whitespace, takes the rest as an effort level.
    static func resolveModel(_ arguments: String, models: [ModelOption]) -> Result<Choice, ComposerCommandMessage> {
        let trimmed = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        if let model = models.first(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame || $0.id.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return .success(Choice(modelID: model.id, effortID: nil))
        }
        var best: (model: ModelOption, key: String, rest: Substring)?
        for model in models where !model.reasoningOptions.isEmpty {
            for key in [model.name, model.id] where key.count > (best?.key.count ?? 0) {
                if let rest = rest(of: trimmed, after: key) { best = (model, key, rest) }
            }
        }
        if let best {
            let token = best.rest.trimmingCharacters(in: .whitespacesAndNewlines)
            if !token.isEmpty {
                return resolveEffort(token, options: best.model.reasoningOptions).map { Choice(modelID: best.model.id, effortID: $0) }
            }
        }
        return .failure(ComposerCommandMessage("Unknown model: \(trimmed)"))
    }

    /// The text after `key` when `text` starts with it (ignoring case) and a space follows.
    private static func rest(of text: String, after key: String) -> Substring? {
        guard !key.isEmpty, text.count > key.count,
              text.prefix(key.count).caseInsensitiveCompare(key) == .orderedSame else { return nil }
        let rest = text.dropFirst(key.count)
        return rest.first?.isWhitespace == true ? rest : nil
    }

    /// Resolves an effort token against a model's menu: a menu id or label, or a standard level
    /// (by name or label) that the menu offers.
    static func resolveEffort(_ token: String, options: [ModelOption]) -> Result<String, ComposerCommandMessage> {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !options.isEmpty else { return .failure(ComposerCommandMessage("current model does not support reasoning effort")) }
        if let option = options.first(where: { $0.id.caseInsensitiveCompare(token) == .orderedSame || $0.name.caseInsensitiveCompare(token) == .orderedSame }) {
            return .success(option.id)
        }
        if let level = standardLevel(token), let option = options.first(where: { offers($0, level: level) }) {
            return .success(option.id)
        }
        return .failure(ComposerCommandMessage("unknown effort level '\(token)'; use one of: \(options.map(\.id).joined(separator: ", "))"))
    }

    /// A standard level from its name or label ("xhigh", "X-High", or the desktop's "Extra high").
    static func standardLevel(_ token: String) -> String? {
        let lowered = token.lowercased()
        if standardEfforts.contains(lowered) { return lowered }
        if let match = standardLabels.first(where: { $0.value.lowercased() == lowered }) { return match.key }
        return ["extra high": "xhigh", "extra-high": "xhigh", "x high": "xhigh"][lowered]
    }

    /// The desktop keeps only a menu entry's id and label, so a standard level matches an entry
    /// whose id is that level or whose label is one of the level's labels.
    private static func offers(_ option: ModelOption, level: String) -> Bool {
        if option.id.lowercased() == level { return true }
        return standardLevel(option.name) == level
    }

    /// "Usage: /effort <low|medium|high> (current: medium)".
    static func effortUsage(options: [ModelOption], current: String) -> String {
        let levels = options.isEmpty ? "<level>" : "<" + options.map(\.id).joined(separator: "|") + ">"
        return "Usage: /effort \(levels)" + (current.isEmpty ? "" : " (current: \(current))")
    }

    /// The effort word used in "Switched to {name} ({effort} effort)".
    static func effortWord(_ id: String, options: [ModelOption]) -> String {
        if standardEfforts.contains(id.lowercased()) { return id.lowercased() }
        let label = options.first { $0.id == id }?.name ?? id
        return standardLevel(label) ?? id
    }
}

/// The permission modes in `[ui].permission_mode`, safest first (P/settings/defs.rs).
enum ComposerPermissionMode: String, CaseIterable, Identifiable {
    case standard = "default"
    case ask
    case auto
    case alwaysApprove = "always-approve"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .standard: return L10n.t("mode_default", "Default")
        case .ask: return L10n.t("mode_ask", "Ask")
        case .auto: return L10n.t("mode_auto", "Auto")
        case .alwaysApprove: return L10n.t("mode_always_approve", "Always approve")
        }
    }
    var detail: String {
        switch self {
        case .standard: return L10n.t("mode_default_detail", "Use the agent's default (currently Ask).")
        case .ask: return L10n.t("mode_ask_detail", "Ask before tool actions.")
        case .auto: return L10n.t("mode_auto_detail", "A classifier approves safe tools; risky actions still ask.")
        case .alwaysApprove: return L10n.t("mode_always_approve_detail", "Every tool action runs without asking.")
        }
    }
    var symbol: String {
        switch self {
        case .standard, .ask: return "hand.raised"
        case .auto: return "checkmark.shield"
        case .alwaysApprove: return "exclamationmark.shield.fill"
        }
    }
    var isAlwaysApprove: Bool { self == .alwaysApprove }

    /// `[ui]` keys in the harness's precedence: `permission_mode`, then the legacy
    /// `approval_mode`, then legacy `yolo` (S/util/config/permissions.rs). Nil when none is set.
    static func configured(in config: GrokConfig) -> ComposerPermissionMode? {
        if let raw = config.string("permission_mode", in: "ui") { return ComposerPermissionMode(rawValue: raw) ?? .ask }
        if let raw = config.string("approval_mode", in: "ui") { return raw == "always-approve" ? .alwaysApprove : .ask }
        if let yolo = config.bool("yolo", in: "ui") { return yolo ? .alwaysApprove : .ask }
        return nil
    }

    /// `_x.ai/yolo_mode_changed` (snake_case, sent without `clientIdentifier` so every session follows).
    var notificationParams: [String: Any] {
        ["yolo_mode": self == .alwaysApprove, "auto_mode": self == .auto, "permission_mode": rawValue]
    }

    /// The terminal's toast after a change (P/app/dispatch/modes.rs).
    func confirmation(planMode: Bool) -> String {
        switch self {
        case .alwaysApprove:
            return planMode ? L10n.t("toast_always_approve_plan", "⚠ Always-approve ON: plan mode still blocks file edits until you exit plan mode")
                : L10n.t("toast_always_approve_on", "⚠ Always-approve ON: all tool actions auto-run")
        case .auto: return L10n.t("toast_mode_auto", "✓ Permission mode: Auto (classifier)")
        case .ask: return L10n.t("toast_mode_ask", "✓ Permission mode: Ask")
        case .standard: return L10n.t("toast_mode_default", "✓ Permission mode: Default")
        }
    }

    /// `/always-approve [on|off]`: no argument toggles; "off", "false", "0", "no", and "disable"
    /// turn it off; any other argument turns it on (S/session/slash_commands.rs).
    static func alwaysApproveTarget(_ arguments: String, current: ComposerPermissionMode) -> Bool {
        let value = arguments.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.isEmpty { return current != .alwaysApprove }
        return !["off", "false", "0", "no", "disable"].contains(value)
    }
}

/// `[ui].follow_up_behavior`: what Return does while a turn runs.
enum ComposerFollowUpBehavior: String, CaseIterable, Identifiable {
    case queue, steer
    var id: String { rawValue }
    var title: String { self == .queue ? L10n.t("followup_queue", "Queue") : L10n.t("followup_steer", "Steer") }
    var detail: String {
        self == .queue ? L10n.t("followup_queue_detail", "Send it after Crok finishes.") : L10n.t("followup_steer_detail", "Add it to the running turn.")
    }
}

/// The inline `/compact` status row.
enum ComposerCompactionStatus: Equatable {
    case running(started: Date)
    case completed(TimeInterval)
    case failed(String)
    case cancelled

    var isRunning: Bool { if case .running = self { return true }; return false }

    /// The terminal's wording (P/scrollback/blocks/session_event.rs).
    var message: String {
        switch self {
        case .running: return "Compacting conversation…"
        case .completed(let elapsed): return "Compaction completed in \(ComposerFormat.duration(elapsed))."
        case .failed(let error):
            return error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Compaction failed." : "Compaction failed - \(error)"
        case .cancelled: return "Compaction cancelled."
        }
    }
}

enum ComposerFormat {
    /// Compact durations: `5.2s`, `32s`, `2m5s`, `1h2m` (xai-grok-pager-render util.rs).
    static func duration(_ interval: TimeInterval) -> String {
        let interval = max(0, interval)
        let seconds = Int(interval)
        if seconds < 10 { return String(format: "%.1fs", interval) }
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m\(seconds % 60)s" }
        return "\(minutes / 60)h\(minutes % 60)m"
    }

    static func wordCount(_ text: String) -> Int {
        var count = 0, inWord = false
        for scalar in text.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { inWord = false }
            else if !inWord { inWord = true; count += 1 }
        }
        return count
    }
}
