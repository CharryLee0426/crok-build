import Foundation

/// The phone's answer to `/model` or `/think` in the transcript (Telegram's bot message with an inline keyboard). It
/// lives on this phone only, never on the relay. The choices themselves come live from `sessions:get` → `models`.
struct BotCard: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case model
        case think
    }

    enum State: Equatable, Sendable {
        /// The keyboard is open; `note` says why a typed choice was not applied ("No model matches …").
        case choosing(note: String?)
        /// `commands:setConfig` is on its way for this choice; its button spins.
        case applying(choiceId: String)
        /// Applied: "Model: Grok 4 ✓"; the keyboard folds away.
        case done(label: String)
        /// The relay or the computer refused; the keyboard stays for another try.
        case failed(message: String)
    }

    let id: String
    let kind: Kind
    let createdAt: Date
    var state: State

    init(id: String = UUID().uuidString, kind: Kind, createdAt: Date = Date(), state: State = .choosing(note: nil)) {
        self.id = id
        self.kind = kind
        self.createdAt = createdAt
        self.state = state
    }

    var isApplying: Bool {
        if case .applying = state { return true }
        return false
    }

    var isDone: Bool {
        if case .done = state { return true }
        return false
    }
}

/// One button of a bot card's keyboard.
struct BotChoice: Identifiable, Equatable, Sendable {
    /// What `commands:setConfig` takes.
    var id: String
    var title: String
    var detail: String?
    var isCurrent: Bool
}

/// What a bot card can offer for a session right now.
enum BotChoices: Equatable, Sendable {
    case choices([BotChoice])
    /// The computer is offline: nothing to choose from.
    case computerOffline(String)
    /// The computer is online but its crok publishes no models (an older version).
    case notOffered(String)
    /// `/think` for a model without thinking levels.
    case noThinking(model: String)

    static func make(_ kind: BotCard.Kind, detail: SessionDetail?, computerName: String, computerOnline: Bool) -> BotChoices {
        guard let models = detail?.models, !models.isEmpty else {
            return computerOnline ? .notOffered(computerName) : .computerOffline(computerName)
        }
        switch kind {
        case .model:
            return .choices(
                models.map { BotChoice(id: $0.id, title: $0.name, detail: $0.description, isCurrent: $0.id == detail?.model) })
        case .think:
            guard let model = detail?.currentModel, !model.efforts.isEmpty else {
                return .noThinking(model: detail?.currentModel?.name ?? detail?.model ?? "")
            }
            let current = model.effort(matching: detail?.effort)
            return .choices(
                model.efforts.map { BotChoice(id: $0.id, title: $0.name, detail: $0.description, isCurrent: $0.id == current?.id) })
        }
    }

    /// The label of a choice by id (for "Model: Grok 4 ✓").
    static func name(of id: String, _ kind: BotCard.Kind, in detail: SessionDetail?) -> String {
        switch kind {
        case .model:
            return detail?.models?.first(where: { $0.id == id })?.name ?? id
        case .think:
            let efforts = detail?.currentModel?.efforts ?? detail?.models?.flatMap(\.efforts) ?? []
            return efforts.first(where: { $0.id == id || $0.level == id })?.name ?? id
        }
    }
}
