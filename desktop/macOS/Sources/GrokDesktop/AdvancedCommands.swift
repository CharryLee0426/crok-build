import Foundation

extension AppStore {
    func requestRecap() async {
        guard let project else { banner = "Open a project first."; return }
        let selectedID = state.selectedConversationID
        let requestID = UUID()
        advancedRequestID = requestID
        advancedTitle = "Session recap"; advancedContent = nil; advancedError = nil
        advancedLoading = true; showAdvancedPanel = true; pendingRecap = nil
        do {
            let (client, id, session) = try await featureSession()
            guard advancedRequestID == requestID, self.project?.id == project.id,
                  state.selectedConversationID == id, selectedID == nil || selectedID == id else {
                if advancedRequestID == requestID { advancedLoading = false }
                return
            }
            // The notification can arrive before the request acknowledgment.
            pendingRecap = (conversationID: id, requestID: requestID)
            let result = try ExtensionResponse.unwrap(try await client.request("_x.ai/recap", params: ["sessionId": session, "auto": false]))
            guard advancedRequestID == requestID, pendingRecap?.requestID == requestID else { return }
            if result["disabled"] as? Bool == true {
                pendingRecap = nil; advancedLoading = false
                advancedError = "Session recap is disabled by the harness configuration."
            } else if result["ok"] as? Bool != true {
                throw DesktopError.message("The harness did not acknowledge the recap request.")
            } else {
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 120_000_000_000)
                    guard let self, self.pendingRecap?.requestID == requestID,
                          self.advancedRequestID == requestID else { return }
                    self.pendingRecap = nil; self.advancedLoading = false
                    self.advancedError = "The harness has not returned a recap yet. Try /recap again."
                }
            }
        } catch {
            guard advancedRequestID == requestID else { return }
            pendingRecap = nil; advancedLoading = false
            guard self.project?.id == project.id, selectedID == nil || state.selectedConversationID == selectedID else { return }
            advancedError = error.localizedDescription
        }
    }

    /// Returns true for recap notifications, including unsolicited automatic ones.
    /// Automatic summaries must not replace a user's unrelated detail panel.
    func consumeAdvancedUpdate(_ update: [String: Any], id: UUID) -> Bool {
        guard let kind = update["sessionUpdate"] as? String,
              ["session_recap", "session_recap_unavailable"].contains(kind) else { return false }
        guard update["auto"] as? Bool != true,
              let pending = pendingRecap, pending.conversationID == id else { return true }
        pendingRecap = nil
        guard pending.requestID == advancedRequestID else { return true }
        advancedLoading = false
        guard state.selectedConversationID == id else { return true }
        if kind == "session_recap", let summary = update["summary"] as? String, !summary.isEmpty {
            advancedContent = summary; advancedError = nil
        } else {
            advancedError = "A recap is not available yet. The session may have no completed response, or the model could not generate a summary."
        }
        return true
    }

    func loadRewindPoints() async {
        guard let selected = conversation, let project else { banner = "Select an existing task to rewind."; return }
        guard !run.isRunning, !run.isConfiguring else { banner = "Stop the current turn before choosing a rewind point."; return }
        let requestID = UUID()
        advancedRequestID = requestID; pendingRecap = nil
        advancedTitle = "Rewind"; advancedContent = nil; advancedError = nil
        advancedLoading = true; showAdvancedPanel = true
        rewindPoints = []; rewindPreview = nil; rewindConversationID = selected.id
        defer { if advancedRequestID == requestID { advancedLoading = false } }
        do {
            let (client, id, session) = try await featureSession()
            guard id == selected.id, state.selectedConversationID == id else { return }
            let result = try ExtensionResponse.unwrap(try await client.request("_x.ai/rewind/points", params: ["sessionId": session]))
            guard advancedRequestID == requestID, state.selectedConversationID == id, self.project?.id == project.id else { return }
            rewindPoints = try RewindCheckpoint.parse(result)
            advancedContent = rewindPoints.isEmpty ? "No rewind checkpoints are available for this task." : "Choose a prompt to restore the state from before that prompt ran. Later prompts are removed when restoring the conversation. File restoration can undo changes made by Crok."
        } catch {
            if advancedRequestID == requestID, state.selectedConversationID == selected.id { advancedError = error.localizedDescription }
        }
    }

    func canRestoreRewind(_ point: RewindCheckpoint, mode: RewindSelection) -> Bool {
        rewindConversationID == state.selectedConversationID && rewindPoints.contains(point)
            && rewindPreview?.matches(point, mode: mode) == true && rewindPreview?.conflicts.isEmpty == true
            && !run.isRunning && !run.isConfiguring && !advancedLoading
    }

    func previewRewind(_ point: RewindCheckpoint, mode: RewindSelection) async {
        guard let selected = conversation, selected.id == rewindConversationID, rewindPoints.contains(point),
              !run.isRunning, !run.isConfiguring, !advancedLoading else { advancedError = "Choose a checkpoint in a stopped task."; return }
        guard mode == .conversationOnly || point.hasFileChanges else { advancedError = "This checkpoint has no file snapshots."; return }
        let requestID = UUID()
        advancedRequestID = requestID; advancedLoading = true; advancedError = nil; rewindPreview = nil
        defer { if advancedRequestID == requestID { advancedLoading = false } }
        do {
            let (client, id, session) = try await featureSession()
            guard id == selected.id, state.selectedConversationID == id else { return }
            let raw = try await client.request("_x.ai/rewind/execute", params: ["sessionId": session, "targetPromptIndex": point.promptIndex, "mode": mode.rawValue, "force": false], timeout: 120)
            let preview = try RewindPreview.parse(raw["result"] as? [String: Any] ?? raw, point: point, mode: mode)
            guard advancedRequestID == requestID, state.selectedConversationID == id else { return }
            rewindPreview = preview; advancedContent = preview.summary
        } catch {
            if advancedRequestID == requestID, state.selectedConversationID == selected.id { advancedError = error.localizedDescription }
        }
    }

    /// Called only after preview and explicit UI confirmation. In this harness,
    /// force:false is a dry run, and force:true commits. Never commit known conflicts.
    func restoreRewind(_ point: RewindCheckpoint, mode: RewindSelection) async {
        guard let selected = conversation, let project, selected.id == rewindConversationID,
              rewindPoints.contains(point) else { advancedError = "Reload the rewind points for the selected task."; return }
        guard canRestoreRewind(point, mode: mode), let approvedPreview = rewindPreview else { advancedError = "Preview this checkpoint and resolve any conflicts before restoring."; return }
        guard mode == .conversationOnly || point.hasFileChanges else { advancedError = "This checkpoint does not have file snapshots. Choose conversation only."; return }
        let requestID = UUID()
        advancedRequestID = requestID; advancedLoading = true; advancedError = nil
        var boundID: UUID?
        var sentRequest = false
        var receivedResponse = false
        defer {
            if let boundID { runs[boundID]?.isConfiguring = false }
            if advancedRequestID == requestID { advancedLoading = false }
        }
        do {
            let (client, id, session) = try await featureSession()
            guard id == selected.id, state.selectedConversationID == id, self.project?.id == project.id,
                  !run.isRunning, !run.isConfiguring else { throw CancellationError() }
            boundID = id; runs[id, default: RunState()].isConfiguring = true
            let currentRaw = try await client.request("_x.ai/rewind/execute", params: ["sessionId": session, "targetPromptIndex": point.promptIndex, "mode": mode.rawValue, "force": false], timeout: 120)
            let currentPreview = try RewindPreview.parse(currentRaw["result"] as? [String: Any] ?? currentRaw, point: point, mode: mode)
            guard advancedRequestID == requestID, state.selectedConversationID == id else { throw CancellationError() }
            guard currentPreview.conflicts.isEmpty, currentPreview.cleanFiles.sorted() == approvedPreview.cleanFiles.sorted() else {
                rewindPreview = currentPreview; advancedContent = currentPreview.summary
                throw DesktopError.message("The rewind preview changed. Review the affected files before restoring.")
            }
            sentRequest = true
            let raw = try await client.request("_x.ai/rewind/execute", params: ["sessionId": session, "targetPromptIndex": point.promptIndex, "mode": mode.rawValue, "force": true], timeout: 120)
            receivedResponse = true
            let result = raw["result"] as? [String: Any] ?? raw
            guard result["success"] as? Bool == true else { throw DesktopError.message(RewindCheckpoint.failureMessage(result)) }
            if advancedRequestID == requestID { rewindPoints = []; rewindPreview = nil }
            await refreshAfterRewind(id: id, conversationChanged: mode != .filesOnly)
            guard state.selectedConversationID == id, self.project?.id == project.id, advancedRequestID == requestID else { return }
            if mode != .filesOnly, let prompt = result["prompt_text"] as? String { draft = prompt }
            let files = result["reverted_files"] as? [String] ?? []
            advancedContent = "Restored \(mode.title.lowercased()) to before prompt \(point.promptIndex + 1)." + (files.isEmpty ? "" : "\n\nRestored files:\n" + files.joined(separator: "\n"))
            savedPlanContent = nil
        } catch {
            if sentRequest, !receivedResponse, let boundID {
                // Reconcile from authoritative history even if a timed-out request
                // may have applied. No follow-up restore occurs.
                await refreshAfterRewind(id: boundID, conversationChanged: true)
            }
            if advancedRequestID == requestID, state.selectedConversationID == selected.id, !(error is CancellationError) {
                advancedError = error.localizedDescription
            }
        }
    }

    /// `/btw`: asks in the side panel's side chat, which uses the dedicated ACP lane so the
    /// active turn keeps running. Without a question it opens the side chat to type one.
    func askSideQuestion(_ question: String) {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        // A side question is about a task's conversation; don't start an empty one for it.
        guard let id = state.selectedConversationID else { banner = "Open a task to ask a side question about it."; return }
        showSidePanel(.sideChat)
        if question.isEmpty { features.sideChat.requestFocus() }
        else { features.sideChat.ask(question, in: id) }
    }

    /// Read the harness's saved Markdown plan, separate from ACP progress entries.
    /// This desktop connects to a local process; the session summary identifies its storage home.
    func loadSavedPlan() async {
        let requestID = UUID()
        savedPlanRequestID = requestID
        savedPlanContent = nil; savedPlanError = nil; savedPlanLoading = true
        defer { if savedPlanRequestID == requestID { savedPlanLoading = false } }
        guard let project, let selected = conversation, selected.sessionID != nil else { return }
        do {
            let (client, id, session) = try await featureSession()
            guard id == selected.id else { return }
            let result = try ExtensionResponse.unwrap(try await client.request("_x.ai/session/state", params: ["sessionId": session, "cwd": project.path]))
            guard let summary = result["summary"] as? [String: Any] else { throw DesktopError.message("The harness did not return the saved session metadata.") }
            let home = summary["grok_home"] as? String
                ?? ProcessInfo.processInfo.environment["CROK_HOME"]
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".crok").path
            let cwd = (summary["info"] as? [String: Any])?["cwd"] as? String ?? project.path
            let content = try await Task.detached(priority: .utility) {
                try SavedPlanArtifact.read(home: home, cwd: cwd, sessionID: session)
            }.value
            guard savedPlanRequestID == requestID, state.selectedConversationID == selected.id, self.project?.id == project.id else { return }
            savedPlanContent = content
        } catch {
            guard savedPlanRequestID == requestID, state.selectedConversationID == selected.id, self.project?.id == project.id else { return }
            savedPlanError = error.localizedDescription
        }
    }
}

