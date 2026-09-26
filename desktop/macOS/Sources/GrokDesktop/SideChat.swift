import AppKit
import SwiftUI

/// Side chats: `/btw` questions about a task, answered from its conversation without
/// interrupting the turn that is running. Each task keeps its own thread.
@MainActor
final class SideChatModel: ObservableObject {
    weak var store: AppStore?
    @Published private(set) var threads: [UUID: [SideChatMessage]] = [:]
    @Published private(set) var pending: Set<UUID> = []
    @Published var drafts: [UUID: String] = [:]
    /// Bumped to move keyboard focus to the side chat's field.
    @Published private(set) var focusRequest = 0

    /// The harness answers each side question on its own, so recent exchanges travel with a
    /// follow-up; this bounds how much of them.
    static let contextCharacters = 6_000
    static let contextExchanges = 4

    init(store: AppStore) { self.store = store }

    func thread(_ id: UUID) -> [SideChatMessage] { threads[id] ?? store?.task(id)?.sideChat ?? [] }

    func requestFocus() { focusRequest += 1 }

    /// Asks a side question about a task.
    func ask(_ text: String, in id: UUID) {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let store, !question.isEmpty, store.task(id) != nil, !pending.contains(id) else { return }
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

struct SideChatView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var sideChat: SideChatModel

    var body: some View {
        if let id = store.state.selectedConversationID, let task = store.task(id) {
            SideChatThread(conversationID: id, taskTitle: task.title).id(id)
        } else {
            SidePanelEmptyState(symbol: "bubble.left.and.text.bubble.right", title: "No task selected",
                                detail: "Side chats belong to a task. Open one to ask Crok a quick question without interrupting its work.")
        }
    }
}

private struct SideChatThread: View {
    @EnvironmentObject var sideChat: SideChatModel
    let conversationID: UUID
    let taskTitle: String
    @FocusState private var focused: Bool

    private var messages: [SideChatMessage] { sideChat.thread(conversationID) }
    private var isPending: Bool { sideChat.pending.contains(conversationID) }
    private var draft: Binding<String> {
        Binding(get: { sideChat.drafts[conversationID] ?? "" }, set: { sideChat.drafts[conversationID] = $0 })
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("About \u{201C}\(taskTitle)\u{201D}").font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.muted)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                if !messages.isEmpty {
                    IconButton(icon: "trash", help: "Clear this side chat", size: 24) { sideChat.clear(conversationID) }
                        .disabled(isPending)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 6)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if messages.isEmpty { intro }
                        ForEach(messages) { message in
                            SideChatBubble(message: message) { sideChat.retry(message, in: conversationID) }
                        }
                        if isPending {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.mini)
                                Text("Crok is answering…").font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                            }.padding(.leading, 2)
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                }
                .defaultScrollAnchor(.bottom)
                .onChange(of: messages.count) { _, _ in withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("end", anchor: .bottom) } }
                .onChange(of: isPending) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
            }
            input.padding(10)
        }
        .onAppear { focused = true }
        .onChange(of: sideChat.focusRequest) { _, _ in focused = true }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "bubble.left.and.text.bubble.right").font(.system(size: 20, weight: .light)).foregroundStyle(Theme.accent)
            Text("Ask on the side").font(.system(size: 14, weight: .semibold))
            Text("Crok answers from this task's conversation without interrupting what it is doing. Nothing here changes the task.")
                .font(.system(size: 12.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 12)
    }

    private var input: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask a side question…", text: draft, axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: 13.5)).lineLimit(1...6)
                .focused($focused)
                .onSubmit(send)
                .padding(.vertical, 5)
                .accessibilityLabel("Side question")
            Button(action: send) {
                Image(systemName: "arrow.up").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.canvas)
                    .frame(width: 26, height: 26)
                    .background(canSend ? Theme.ink : Theme.muted.opacity(0.35), in: Circle())
            }
            .buttonStyle(.plain).disabled(!canSend)
            .help("Ask · ↵").accessibilityLabel("Ask side question")
        }
        .padding(.leading, 12).padding(.trailing, 6).padding(.vertical, 5)
        .glassSurface(cornerRadius: 18)
    }

    private var canSend: Bool { !isPending && !(sideChat.drafts[conversationID] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func send() {
        guard canSend else { return }
        sideChat.ask(sideChat.drafts[conversationID] ?? "", in: conversationID)
    }
}

private struct SideChatBubble: View {
    let message: SideChatMessage
    var onRetry: () -> Void

    var body: some View {
        switch message.role {
        case .question:
            HStack {
                Spacer(minLength: 36)
                Text(message.text).font(.system(size: 13.5)).textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Theme.sidebar, in: RoundedRectangle(cornerRadius: 13))
            }
        case .answer:
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    GrokMark(size: 15)
                    Text("Crok").font(.system(size: 11.5, weight: .semibold))
                    Spacer(minLength: 0)
                    IconButton(icon: "doc.on.doc", help: "Copy answer", size: 22) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(message.text, forType: .string)
                    }
                }
                MarkdownReply(text: message.text, style: MarkdownStyle(fontSize: 13.5, blockSpacing: 9))
            }
        case .failure:
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(Color.orange)
                Text(message.text).font(.system(size: 12.5)).foregroundStyle(Theme.muted).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button("Retry", action: onRetry).buttonStyle(SubtleButtonStyle()).font(.system(size: 12, weight: .medium))
            }
            .padding(10).background(Theme.sidebar, in: RoundedRectangle(cornerRadius: 10))
        }
    }
}
