import Foundation

// A session's model and thinking level, picked where the person writes (mobile/DESIGN.md "Model and thinking level"):
// the computer's list, its provider sections and search, and what the two pills above the composer say.

/// A computer's models as the pickers see them: `devices:models`, or `sessions:get`'s short copy when that query fails
/// (an older relay without it).
enum ModelList: Equatable, Sendable {
    /// Nothing has answered yet.
    case loading
    /// The computer offers no choice: it is offline, or its crok publishes no list (an older version).
    case unavailable
    case models([ModelChoice])

    var models: [ModelChoice]? {
        if case .models(let list) = self { return list }
        return nil
    }

    /// - Parameters:
    ///   - listed: `devices:models`' latest answer: nil before one, `.some(nil)` for null.
    ///   - listFailed: that query failed without ever answering (an older relay).
    ///   - fallback: `sessions:get`'s `models` (null for lists over 200).
    ///   - fallbackLoaded: `sessions:get` has answered (a new session has none: pass true with no fallback).
    static func resolve(listed: [ModelChoice]??, listFailed: Bool, fallback: [ModelChoice]?, fallbackLoaded: Bool) -> ModelList {
        if let listed {
            guard let list = listed, !list.isEmpty else { return .unavailable }
            return .models(list)
        }
        guard listFailed else { return .loading }
        if let fallback, !fallback.isEmpty { return .models(fallback) }
        return fallbackLoaded ? .unavailable : .loading
    }
}

/// One provider's models in Choose a Model.
struct ModelSection: Identifiable, Equatable, Sendable {
    /// The provider (the ids' first segment: `anthropic`, `openrouter`…), or "" for ids without one.
    var id: String
    /// The provider, or the computer's name for its models without a provider.
    var title: String
    var models: [ModelChoice]
}

/// Choose a Model's sections and search.
enum ModelCatalog {
    /// The id up to its first `/`; nil for an id without one.
    static func provider(of id: String) -> String? {
        guard let slash = id.firstIndex(of: "/"), slash != id.startIndex else { return nil }
        return String(id[..<slash])
    }

    /// Search: a case-insensitive substring of the name, the id (which carries the provider) or the description.
    static func matches(_ model: ModelChoice, query: String) -> Bool {
        let wanted = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return true }
        return model.name.localizedCaseInsensitiveContains(wanted) || model.id.localizedCaseInsensitiveContains(wanted)
            || (model.description?.localizedCaseInsensitiveContains(wanted) ?? false)
    }

    /// The list by provider, providers in the order they first appear (the computer's picker order), each keeping its
    /// models' order; sections without a match leave. A repeated id shows once.
    static func sections(_ models: [ModelChoice], computerName: String, query: String = "") -> [ModelSection] {
        var order: [String] = []
        var byProvider: [String: [ModelChoice]] = [:]
        var seen: Set<String> = []
        for model in models where seen.insert(model.id).inserted {
            let key = provider(of: model.id) ?? ""
            if byProvider[key] == nil {
                order.append(key)
                byProvider[key] = []
            }
            if matches(model, query: query) { byProvider[key]?.append(model) }
        }
        return order.compactMap { key in
            guard let found = byProvider[key], !found.isEmpty else { return nil }
            return ModelSection(id: key, title: key.isEmpty ? computerName : key, models: found)
        }
    }
}

/// Words for levels and models.
enum ModelLabels {
    /// "Default": nothing picked, the computer's own choice.
    static var defaultChoice: String { String(localized: "Default") }

    /// A canonical thinking level's name, for a level the model's list does not name.
    static func levelName(_ raw: String) -> String {
        switch raw {
        case "none": String(localized: "None")
        case "minimal": String(localized: "Minimal")
        case "low": String(localized: "Low")
        case "medium": String(localized: "Medium")
        case "high": String(localized: "High")
        case "xhigh": String(localized: "Extra high")
        case "max": String(localized: "Max")
        default: raw
        }
    }

    /// A model's name from the list, else its id.
    static func modelName(_ id: String?, in models: [ModelChoice]?) -> String? {
        guard let id, !id.isEmpty else { return nil }
        return models?.first(where: { $0.id == id })?.name ?? id
    }

    /// The name of the level a session runs at (its `effort` is the level), from the model's list when it names it.
    static func levelName(_ effort: String?, model: ModelChoice?) -> String? {
        guard let effort, !effort.isEmpty else { return nil }
        return model?.effort(matching: effort)?.name ?? levelName(effort)
    }
}

/// A change sent with `commands:setConfig` (a model id, or a thinking level's option id): on its way until the command
/// is done, then shown until the session reports it.
struct ConfigChange: Equatable, Sendable {
    var value: String
    var done = false

    var isPending: Bool { !done }
}

