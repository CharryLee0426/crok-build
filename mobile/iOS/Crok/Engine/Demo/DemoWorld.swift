import Foundation

/// The demo relay's state: two computers, a handful of sessions in every state, and a transcript with every event
/// kind. Launch with `-CrokDemo YES` to use it; prompts, Stop and session info are simulated.
@MainActor
final class DemoWorld {
    struct Session {
        var detail: SessionDetail
        var events: [TranscriptEvent]
        var commands: [PromptCommand]
        var preview: String?
        var previewKind: EventKind?
        var turn: Task<Void, Never>?
    }

    var sessions: [Session] = []
    var devices: [DeviceRow] = []
    var me: AccountInfo
    var infoCommands: [DocID: CommandRecord] = [:]
    let currentDeviceId = "demo-phone"
    private var observers: [UUID: @MainActor () -> Void] = [:]
    private var nextId = 1000

    init(now: Date = Date()) {
        me = AccountInfo(
            userId: "demo-user", name: "Charlie Lee", email: "charlie@example.com", imageUrl: nil,
            device: .init(deviceId: "demo-phone", kind: .phone, name: "Charlie's iPhone", platform: "iOS 26.0", client: AppInfo.clientName))
        build(now: now)
    }

    // MARK: Observation

    func addObserver(_ id: UUID, _ callback: @escaping @MainActor () -> Void) { observers[id] = callback }
    func removeObserver(_ id: UUID) { observers[id] = nil }
    func changed() { for observer in Array(observers.values) { observer() } }

    func newId(_ prefix: String) -> DocID {
        nextId += 1
        return "\(prefix)-\(nextId)"
    }

    // MARK: Queries

    func rows(archived: Bool) -> [SessionRow] {
        sessions
            .filter { $0.detail.archived == archived }
            .map(row)
            .sorted { a, b in a.pinned != b.pinned ? a.pinned : a.lastActivityAt > b.lastActivityAt }
    }

    func row(_ session: Session) -> SessionRow {
        let d = session.detail
        let plan = d.plan.isEmpty
            ? nil : PlanProgress(done: Double(d.plan.filter { $0.status == "completed" }.count), total: Double(d.plan.count))
        let device = devices.first(where: { $0.id == d.deviceId })
        return SessionRow(
            id: d.id, sessionId: d.sessionId, title: d.title, cwd: d.cwd, model: d.model, status: d.status, online: d.online,
            app: d.app, deviceId: d.deviceId, deviceName: device?.name ?? d.deviceName, deviceOnline: device?.online ?? false,
            preview: session.preview, previewKind: session.previewKind, lastActivityAt: d.lastActivityAt, pinned: d.pinned,
            archived: d.archived, unread: d.unread, plan: plan)
    }

    func index(of id: DocID) throws -> Int {
        guard let index = sessions.firstIndex(where: { $0.detail.id == id }) else {
            throw RelayError(.notFound, "No such session.")
        }
        return index
    }

    func eventsPage(_ id: DocID, cursor: String?, endCursor: String?, numItems: Int) throws -> EventsPage {
        let all = sessions[try index(of: id)].events.sorted { $0.seq > $1.seq }
        let startSeq = cursor.flatMap(Double.init) ?? .infinity
        let candidates = all.filter { $0.seq < startSeq }
        let page: [TranscriptEvent]
        if let end = endCursor.flatMap(Double.init) {
            page = candidates.filter { $0.seq >= end }
        } else {
            page = Array(candidates.prefix(numItems))
        }
        let lastSeq = page.last?.seq ?? (startSeq.isFinite ? startSeq : 0)
        let isDone = !candidates.contains(where: { $0.seq < lastSeq })
        return EventsPage(page: page, isDone: isDone, continueCursor: String(lastSeq), splitCursor: nil, pageStatus: nil)
    }

    // MARK: Mutations

    func pushEvent(_ session: Int, kind: EventKind, text: String, title: String? = nil, toolKind: String? = nil,
                   status: String? = nil, origin: String? = nil, commandId: DocID? = nil, fromLabel: String? = nil,
                   key: String? = nil) -> DocID
    {
        let seq = (sessions[session].events.map(\.seq).max() ?? 0) + 1
        let id = newId("event")
        let now = Date().milliseconds
        sessions[session].events.append(
            TranscriptEvent(
                id: id, seq: seq, key: key ?? id, kind: kind, text: text, title: title, toolKind: toolKind, status: status,
                origin: origin, commandId: commandId, fromLabel: fromLabel, at: now))
        sessions[session].detail.lastActivityAt = now
        sessions[session].detail.eventSeq = seq
        return id
    }