enum RewindSelection: String, CaseIterable, Identifiable {
    case conversationOnly = "conversation_only"
    case filesOnly = "files_only"
    case all
    var id: String { rawValue }
    var title: String {
        switch self {
        case .conversationOnly: return "Conversation only"
        case .filesOnly: return "Files only"
        case .all: return "Conversation and files"
        }
    }
}

struct RewindPreview: Equatable {
    let pointIndex: Int
    let mode: RewindSelection
    let cleanFiles: [String]
    let conflicts: [String]

    func matches(_ point: RewindCheckpoint, mode: RewindSelection) -> Bool {
        pointIndex == point.promptIndex && self.mode == mode
    }

    var summary: String {
        var sections = ["Restore \(mode.title.lowercased()) to before prompt \(pointIndex + 1)."]
        if mode != .filesOnly { sections.append("Prompts from this point onward will be removed from the conversation.") }
        if mode != .conversationOnly {
            sections.append(cleanFiles.isEmpty ? "No unchanged tracked files would be restored." : "Files to restore:\n" + cleanFiles.joined(separator: "\n"))
        }
        if !conflicts.isEmpty { sections.append("Conflicts — restore is unavailable:\n" + conflicts.joined(separator: "\n")) }
        else { sections.append("The preview is ready. Confirm Restore to apply it.") }
        return sections.joined(separator: "\n\n")
    }

