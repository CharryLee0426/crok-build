import AppKit
import SwiftUI

/// Side chats: `/btw` questions about a task, answered from its conversation without
/// interrupting the turn that is running. Each task keeps its own thread.
@MainActor
final class SideChatModel: ObservableObject {
    weak var store: AppStore?
    @Published private(set) var threads: [UUID: [SideChatMessage]] = [:]
    @Published private(set) var pending: Set<UUID> = []
    /// What was typed in each task's side chat, kept while another task's shows. Not published:
    /// the field holds the text while it is typed (see `SideChatPaneView.keepDraft`).
    var drafts: [UUID: String] = [:]
    /// Bumped to move keyboard focus to the side chat's field.
    @Published private(set) var focusRequest = 0

    /// The harness answers each side question on its own, so recent exchanges travel with a
    /// follow-up; this bounds how much of them.
    static let contextCharacters = 6_000
    static let contextExchanges = 4

    init(store: AppStore) { self.store = store }

    func thread(_ id: UUID) -> [SideChatMessage] { threads[id] ?? store?.task(id)?.sideChat ?? [] }

    func requestFocus() { focusRequest += 1 }

    /// Asks a side question about a task. Returns false when it was not asked: it was empty, or
    /// the task's last question is still being answered.
    @discardableResult
    func ask(_ text: String, in id: UUID) -> Bool {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let store, !question.isEmpty, store.task(id) != nil, !pending.contains(id) else { return false }
        let prompt = Self.prompt(question, after: thread(id))
        append(SideChatMessage(role: .question, text: question), to: id)
        drafts[id] = nil
        pending.insert(id)
        Task { [weak self, weak store] in
            guard let store else { return }
            do {
                let (client, session) = try await store.session(for: id)
                let result = try ExtensionResponse.unwrap(try await client.request("_x.ai/btw", params: ["sessionId": session, "question": prompt], timeout: nil))
                guard let answer = result["answer"] as? String, !answer.isEmpty else {
                    throw DesktopError.message("The harness did not return an answer to the side question.")
                }
                self?.append(SideChatMessage(role: .answer, text: answer), to: id)
            } catch {
                self?.append(SideChatMessage(role: .failure, text: error.localizedDescription), to: id)
            }
            self?.pending.remove(id)
        }
        return true
    }

    /// Asks the question a failure answered again.
    func retry(_ failure: SideChatMessage, in id: UUID) {
        var messages = thread(id)
        guard let index = messages.firstIndex(of: failure), index > 0, messages[index - 1].role == .question else { return }
        let question = messages[index - 1].text
        messages.removeSubrange((index - 1)...index)
        save(messages, to: id)
        ask(question, in: id)
    }

    func clear(_ id: UUID) {
        guard !pending.contains(id) else { return }
        save([], to: id)
    }

    private func append(_ message: SideChatMessage, to id: UUID) {
        save(thread(id) + [message], to: id)
    }

    private func save(_ messages: [SideChatMessage], to id: UUID) {
        threads[id] = messages
        store?.setSideChat(messages, for: id)
    }

    /// The question as sent: earlier answered exchanges first, so a follow-up can refer to them.
    static func prompt(_ question: String, after history: [SideChatMessage]) -> String {
        var exchanges: [String] = []
        var budget = contextCharacters
        var index = history.count - 1
        while index > 0, exchanges.count < contextExchanges {
            let answer = history[index], asked = history[index - 1]
            index -= 1
            guard answer.role == .answer, asked.role == .question else { continue }
            let exchange = "Q: \(asked.text)\nA: \(answer.text)"
            guard exchange.count <= budget else { break }
            budget -= exchange.count
            exchanges.insert(exchange, at: 0)
            index -= 1
        }
        guard !exchanges.isEmpty else { return question }
        return "Earlier side questions in this chat, for context:\n\n" + exchanges.joined(separator: "\n\n") + "\n\nNew side question: " + question
    }
}

extension AppStore {
    func setSideChat(_ messages: [SideChatMessage], for id: UUID) {
        guard let index = state.conversations.firstIndex(where: { $0.id == id }) else { return }
        state.conversations[index].sideChat = messages.isEmpty ? nil : messages
        save()
    }
}

// MARK: - View

/// The Side chat tab: the selected task's side chat, or what side chats are for without one.
struct SideChatView: View {
    @EnvironmentObject var sideChat: SideChatModel
    /// The selected task. Given rather than read from the store, so that the tab is not evaluated
    /// again for every chunk a running task streams.
    let conversationID: UUID?
    let taskTitle: String

    var body: some View {
        if let id = conversationID {
            SideChatPane(model: sideChat, conversationID: id, taskTitle: taskTitle, messages: sideChat.thread(id),
                         isPending: sideChat.pending.contains(id), focusRequest: sideChat.focusRequest)
        } else {
            SidePanelEmptyState(symbol: "bubble.left.and.text.bubble.right", title: "No task selected",
                                detail: "Side chats belong to a task. Open one to ask Crok a quick question without interrupting its work.")
        }
    }
}

/// The AppKit side chat in SwiftUI (see `SideChatPaneView`). It takes the room it is given, so
/// SwiftUI neither measures its messages nor lays out what is typed.
private struct SideChatPane: NSViewRepresentable {
    let model: SideChatModel
    let conversationID: UUID
    let taskTitle: String
    let messages: [SideChatMessage]
    let isPending: Bool
    let focusRequest: Int

    func makeNSView(context: Context) -> SideChatPaneView { SideChatPaneView(model: model) }

    func updateNSView(_ view: SideChatPaneView, context: Context) {
        view.show(conversationID: conversationID, title: taskTitle, messages: messages, isPending: isPending, focusRequest: focusRequest)
    }

    static func dismantleNSView(_ view: SideChatPaneView, coordinator: ()) { view.keepDraft() }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SideChatPaneView, context: Context) -> CGSize? {
        let size = proposal.replacingUnspecifiedDimensions(by: CGSize(width: 320, height: 240))
        return CGSize(width: size.width.isFinite ? size.width : 320, height: size.height.isFinite ? size.height : 240)
    }
}
