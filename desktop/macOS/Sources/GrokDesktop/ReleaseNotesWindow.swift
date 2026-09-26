import SwiftUI

enum ReleaseNotesSource: Equatable {
    case remote, cache
}

struct ReleaseNotesState: Equatable {
    var version: String?
    var markdown: String?
    var source: ReleaseNotesSource?
    var isLoading = false
    /// Shown instead of notes, e.g. "No release notes available (offline)."
    var message: String?
}

/// Release notes are published per version at `x.ai/cli/changelogs/<VERSION>.external.md`, and
/// `$GROK_HOME/CHANGELOG.md` holds the last copy the terminal or Grok Desktop downloaded.
enum ReleaseNotesLoader {
    static let base = "https://x.ai/cli/changelogs"
    static let timeout: TimeInterval = 3

    static func url(version: String) -> URL? {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-+_")
        guard !version.isEmpty, version.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return URL(string: "\(base)/\(version).external.md")
    }

    static func cacheFile(home: URL) -> URL { home.appendingPathComponent("CHANGELOG.md") }

    /// The CDN copy when it arrives in time (and it refreshes the cache), else the cached copy.
    /// `GROK_CHANGELOG_OFFLINE` skips the network, as it does for the terminal.
    static func load(version: String?, home: URL, environment: [String: String] = ProcessInfo.processInfo.environment,
                     download: (URL, TimeInterval) async -> String?) async -> (markdown: String, source: ReleaseNotesSource)? {
        let offline = environment["CROK_CHANGELOG_OFFLINE"].map { !$0.isEmpty && $0 != "0" } ?? false
        if !offline, let version, let url = url(version: version),
           let text = await download(url, timeout), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let cache = cacheFile(home: home)
            await Task.detached(priority: .utility) {
                try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
                try? Data(text.utf8).write(to: cache, options: .atomic)
            }.value
            return (text.trimmingCharacters(in: .whitespacesAndNewlines), .remote)
        }
        let cached = await Task.detached(priority: .utility) { () -> String? in
            guard let data = try? Data(contentsOf: cacheFile(home: home)), data.count <= 4 * 1024 * 1024 else { return nil }
            return String(data: data, encoding: .utf8)
        }.value
        guard let cached, !cached.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return (cached.trimmingCharacters(in: .whitespacesAndNewlines), .cache)
    }

    /// An unauthenticated GET that gives up after `timeout`, like the terminal's.
    static func download(_ url: URL, timeout: TimeInterval) async -> String? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        guard let (data, response) = try? await session.data(from: url),
              let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// The runtime's version from `grok version --json` (`{"currentVersion": "1.0.41 (abc123)"}`).
    static func cliVersion(binary: String) async -> String? {
        guard let output = try? await GrokCLI.run(binary, arguments: ["version", "--json"], timeout: 10), output.status == 0 else { return nil }
        return parseVersion(output.stdout)
    }

    static func parseVersion(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let current = object["currentVersion"] as? String else { return nil }
        return current.split(separator: " ").first.map(String.init)
    }
}

/// `/release-notes`: what's new in the runtime's version, in a window of its own.
struct ReleaseNotesWindow: View {
    var loadsOnAppear = true
    @EnvironmentObject var account: AccountFeatureModel

    private var state: ReleaseNotesState { account.releaseNotes }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: "sparkles").font(.system(size: 20, weight: .medium)).foregroundStyle(Theme.accent)
                    .frame(width: 40, height: 40).background(Theme.hover.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Release Notes").font(.system(size: 21, weight: .semibold))
                    Text(subtitle).font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                }
                Spacer()
                if state.isLoading { ProgressView().controlSize(.small) }
                Button { account.loadReleaseNotes() } label: { Label("Reload", systemImage: "arrow.clockwise") }
                    .buttonStyle(SubtleButtonStyle()).font(.system(size: 12.5, weight: .medium))
                    .disabled(state.isLoading).keyboardShortcut("r")
            }
            .padding(.horizontal, 28).padding(.vertical, 18)
            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 560, minHeight: 440)
        .glassWindowBackground()
        .task { if loadsOnAppear && state.markdown == nil && !state.isLoading { account.loadReleaseNotes() } }
    }

    private var subtitle: String {
        var parts = [state.version.map { "Crok Build \($0)" } ?? "Crok Build"]
        switch state.source {
        case .remote: parts.append("from x.ai")
        case .cache: parts.append("saved copy — couldn't reach x.ai")
        case nil: break
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var content: some View {
        if let markdown = state.markdown {
            ScrollView {
                MarkdownContent(text: markdown, style: .panel)
                    .frame(maxWidth: 720, alignment: .leading)
                    .padding(.horizontal, 36).padding(.vertical, 28)
                    .frame(maxWidth: .infinity)
            }
        } else if let message = state.message {
            VStack(spacing: 12) {
                Image(systemName: "wifi.slash").font(.system(size: 30, weight: .light)).foregroundStyle(Theme.muted)
                Text(message).font(.system(size: 15, weight: .semibold))
                Text("Release notes download from x.ai. Check your connection, then reload.")
                    .font(.system(size: 13)).foregroundStyle(Theme.muted)
                Button("Reload") { account.loadReleaseNotes() }.buttonStyle(SubtleButtonStyle()).padding(.top, 4)
            }
            .padding(40)
        } else {
            ProgressView("Loading release notes…").controlSize(.small)
        }
    }
}