    static func parse(_ value: [String: Any], point: RewindCheckpoint, mode: RewindSelection) throws -> RewindPreview {
        guard value["success"] as? Bool == false,
              value["target_prompt_index"] as? Int == point.promptIndex,
              value["mode"] as? String == mode.rawValue,
              let clean = value["clean_files"] as? [String],
              let conflicts = value["conflicts"] as? [[String: Any]] else {
            throw DesktopError.message("The harness did not return a valid rewind preview.")
        }
        let messages = conflicts.map { conflict in
            (conflict["path"] as? String ?? "Unknown file") + " · " + (conflict["conflict_type"] as? String ?? "conflict").replacingOccurrences(of: "_", with: " ")
        }
        if messages.isEmpty, let error = value["error"] as? String, !error.isEmpty { throw DesktopError.message(error) }
        return RewindPreview(pointIndex: point.promptIndex, mode: mode, cleanFiles: clean, conflicts: messages)
    }
}

struct RewindCheckpoint: Identifiable, Equatable {
    var id: Int { promptIndex }
    let promptIndex: Int
    let createdAt: String
    let snapshotCount: Int
    let hasFileChanges: Bool
    let prompt: String

    static func parse(_ response: [String: Any]) throws -> [RewindCheckpoint] {
        guard let entries = response["rewind_points"] as? [[String: Any]] else { throw DesktopError.message("The harness did not return rewind checkpoints.") }
        var seen: Set<Int> = []
        return entries.compactMap { entry in
            guard let index = entry["prompt_index"] as? Int, index >= 0, seen.insert(index).inserted else { return nil }
            return RewindCheckpoint(promptIndex: index, createdAt: entry["created_at"] as? String ?? "", snapshotCount: entry["num_file_snapshots"] as? Int ?? 0, hasFileChanges: entry["has_file_changes"] as? Bool ?? false, prompt: entry["prompt_preview"] as? String ?? "Prompt \(index + 1)")
        }.sorted { $0.promptIndex > $1.promptIndex }
    }

