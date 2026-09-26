import SwiftUI

extension ExtensionFeatureModel {
    /// Whether the selected task can run `memory/rewrite` (it needs a session, as in the terminal).
    var canEnhanceMemoryNote: Bool { store?.conversation?.sessionID != nil }

    /// `memory/rewrite` with the terminal's context summary. The raw text comes back on failure.
    func rewriteMemoryNote(_ raw: String) async throws -> String {
        guard let store else { throw DesktopError.message("Open a project first.") }
        let conversationID = store.state.selectedConversationID
        let (client, _, session) = try await store.featureSession()
        let result = try await client.request("_x.ai/memory/rewrite", params: [
            "sessionId": session, "rawText": raw, "contextSummary": rememberContext(conversationID: conversationID),
        ], timeout: 120)
        let text = (result["result"] as? [String: Any])?["rewritten"] as? String ?? result["rewritten"] as? String
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return raw }
        return text
    }

    /// The store a note will go to: what the task's memory listing showed, else config and disk.
    func memoryNoteMode(home: URL = GrokPaths.home, configURL: URL = GrokPaths.configFile) -> MemoryNoteMode {
        if let id = store?.state.selectedConversationID, let mode = memory.mode(for: id) { return mode }
        return MemoryNoteStore.inferMode(home: home, config: GrokConfig(url: configURL))
    }

    /// Learns the task's memory store from a quick listing when the task is already connected.
    func refreshMemoryNoteMode() async {
        guard let store, let id = store.state.selectedConversationID, memory.mode(for: id) == nil,
              let client = store.clients[id], store.loaded.contains(id), let session = store.conversation?.sessionID,
              let result = try? ExtensionResponse.unwrap(try await client.request("_x.ai/memory/list", params: ["sessionId": session])) else { return }
        memory.receive(MemoryListing(result), conversationID: id)
    }

    /// Saves like the terminal: a "Saving" line, then the outcome.
    func saveMemoryNote(_ text: String, mode: MemoryNoteMode, home: URL = GrokPaths.home) async {
        guard let store else { return }
        store.banner = "Saving memory note..."
        do {
            try await Task.detached(priority: .userInitiated) { _ = try MemoryNoteStore.save(text, mode: mode, home: home) }.value
            store.banner = "Memory note saved"
        } catch {
            store.banner = "Couldn't save memory note: \(error.localizedDescription)"
        }
    }
}

/// `/remember [text]`: write a note, optionally let Grok enhance it with the task's context, and save it.
struct RememberSheet: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var extensions: ExtensionFeatureModel
    let initialText: String
    @State private var raw: String
    @State private var enhanced: String?
    @State private var showEnhanced = false
    @State private var enhancing = false
    @State private var enhanceNote: String?
    @State private var enhancedFrom: String?
    @State private var validation: String?
    @State private var mode: MemoryNoteMode = .legacy
    @State private var rewriteID = UUID()

    init(initialText: String) {
        self.initialText = initialText
        _raw = State(initialValue: initialText)
    }

    private var current: String { showEnhanced ? enhanced ?? raw : raw }
    private var canEnhance: Bool { extensions.canEnhanceMemoryNote && !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !enhancing }

    var body: some View {
        DesktopPanel(title: "Memory Note", subtitle: "Save something Crok should remember in future sessions.", width: 640, onClose: { store.sheet = nil }) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Picker("Version", selection: $showEnhanced) {
                        Text("Raw").tag(false)
                        Text("Enhanced").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    .disabled(enhanced == nil)
                    .help(enhanced == nil ? "Enhance the note to compare versions." : "Switch between your note and Crok's version.")
                    if enhancing {
                        ProgressView().controlSize(.small)
                        Text("Enhancing…").font(.system(size: 12)).foregroundStyle(Theme.muted)
                    } else if let enhanceNote {
                        Text(enhanceNote).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(2)
                    } else if enhanced != nil, enhancedFrom != raw {
                        Text("Your note changed since it was enhanced.").font(.system(size: 12)).foregroundStyle(Theme.muted)
                    } else if enhanced != nil, !showEnhanced {
                        Label("Crok's enhanced version is ready", systemImage: "sparkles").font(.system(size: 12)).foregroundStyle(Theme.accent)
                    }
                    Spacer(minLength: 0)
                }
                MemoryNoteEditor(text: showEnhanced ? Binding(get: { enhanced ?? "" }, set: { enhanced = $0 }) : $raw,
                                 placeholder: "Save a memory note…")
                    .frame(height: 230)
                if let validation {
                    Label(validation, systemImage: "exclamationmark.circle").font(.system(size: 12)).foregroundStyle(.red)
                }
                HStack(spacing: 6) {
                    Image(systemName: mode == .legacy ? "doc.text" : "tray.and.arrow.down").accessibilityHidden(true)
                    Text("Saved to global memory · \(MemoryNoteStore.destination(mode))").lineLimit(1).truncationMode(.middle)
                }.font(.system(size: 12)).foregroundStyle(Theme.muted)
            }.padding(24)
        } footer: {
            Button { enhance() } label: { Label(enhanced == nil ? "Enhance" : "Enhance again", systemImage: "sparkles") }
                .disabled(!canEnhance)
                .help(extensions.canEnhanceMemoryNote ? "Rewrite the note with context from this task." : "Enhancing needs a task with a session.")
            Spacer()
            Button("Cancel") { store.sheet = nil }
            Button("Save") { save() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(enhancing && showEnhanced)
        }
        .task {
            mode = extensions.memoryNoteMode()
            await extensions.refreshMemoryNoteMode()
            mode = extensions.memoryNoteMode()
            // A note typed with the command is enhanced right away, like the terminal's review step.
            if !initialText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, extensions.canEnhanceMemoryNote { enhance() }
        }
    }

    private func enhance() {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { validation = "Please provide a memory note."; return }
        let request = UUID(); rewriteID = request
        enhancing = true; enhanceNote = nil; validation = nil
        Task {
            do {
                let result = try await extensions.rewriteMemoryNote(text)
                guard rewriteID == request else { return }
                enhanced = result; enhancedFrom = raw
            } catch {
                guard rewriteID == request else { return }
                enhanceNote = "Couldn't enhance: \(ExtensionErrorText.describe(error))"
            }
            if rewriteID == request { enhancing = false }
        }
    }

    private func save() {
        let text = current.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { validation = "Please provide a memory note."; return }
        if mode == .v2, MemoryNoteStore.normalize(text).utf8.count > MemoryNoteStore.maxObservationBytes {
            validation = MemoryNoteError.tooLarge(actual: MemoryNoteStore.normalize(text).utf8.count, limit: MemoryNoteStore.maxObservationBytes).localizedDescription
            return
        }
        rewriteID = UUID()
        store.sheet = nil
        let mode = mode
        Task { await extensions.saveMemoryNote(text, mode: mode) }
    }
}

/// A plain multi-line editor on the app's input surface.
struct MemoryNoteEditor: View {
    @Binding var text: String
    var placeholder: String
    var monospaced = false
    @FocusState private var focused: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .font(monospaced ? .system(size: 13, design: .monospaced) : .system(size: 14))
                .scrollContentBackground(.hidden)
                .focused($focused)
                .padding(.horizontal, 8).padding(.vertical, 10)
                .accessibilityLabel(placeholder)
            if text.isEmpty {
                Text(placeholder).font(.system(size: 14)).foregroundStyle(Theme.muted)
                    .padding(.horizontal, 13).padding(.vertical, 10).allowsHitTesting(false)
            }
        }
        .modifier(InputSurface(focused: focused))
        .onAppear { focused = true }
    }
}