    func updateEvent(_ session: Int, id: DocID, text: String? = nil, status: String? = nil) {
        guard let index = sessions[session].events.firstIndex(where: { $0.id == id }) else { return }
        if let text { sessions[session].events[index].text = text }
        if let status { sessions[session].events[index].status = status }
    }

    func setCommand(_ session: Int, _ commandId: DocID, status: CommandStatus, error: String? = nil) {
        guard let index = sessions[session].commands.firstIndex(where: { $0.id == commandId }) else { return }
        sessions[session].commands[index].status = status
        sessions[session].commands[index].error = error
        sessions[session].commands[index].updatedAt = Date().milliseconds
    }

    /// A prompt from the phone: queued, picked up, a tool call, a reply streamed in chunks, done.
    func runPrompt(sessionId: DocID, commandId: DocID, text: String) {
        guard let s = try? index(of: sessionId) else { return }
        sessions[s].turn?.cancel()
        sessions[s].turn = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard let self, !Task.isCancelled, let s = try? self.index(of: sessionId) else { return }
            self.setCommand(s, commandId, status: .delivered)
            _ = self.pushEvent(s, kind: .user, text: text, origin: "remote", commandId: commandId, fromLabel: "Charlie's iPhone")
            self.sessions[s].detail.status = .running
            self.sessions[s].preview = text
            self.sessions[s].previewKind = .user
            self.changed()

            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            let tool = self.pushEvent(
                s, kind: .tool, text: "Sources/Relay/Upload.swift", title: "Read Upload.swift", toolKind: "read",
                status: "in_progress")
            self.changed()
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            self.updateEvent(s, id: tool, status: "completed")
            self.changed()

            let reply = DemoWorld.streamedReply
            let answer = self.pushEvent(s, kind: .assistant, text: "")
            var shown = 0
            let words = reply.split(separator: " ", omittingEmptySubsequences: false)
            while shown < words.count {
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled else { return }
                shown = min(words.count, shown + 9)
                self.updateEvent(s, id: answer, text: words.prefix(shown).joined(separator: " "))
                self.changed()
            }
            self.sessions[s].detail.status = .idle
            self.sessions[s].preview = reply
            self.sessions[s].previewKind = .assistant
            self.setCommand(s, commandId, status: .done)
            _ = self.pushEvent(s, kind: .system, text: "", status: "end_turn")
            self.changed()
        }
    }

    func stopTurn(sessionId: DocID) {
        guard let s = try? index(of: sessionId) else { return }
        sessions[s].turn?.cancel()
        sessions[s].turn = nil
        for i in sessions[s].events.indices where sessions[s].events[i].kind == .tool {
            if sessions[s].events[i].status == "in_progress" || sessions[s].events[i].status == "pending" {
                sessions[s].events[i].status = "failed"
            }
        }
        for i in sessions[s].commands.indices where sessions[s].commands[i].status == .delivered {
            sessions[s].commands[i].status = .done
        }
        sessions[s].detail.status = .idle
        _ = pushEvent(s, kind: .system, text: "", status: "cancelled")
        changed()
    }

    func info(for sessionId: DocID) -> SessionInfoResult? {
        guard let s = try? index(of: sessionId) else { return nil }
        let d = sessions[s].detail
        return SessionInfoResult(
            model: d.model, effort: d.effort, cwd: d.cwd, gitBranch: d.gitBranch, title: d.title, createdAt: d.createdAt,
            usage: d.usage, contextUsed: d.usage?.contextTokens, contextWindow: d.usage?.contextWindow,
            messages: Double(sessions[s].events.count), sessionId: d.sessionId)
    }

    static let streamedReply = """
        The upload test flakes because `UploadQueue` retries on a **real** timer: when the CI machine is slow, the \
        second retry lands after the test's 2 s deadline.

        I changed the queue to take a clock, and the test now drives it:

        ```swift
        let clock = TestClock()
        let queue = UploadQueue(clock: clock)
        await clock.advance(by: .seconds(5))
        ```

        Ran the test 50 times in a row: all green.
        """
}
