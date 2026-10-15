import SwiftUI

/// Session info: `sessions:get`, refreshed from the computer with `commands:requestInfo` while it is online.
@MainActor
@Observable
final class SessionInfoModel {
    let sessionDocId: DocID
    let engine: CrokEngine
    let detail: LiveQuery<SessionDetail>
    private(set) var fresh: SessionInfoResult?
    private(set) var refreshing = false
    private(set) var refreshProblem: String?
    @ObservationIgnored private var command: LiveQuery<CommandRecord?>?
    @ObservationIgnored private var requested = false

    init(sessionDocId: DocID, engine: CrokEngine) {
        self.sessionDocId = sessionDocId
        self.engine = engine
        let sessions = engine.sessions
        detail = LiveQuery(engine: engine) { sessions.get(sessionDocId) }
    }

    func start() {
        detail.onValue = { [weak self] value in
            guard let self, !self.requested, value.online else { return }
            self.requested = true
            Task { await self.requestFreshInfo() }
        }
        detail.start()
    }

    func stop() {
        detail.stop()
        command?.stop()
    }

    /// Asks the computer for fresh numbers and follows the command until it is done or failed.
    private func requestFreshInfo() async {
        refreshing = true
        let commands = engine.commands
        let id = sessionDocId
        do {
            let commandId = try await commands.requestInfo(id)
            let query = LiveQuery<CommandRecord?>(engine: engine) { commands.get(commandId) }
            query.onValue = { [weak self, weak query] record in
                guard let self, let record else { return }
                switch record.status {
                case .done:
                    self.fresh = record.result
                    self.refreshing = false
                    query?.stop()
                case .failed:
                    self.refreshProblem = record.error
                    self.refreshing = false
                    query?.stop()
                default:
                    break
                }
            }
            command = query
            query.start()
        } catch {
            let relayError = (error as? RelayError) ?? RelayError(.server, error.localizedDescription)
            if relayError.isRevoked { engine.handleRevoked() }
            refreshProblem = relayError.message
            refreshing = false
        }
    }
}