/// One pill of the setup row.
struct SetupPill: Equatable, Sendable {
    var label: String
    /// Nothing picked yet (a new session), or nothing known: the computer's own choice.
    var isDefault = false
    /// The computer publishes no list (an older crok there): dimmed, and a tap explains.
    var dimmed = false
    /// A change is on its way: a spinner in place of the chevron, and taps are ignored.
    var busy = false
    /// Taps are ignored without a spinner (the model is changing, so its levels may too).
    var enabled = true
}

/// The setup row above the composer's input row: the model pill and, for a model with thinking levels, the thinking
/// pill; nil when the row is hidden.
struct ModelSetupRow: Equatable, Sendable {
    var model: SetupPill
    var thinking: SetupPill?
    /// The model shown, by id; nil for Default.
    var modelId: String?
    /// The model whose levels the thinking menu offers (the one shown).
    var levelModel: ModelChoice?
    /// The level shown, by option id; nil for Default or a level the list does not have.
    var levelId: String?

    var acceptsModelTaps: Bool { !model.busy && model.enabled }
    var acceptsLevelTaps: Bool { thinking.map { !$0.busy && $0.enabled } ?? false }
}

enum ModelSetup {
    /// An open session's row: hidden while its computer is offline (the composer says so) and while it is starting (it
    /// already carries its choice). Without a list from an online computer (an older crok there) the model pill shows
    /// the session's model, dimmed; without that too, no row.
    static func session(
        list: ModelList, model: String?, effort: String?, modelChange: ConfigChange? = nil,
        effortChange: ConfigChange? = nil, computerOnline: Bool, starting: Bool
    ) -> ModelSetupRow? {
        guard computerOnline, !starting else { return nil }
        let model = model?.nilIfEmpty
        switch list {
        case .loading:
            return nil
        case .unavailable:
            guard let model else { return nil }
            return ModelSetupRow(model: SetupPill(label: model, dimmed: true), modelId: model)
        case .models(let models):
            let shownId = modelChange?.value ?? model
            let shown = shownId.flatMap { id in models.first(where: { $0.id == id }) }
            let modelPill = SetupPill(
                label: shown?.name ?? shownId ?? ModelLabels.defaultChoice, isDefault: shownId == nil,
                busy: modelChange?.isPending ?? false)
            var row = ModelSetupRow(model: modelPill, modelId: shownId)
            guard let shown, !shown.efforts.isEmpty else { return row }
            let level: EffortChoice?
            if let effortChange {
                level = shown.efforts.first(where: { $0.id == effortChange.value })
            } else if let matched = shown.effort(matching: effort) {
                level = matched
            } else if modelChange != nil {
                // A new model the session's level does not exist on: the computer takes the model's default.
                level = shown.efforts.first(where: { $0.id == shown.defaultEffort })
            } else {
                level = nil
            }
            let label = level?.name ?? effort?.nilIfEmpty.map { ModelLabels.levelName($0) } ?? ModelLabels.defaultChoice
            row.thinking = SetupPill(
                label: label, isDefault: level == nil && effort?.nilIfEmpty == nil,
                busy: effortChange?.isPending ?? false, enabled: !(modelChange?.isPending ?? false))
            row.levelModel = shown
            row.levelId = level?.id
            return row
        }
    }

    /// A new session's row: "Default" until a model is picked; the thinking pill once a model with levels is, saying
    /// "Default" until a level is. Hidden while the computer is offline or offers no list.
    static func newSession(list: ModelList, model: String?, effort: String?, computerOnline: Bool) -> ModelSetupRow? {
        guard computerOnline, case .models(let models) = list else { return nil }
        guard let picked = model.flatMap({ id in models.first(where: { $0.id == id }) }) else {
            return ModelSetupRow(model: SetupPill(label: ModelLabels.defaultChoice, isDefault: true))
        }
        var row = ModelSetupRow(model: SetupPill(label: picked.name), modelId: picked.id)
        guard !picked.efforts.isEmpty else { return row }
        let level = effort.flatMap { id in picked.efforts.first(where: { $0.id == id }) }
        row.thinking = SetupPill(label: level?.name ?? ModelLabels.defaultChoice, isDefault: level == nil)
        row.levelModel = picked
        row.levelId = level?.id
        return row
    }

    /// What `sessions:create` gets for a new session's picks: the model's id and the level's option id, while the
    /// computer still offers them; nil for Default.
    static func createArguments(list: ModelList, model: String?, effort: String?) -> (model: String?, effort: String?) {
        guard let picked = model.flatMap({ id in list.models?.first(where: { $0.id == id }) }) else { return (nil, nil) }
        let level = effort.flatMap { id in picked.efforts.first(where: { $0.id == id }) }
        return (picked.id, level?.id)
    }
}

/// "Couldn't change the model" with the computer's or the relay's reason.
struct ConfigFailure: Equatable, Sendable, Identifiable {
    var option: ConfigOption
    var message: String
    let id = UUID()

    var title: String {
        switch option {
        case .model: String(localized: "Couldn't change the model")
        case .reasoningEffort: String(localized: "Couldn't change the thinking level")
        }
    }
}
