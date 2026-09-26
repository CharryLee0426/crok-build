import AppKit
import SwiftUI

extension Notification.Name {
    static let grokFocusComposer = Notification.Name("ai.grok.desktop.focus-composer")
}

/// State for the native equivalents of the terminal's commands, grouped by area. Each model
/// is an environment object, so a panel re-renders only when its own area changes.
@MainActor
final class DesktopFeatures {
    let account: AccountFeatureModel
    let transcript: TranscriptToolsModel
    let composer: ComposerFeatureModel
    let sessions: SessionFeatureModel
    let extensions: ExtensionFeatureModel
    let extras: ExtrasFeatureModel
    let attachments: PromptAttachmentsModel
    let files: FilesPanelModel
    let sideChat: SideChatModel
    let terminals: TerminalSessions

    init(store: AppStore) {
        account = AccountFeatureModel(store: store)
        transcript = TranscriptToolsModel(store: store)
        composer = ComposerFeatureModel(store: store)
        sessions = SessionFeatureModel(store: store)
        extensions = ExtensionFeatureModel(store: store)
        extras = ExtrasFeatureModel(store: store)
        attachments = PromptAttachmentsModel(store: store)
        files = FilesPanelModel(store: store)
        sideChat = SideChatModel(store: store)
        terminals = TerminalSessions()
    }

    /// Notifications from connections that do not belong to a task, such as the one that
    /// loads the model catalog: announcements and account settings.
    func handleGlobal(method: String, params: [String: Any]) {
        _ = account.handleGlobal(method: method, params: params)
        _ = composer.handleGlobal(method: method, params: params)
    }

    /// Every model sees each harness notification until one consumes it.
    /// `update` is the `session/update` payload when the notification carries one.
    func handle(method: String, params: [String: Any], update: [String: Any]?, conversationID: UUID) -> Bool {
        account.handle(method: method, params: params, update: update, conversationID: conversationID)
            || composer.handle(method: method, params: params, update: update, conversationID: conversationID)
            || sessions.handle(method: method, params: params, update: update, conversationID: conversationID)
            || transcript.handle(method: method, params: params, update: update, conversationID: conversationID)
            || extensions.handle(method: method, params: params, update: update, conversationID: conversationID)
            || extras.handle(method: method, params: params, update: update, conversationID: conversationID)
    }
}

/// Native sheets opened by commands. Each case's view belongs to the feature that owns it.
enum DesktopSheet: Identifiable, Equatable {
    case usage(UsageTab)
    case feedback(text: String)
    case editPrompt(text: String)
    case fork(arguments: String)
    case resume
    case dashboard
    case tasks
    case workflowRuns
    case doctor(arguments: String)
    case remember(text: String)
    case importClaude
    case theme
    case keyboardShortcuts
    case history
    case jump

    var id: String {
        switch self {
        case .usage(let tab): return "usage.\(tab.rawValue)"
        case .feedback: return "feedback"
        case .editPrompt: return "edit-prompt"
        case .fork: return "fork"
        case .resume: return "resume"
        case .dashboard: return "dashboard"
        case .tasks: return "tasks"
        case .workflowRuns: return "workflow-runs"
        case .doctor: return "doctor"
        case .remember: return "remember"
        case .importClaude: return "import-claude"
        case .theme: return "theme"
        case .keyboardShortcuts: return "keyboard-shortcuts"
        case .history: return "history"
        case .jump: return "jump"
        }
    }
}

enum UsageTab: String, CaseIterable, Identifiable {
    case context, usage, session
    var id: String { rawValue }
    var title: String {
        switch self {
        case .context: return "Context usage"
        case .usage: return "Session usage"
        case .session: return "Session info"
        }
    }
}

/// Secondary windows. Their content reads what to show from the owning feature model.
enum DesktopWindow: String, CaseIterable {
    case trace, docs, releaseNotes = "release-notes", transcript, gboom, tutorial
}

extension DesktopSheet {
    @MainActor @ViewBuilder
    var content: some View {
        switch self {
        case .usage(let tab): UsageSheet(initialTab: tab)
        case .feedback(let text): FeedbackSheet(initialText: text)
        case .editPrompt(let text): EditPromptSheet(initialText: text)
        case .fork(let arguments): ForkSheet(arguments: arguments)
        case .resume: ResumeSheet()
        case .dashboard: DashboardSheet()
        case .tasks: TasksSheet()
        case .workflowRuns: WorkflowRunsSheet()
        case .doctor(let arguments): DoctorSheet(arguments: arguments)
        case .remember(let text): RememberSheet(initialText: text)
        case .importClaude: ImportClaudeSheet()
        case .theme: ThemeSheet()
        case .keyboardShortcuts: KeyboardShortcutsSheet()
        case .history: HistorySheet()
        case .jump: JumpSheet()
        }
    }
}

