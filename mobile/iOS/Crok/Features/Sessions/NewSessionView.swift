import SwiftUI

/// The list toolbar's compose button opens this first: which project the new session starts in (projects of online
/// computers, grouped by computer, most recent first), like Telegram's "New Message" picking whom to write to.
struct NewSessionPicker: View {
    let groups: [ProjectGroup]
    let onPick: (NewSessionTarget) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let computers = NewSessionChoices.computers(from: groups)
        NavigationStack {
            List {
                ForEach(computers) { computer in
                    Section {
                        ForEach(computer.projects) { group in
                            Button {
                                onPick(NewSessionTarget(group: group))
                                dismiss()
                            } label: {
                                HStack(spacing: 12) {
                                    ProjectAvatarView(folder: group.name, size: 36, square: true)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(verbatim: group.name)
                                            .font(.body.weight(.semibold))
                                            .foregroundStyle(.primary)
                                        Text(verbatim: PathText.abbreviatingHome(group.path))
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                }
                                // The whole row is the button, not just its text.
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("newSessionProject-\(group.name)")
                        }
                    } header: {
                        HStack(spacing: 5) {
                            Circle().fill(Theme.online).frame(width: 6, height: 6)
                            Text(verbatim: computer.name)
                        }
                    }
                }
            }
            .overlay {
                if computers.isEmpty {
                    ContentUnavailableView {
                        Label("No computer is online", systemImage: "desktopcomputer")
                    } description: {
                        Text("Start crok or Crok Desktop on a computer to start a session there.")
                    }
                }
            }
            .navigationTitle("New Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

/// A session about to start (relay/DESIGN.md §5 "New sessions"): the composer, where it will run, and the model and
/// thinking level to start on (the computer's `devices:models`; Default until picked, kept on this screen only).
/// Sending calls `sessions:create` with the prompt shown at once; the screen then becomes that session.
@MainActor
@Observable
final class NewSessionModel {
    let target: NewSessionTarget
    let engine: CrokEngine
    var draft: String
    /// The prompt on its way, shown before the relay answers.
    private(set) var pendingPrompt: LocalPrompt?
    private(set) var isCreating = false
    var actionError: RelayError?
    /// The same client id for every attempt: a repeat after a lost answer is the same session.
    let clientId: String
    /// What the computer can run (`devices:models`), while the screen is open.
    let modelQuery: LiveQuery<[ModelChoice]?>
    /// The model picked for the session (an id); nil for Default, the computer's own choice.
    private(set) var pickedModel: String?
    /// The thinking level picked (an option id of `pickedModel`'s levels); nil for Default.
    private(set) var pickedLevel: String?
    /// Choose a Model (the model pill).
    var showsModelPicker = false
    @ObservationIgnored var onCreated: ((DocID) -> Void)?

    init(target: NewSessionTarget, engine: CrokEngine, draft: String = "", clientId: String = UUID().uuidString.lowercased()) {
        self.target = target
        self.engine = engine
        self.draft = draft
        self.clientId = clientId
        let devices = engine.devices
        let deviceId = target.deviceId
        modelQuery = LiveQuery(engine: engine) { devices.models(deviceId) }
    }

    /// Watches the computer's list while the screen shows.
    func start() { modelQuery.start() }
    func stop() { modelQuery.stop() }

    /// The computer's list; with an older relay (no `devices:models`) there is none for a session not made yet.
    var modelList: ModelList {
        ModelList.resolve(
            listed: modelQuery.value, listFailed: modelQuery.value == nil && modelQuery.error != nil, fallback: nil,
            fallbackLoaded: true)
    }

    /// The pills above the input row; nil hides the row.
    var setupRow: ModelSetupRow? {
        ModelSetup.newSession(list: modelList, model: pickedModel, effort: pickedLevel, computerOnline: computerOnline)
    }

    /// Choose a Model: a model, or Default (nil). The thinking level goes back to Default.
    func chooseModel(_ id: String?) {
        guard id != pickedModel else { return }
        pickedModel = id
        pickedLevel = nil
    }

    /// The thinking menu: a level's option id, or Default (nil).
    func chooseLevel(_ id: String?) {
        pickedLevel = id
    }

    /// Whether the computer is online now (from the list); a new session needs a crok there.
    var computerOnline: Bool {
        if let group = engine.groups.first(where: { $0.deviceId == target.deviceId }) { return group.deviceOnline }
        return engine.computers.first(where: { $0.id == target.deviceId })?.online ?? true
    }

    var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isCreating && computerOnline
    }

    func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isCreating else { return }
        isCreating = true
        draft = ""
        pendingPrompt = LocalPrompt(clientId: clientId, text: text, createdAt: Date().milliseconds)
        let setup = ModelSetup.createArguments(list: modelList, model: pickedModel, effort: pickedLevel)
        let result = await engine.startSession(
            in: target, text: text, model: setup.model, effort: setup.effort, clientId: clientId)
        isCreating = false
        switch result {
        case .success(let sessionDocId):
            onCreated?(sessionDocId)
        case .failure(let error):
            // Nothing was made (offline, an older crok there, a bad folder): the text goes back to the field.
            pendingPrompt = nil
            draft = text
            actionError = error
        }
    }
}

struct NewSessionContent: View {
    @Bindable var model: NewSessionModel
    @Environment(CrokEngine.self) private var engine
    @FocusState private var composerFocused: Bool
    @AppStorage(SessionTheme.storageKey) private var themeID = SessionTheme.noneID
    @Environment(\.colorScheme) private var colorScheme

    private var palette: SessionPalette {
        SessionPalette.make(SessionTheme.named(themeID), dark: colorScheme == .dark)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                if let prompt = model.pendingPrompt {
                    PendingPromptBubble(prompt: prompt)
                        .padding(.top, 12)
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .defaultScrollAnchor(.bottom)
        .scrollDismissesKeyboard(.interactively)
        .background(SessionBackgroundView().ignoresSafeArea())
        .environment(\.sessionPalette, palette)
        .overlay {
            if model.pendingPrompt == nil {
                VStack(spacing: 12) {
                    Image(systemName: "terminal")
                        .font(.system(size: 30, weight: .regular))
                        .foregroundStyle(palette.onWallpaper ? Color.white : Theme.accent)
                    Text("Starts in \(PathText.abbreviatingHome(model.target.path)) on \(model.target.deviceName)")
                        .font(.subheadline)
                        .foregroundStyle(palette.serviceText)
                        .multilineTextAlignment(.center)
                    if !model.computerOnline {
                        Text("\(model.target.deviceName) is offline. Start crok or Crok Desktop there first.")
                            .font(.footnote)
                            .foregroundStyle(Theme.danger)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .background(palette.serviceBackground, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .frame(maxWidth: 320)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("newSessionPlaceholder")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ComposerBar {
                VStack(spacing: 8) {
                    if let row = model.setupRow, model.pendingPrompt == nil {
                        ModelSetupBar(
                            row: row, offersDefault: true, onModel: { model.showsModelPicker = true },
                            onLevel: { model.chooseLevel($0) })
                        .transition(.opacity)
                    }
                    ComposerInputRow(
                        draft: $model.draft,
                        placeholder: String(localized: "Message crok on \(model.target.deviceName)…"),
                        focused: $composerFocused, menu: nil, isRunning: false, canSend: model.canSend,
                        onStop: {}, onSend: { Task { await model.send() } })
                }
                .animation(.snappy, value: model.setupRow == nil)
            }
        }
        .sheet(isPresented: $model.showsModelPicker) {
            ModelPickerSheet(
                models: model.modelList.models ?? [], computerName: model.target.deviceName, current: model.pickedModel,
                offersDefault: true, onPick: { model.chooseModel($0) })
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                ConnectionTitleView(
                    title: String(localized: "New session"), connection: engine.connection,
                    subtitle: AnyView(
                        Text(verbatim: "\(model.target.projectName) · \(model.target.deviceName)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .accessibilityIdentifier("newSessionSubtitle")))
            }
        }
        .toolbar(.hidden, for: .tabBar)
        .onAppear {
            model.start()
            if model.draft.isEmpty { composerFocused = true }
        }
        .onDisappear { model.stop() }
        .alert(
            "Couldn't start the session",
            isPresented: Binding(get: { model.actionError != nil }, set: { if !$0 { model.actionError = nil } }),
            presenting: model.actionError
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { error in
            Text(error.message)
        }
    }
}

/// The new session's first prompt while `sessions:create` is on its way (clock tick), before the screen becomes the
/// session.
private struct PendingPromptBubble: View {
    let prompt: LocalPrompt
    @Environment(\.sessionPalette) private var palette

    var body: some View {
        HStack(alignment: .bottom) {
            Spacer(minLength: 48)
            VStack(alignment: .trailing, spacing: 3) {
                Text(prompt.text)
                    .foregroundStyle(palette.userBubbleText)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 4) {
                    Text(Date(milliseconds: prompt.createdAt), format: .dateTime.hour().minute())
                    DeliveryTickView(tick: .sending, color: palette.userBubbleMeta)
                }
                .font(.caption2)
                .foregroundStyle(palette.userBubbleMeta)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(palette.userBubble, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .opacity(0.85)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("userBubble")
    }
}