    static func failureMessage(_ result: [String: Any]) -> String {
        let message = result["error"] as? String ?? "The harness could not restore this checkpoint."
        let conflicts = (result["conflicts"] as? [[String: Any]] ?? []).compactMap { entry -> String? in
            guard let path = entry["path"] as? String else { return nil }
            return path + ((entry["conflict_type"] as? String).map { " (\($0.replacingOccurrences(of: "_", with: " ")))" } ?? "")
        }
        return message + (conflicts.isEmpty ? "" : "\n\nConflicting files:\n" + conflicts.joined(separator: "\n"))
    }
}

enum SavedPlanArtifact {
    static let maximumBytes = 1_048_576

    static func read(home: String, cwd: String, sessionID: String) throws -> String? {
        guard UUID(uuidString: sessionID) != nil else { throw DesktopError.message("The harness returned an invalid session identifier.") }
        let manager = FileManager.default
        let sessions = URL(fileURLWithPath: home).appendingPathComponent("sessions", isDirectory: true)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.~")
        guard let encoded = cwd.addingPercentEncoding(withAllowedCharacters: allowed) else { throw DesktopError.message("The project path could not be resolved.") }
        var candidates: [URL] = []
        if encoded.utf8.count <= 255 { candidates.append(sessions.appendingPathComponent(encoded, isDirectory: true)) }
        // Long-path session directories use a hash plus a .cwd sidecar. Do not
        // reimplement the harness's hash or select another project's directory.
        if candidates.isEmpty || !manager.fileExists(atPath: candidates[0].path) {
            for directory in (try? manager.contentsOfDirectory(at: sessions, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? [] {
                guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                let sidecar = directory.appendingPathComponent(".cwd")
                guard let handle = try? FileHandle(forReadingFrom: sidecar) else { continue }
                let data = try? handle.read(upToCount: 65_536)
                try? handle.close()
                if let data, let path = String(data: data, encoding: .utf8), path.trimmingCharacters(in: .whitespacesAndNewlines) == cwd { candidates.append(directory) }
            }
        }
        for directory in candidates {
            let plan = directory.appendingPathComponent(sessionID, isDirectory: true).appendingPathComponent("plan.md")
            guard manager.fileExists(atPath: plan.path) else { continue }
            let handle = try FileHandle(forReadingFrom: plan)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
            guard data.count <= maximumBytes else { throw DesktopError.message("This saved plan is larger than the 1 MiB preview limit. Open the session's plan.md in an editor.") }
            guard let content = String(data: data, encoding: .utf8) else { throw DesktopError.message("The saved plan is not valid UTF-8 text.") }
            return content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : content
        }
        return nil
    }
}