extension DesktopWindow {
    @MainActor @ViewBuilder
    var content: some View {
        switch self {
        case .trace: TraceWindow()
        case .docs: DocsWindow()
        case .releaseNotes: ReleaseNotesWindow()
        case .transcript: TranscriptWindow()
        case .gboom: GboomWindow()
        case .tutorial: TutorialWindow()
        }
    }

    var title: String {
        switch self {
        case .trace: return "Trace"
        case .docs: return "Grok Build Guides"
        case .releaseNotes: return "Release Notes"
        case .transcript: return "Transcript"
        case .gboom: return "GBOOM"
        case .tutorial: return "Welcome to Grok Build"
        }
    }

    var defaultSize: CGSize {
        switch self {
        case .trace: return CGSize(width: 1180, height: 800)
        case .gboom: return CGSize(width: 960, height: 700)
        case .tutorial: return CGSize(width: 760, height: 620)
        default: return CGSize(width: 860, height: 760)
        }
    }
}

extension View {
    /// Injects the store and every feature model, for the main window, sheets, and windows.
    @MainActor
    func desktopEnvironment(_ store: AppStore) -> some View {
        self.environmentObject(store)
            .environmentObject(store.features.account)
            .environmentObject(store.features.transcript)
            .environmentObject(store.features.composer)
            .environmentObject(store.features.sessions)
            .environmentObject(store.features.extensions)
            .environmentObject(store.features.extras)
            .environmentObject(store.features.attachments)
            .environmentObject(store.features.files)
            .environmentObject(store.features.sideChat)
            .environmentObject(store.features.terminals)
    }
}

/// The frame shared by command sheets: a title block, scrolling content, and a footer.
struct DesktopPanel<Content: View, Footer: View>: View {
    let title: String
    var subtitle: String?
    var width: CGFloat = 720
    var height: CGFloat? = nil
    var onClose: () -> Void
    @ViewBuilder var content: () -> Content
    @ViewBuilder var footer: () -> Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(title).font(.system(size: 23, weight: .semibold))
                    if let subtitle { Text(subtitle).font(.system(size: 13)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true) }
                }
                Spacer()
                IconButton(icon: "xmark", help: "Close", action: onClose).keyboardShortcut(.cancelAction)
            }.padding(24)
            Divider()
            content().frame(maxWidth: .infinity, maxHeight: height == nil ? nil : .infinity, alignment: .topLeading)
            Divider()
            HStack(spacing: 12) { footer() }
                .buttonStyle(SubtleButtonStyle()).font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 24).padding(.vertical, 18)
        }
        .frame(width: width, height: height)
        .glassSheetBackground()
    }
}

extension DesktopPanel where Footer == EmptyView {
    init(title: String, subtitle: String? = nil, width: CGFloat = 720, height: CGFloat? = nil, onClose: @escaping () -> Void, @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, subtitle: subtitle, width: width, height: height, onClose: onClose, content: content, footer: { EmptyView() })
    }
}

/// Metadata the harness reports from `initialize` and `authenticate`.
struct HarnessMeta {
    var initialize: [String: Any] = [:]
    var authenticate: [String: Any] = [:]
    var authMethods: [[String: Any]] = []

    var agentVersion: String? { initialize["agentVersion"] as? String }
    var voiceMode: Bool { initialize["voiceMode"] as? Bool ?? false }
    var feedbackTraceOffer: Bool { initialize["feedbackTraceOffer"] as? Bool ?? authenticate["feedback_trace_offer"] as? Bool ?? false }
    var codingDataRetentionOptOut: Bool? { authenticate["coding_data_retention_opt_out"] as? Bool }
    var isZDR: Bool { authenticate["is_zdr"] as? Bool ?? false }
    var teamName: String? { (authenticate["team_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } }
}

/// Placeholder for a panel whose feature is still being built.
struct PendingFeatureView: View {
    @EnvironmentObject var store: AppStore
    let title: String
    var body: some View {
        DesktopPanel(title: title, subtitle: "This view is not available yet.", width: 520, onClose: { store.sheet = nil }) {
            Text("Coming soon.").foregroundStyle(Theme.muted).padding(24)
        }
    }
}