struct SessionInfoView: View {
    let sessionDocId: DocID
    let onRemoved: () -> Void
    @Environment(CrokEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss
    @State private var model: SessionInfoModel?
    @State private var confirmRemove = false
    @State private var actionError: RelayError?
    @State private var copied = false

    var body: some View {
        NavigationStack {
            Group {
                if let model, let detail = model.detail.value {
                    form(detail, fresh: model.fresh, model: model)
                } else if let error = model?.detail.error {
                    ContentUnavailableView("Session unavailable", systemImage: "exclamationmark.triangle", description: Text(error.message))
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Session info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("infoDone")
                }
            }
        }
        .onAppear {
            if model == nil {
                let created = SessionInfoModel(sessionDocId: sessionDocId, engine: engine)
                model = created
                created.start()
            }
        }
        .onDisappear { model?.stop() }
        .alert(
            "Couldn't do that", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } }),
            presenting: actionError
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { error in
            Text(error.message)
        }
    }

    @ViewBuilder
    private func form(_ detail: SessionDetail, fresh: SessionInfoResult?, model: SessionInfoModel) -> some View {
        let usage = Self.mergedUsage(detail.usage, fresh?.usage)
        let contextUsed = fresh?.contextUsed ?? detail.usage?.contextTokens
        let contextWindow = fresh?.contextWindow ?? detail.usage?.contextWindow
        Form {
            Section {
                HStack(spacing: 14) {
                    ProjectAvatarView(folder: detail.folderName, online: detail.online, dimmed: !detail.online, size: 52)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(fresh?.title ?? detail.title)
                            .font(.headline)
                            .lineLimit(2)
                        Text(statusLine(detail))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Model") {
                InfoRow("Model", value: fresh?.model ?? detail.model)
                InfoRow("Reasoning effort", value: (fresh?.effort ?? detail.effort).map(Self.effortName))
            }

            Section("Workspace") {
                InfoRow("Folder", value: PathText.abbreviatingHome(fresh?.cwd ?? detail.cwd), monospaced: true)
                InfoRow("Git branch", value: fresh?.gitBranch ?? detail.gitBranch, monospaced: true)
                InfoRow("Computer", value: detail.deviceName)
                InfoRow("App", value: Self.appName(detail.app))
                if !detail.devicePlatform.isEmpty {
                    InfoRow("Platform", value: detail.devicePlatform)
                }
            }

            Section("Activity") {
                InfoRow("Started", value: Date(milliseconds: fresh?.createdAt ?? detail.createdAt).formatted(date: .abbreviated, time: .shortened))
                InfoRow("Last activity", value: RelativeTime.ago(Date(milliseconds: detail.lastActivityAt), now: Date()))
                if let messages = fresh?.messages {
                    InfoRow("Messages", value: Int(messages).formatted())
                }
            }

            Section {
                InfoRow("Input tokens", value: usage?.inputTokens.map(Self.tokens))
                InfoRow("Output tokens", value: usage?.outputTokens.map(Self.tokens))
                InfoRow("Cached tokens", value: usage?.cachedTokens.map(Self.tokens))
                InfoRow("Reasoning tokens", value: usage?.reasoningTokens.map(Self.tokens))
                InfoRow("Cost", value: usage?.costUsd.map(Self.cost))
                if let used = contextUsed, let window = contextWindow, window > 0 {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Context")
                            Spacer()
                            Text("\(Self.tokens(used)) of \(Self.tokens(window))")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        ProgressView(value: min(1, used / window))
                            .tint(used / window > 0.85 ? Theme.waiting : Theme.accent)
                        Text("\(Int((used / window * 100).rounded()))% used")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                    .accessibilityElement(children: .combine)
                }
            } header: {
                HStack(spacing: 6) {
                    Text("Usage")
                    if model.refreshing {
                        ProgressView().controlSize(.mini)
                        Text("Updating from \(detail.deviceName)…")
                            .textCase(nil)
                            .accessibilityIdentifier("infoRefreshing")
                    }
                }
            } footer: {
                if let problem = model.refreshProblem {
                    Text("Showing the last numbers the relay has. \(problem)")
                } else if usage?.costUsd != nil {
                    Text("Estimated at standard API prices.")
                }
            }

            if !detail.plan.isEmpty, let summary = PlanSummary.make(detail.plan) {
                Section("Plan \(summary.done)/\(summary.total)") {
                    ForEach(Array(detail.plan.enumerated()), id: \.offset) { _, entry in
                        PlanEntryRow(entry: entry)
                    }
                }
            }

            Section("Session ID") {
                HStack {
                    Text(fresh?.sessionId ?? detail.sessionId)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button {
                        UIPasteboard.general.string = fresh?.sessionId ?? detail.sessionId
                        copied = true
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    }
                    .accessibilityLabel(Text("Copy"))
                    .buttonStyle(.borderless)
                }
            }

            Section {
                Button {
                    Task { actionError = await engine.setPinned(detail.id, !detail.pinned) }
                } label: {
                    Label(detail.pinned ? "Unpin" : "Pin", systemImage: detail.pinned ? "pin.slash" : "pin")
                }
                Button {
                    Task {
                        actionError = await engine.setArchived(detail.id, !detail.archived)
                        if actionError == nil { dismiss() }
                    }
                } label: {
                    Label(detail.archived ? "Unarchive" : "Archive", systemImage: detail.archived ? "tray.and.arrow.up" : "archivebox")
                }
                if !detail.online {
                    Button(role: .destructive) {
                        confirmRemove = true
                    } label: {
                        Label("Remove from relay", systemImage: "trash")
                    }
                    .accessibilityIdentifier("removeFromRelay")
                }
            } footer: {
                if !detail.online {
                    Text("Removing deletes the relay's copy. The session stays on \(detail.deviceName).")
                }
            }
        }
        .confirmationDialog("Remove this session from the relay?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove from relay", role: .destructive) {
                Task {
                    let sessions = engine.sessions
                    let id = detail.id
                    actionError = await engine.perform { try await sessions.remove(id) }
                    if actionError == nil {
                        dismiss()
                        onRemoved()
                    }
                }
            }
        } message: {
            Text("The session stays on \(detail.deviceName); only the copy on the relay is deleted.")
        }
    }

    private func statusLine(_ detail: SessionDetail) -> String {
        guard detail.online else { return String(localized: "offline") }
        switch detail.status {
        case .running: return String(localized: "working…")
        case .waiting: return String(localized: "waiting for approval on \(detail.deviceName)")
        case .error: return String(localized: "error · \(detail.deviceName)")
        case .idle: return String(localized: "idle · \(detail.deviceName)")
        }
    }

    static func mergedUsage(_ base: SessionUsage?, _ fresh: SessionUsage?) -> SessionUsage? {
        guard base != nil || fresh != nil else { return nil }
        var usage = base ?? SessionUsage()
        if let fresh {
            usage.inputTokens = fresh.inputTokens ?? usage.inputTokens
            usage.outputTokens = fresh.outputTokens ?? usage.outputTokens
            usage.cachedTokens = fresh.cachedTokens ?? usage.cachedTokens
            usage.reasoningTokens = fresh.reasoningTokens ?? usage.reasoningTokens
            usage.costUsd = fresh.costUsd ?? usage.costUsd
        }
        return usage
    }

    static func tokens(_ value: Double) -> String { Int(value.rounded()).formatted() }

    static func cost(_ value: Double) -> String {
        value.formatted(.currency(code: "USD").precision(.fractionLength(value < 1 ? 4 : 2)))
    }

    static func appName(_ app: HostApp) -> String {
        switch app {
        case .tui: String(localized: "Terminal (crok)")
        case .desktop: String(localized: "Crok Desktop")
        case .cli: String(localized: "Command line")
        case .unknown: String(localized: "Unknown")
        }
    }

    static func effortName(_ raw: String) -> String {
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
}

/// A label and a value; "—" when the value is unknown.
struct InfoRow: View {
    let title: LocalizedStringKey
    let value: String?
    var monospaced = false

    init(_ title: LocalizedStringKey, value: String?, monospaced: Bool = false) {
        self.title = title
        self.value = value
        self.monospaced = monospaced
    }

    var body: some View {
        LabeledContent {
            Text(value?.isEmpty == false ? value! : "—")
                .font(monospaced ? .system(.subheadline, design: .monospaced) : .body)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
        } label: {
            Text(title)
        }
    }
}
