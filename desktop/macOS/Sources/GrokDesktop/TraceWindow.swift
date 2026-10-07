import SwiftUI
import WebKit

/// What the trace window shows for the selected task.
enum TraceViewState: Equatable {
    case idle
    /// "No active session to trace" or "This session has not been recorded yet".
    case unavailable(String)
    case loading(directory: String)
    case loaded(file: URL, directory: String, sessionID: String)
    case failed(directory: String, error: String)
}

/// `/trace`: the terminal's trace explorer, exported by `crok trace view --format html` and shown
/// in a web view. It follows the selected task while the window is open.
struct TraceWindow: View {
    @EnvironmentObject var sessions: SessionFeatureModel

    var body: some View {
        TraceWindowContent(state: sessions.trace, title: sessions.traceTitle, revision: sessions.traceRevision,
                           reload: { Task { await sessions.loadTrace() } },
                           openInBrowser: sessions.openTraceInBrowser, save: sessions.saveTrace)
            .onAppear { sessions.traceWindowAppeared() }
            .onDisappear { sessions.traceWindowDisappeared() }
    }
}

/// The window's layout, separate from the model so its states can be rendered on their own.
struct TraceWindowContent: View {
    let state: TraceViewState
    let title: String
    let revision: Int
    let reload: () -> Void
    let openInBrowser: () -> Void
    let save: () -> Void

    private var isLoaded: Bool { if case .loaded = state { return true }; return false }
    private var isLoading: Bool { if case .loading = state { return true }; return false }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "waveform.path.ecg").font(.system(size: 17, weight: .medium)).foregroundStyle(Theme.accent).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Trace").font(.system(size: 15, weight: .semibold))
                    Text(title.isEmpty ? "No task selected" : title).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 12)
                IconButton(icon: "arrow.clockwise", help: "Reload trace", action: reload)
                    .disabled(isLoading || state == .idle).opacity(isLoading || state == .idle ? 0.4 : 1)
                    .keyboardShortcut("r", modifiers: .command)
                IconButton(icon: "safari", help: "Open in browser", action: openInBrowser)
                    .disabled(!isLoaded).opacity(isLoaded ? 1 : 0.4)
                IconButton(icon: "square.and.arrow.down", help: "Save As…", action: save)
                    .disabled(!isLoaded).opacity(isLoaded ? 1 : 0.4)
                    .keyboardShortcut("s", modifiers: .command)
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
            .background(Theme.surface)
            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 720, minHeight: 480)
        .glassWindowBackground()
    }

    @ViewBuilder private var content: some View {
        switch state {
        case .idle:
            Color.clear
        case .unavailable(let message):
            SessionEmptyState(symbol: "waveform.path.ecg", title: message, detail: "Traces are recorded as Crok works in a task.")
        case .loading(let directory):
            VStack(spacing: 14) {
                ProgressView().controlSize(.regular)
                Text("Reading the session trace…").font(.system(size: 14, weight: .medium))
                Text(SessionFormat.abbreviatedPath(directory)).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.muted)
                    .textSelection(.enabled).multilineTextAlignment(.center)
            }.padding(40)
        case .failed(let directory, let error):
            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 26)).foregroundStyle(.orange).accessibilityHidden(true)
                Text("Could not read the trace for this session.").font(.system(size: 14, weight: .medium))
                Text(SessionFormat.abbreviatedPath(directory)).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.muted).textSelection(.enabled)
                Text(error).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    .padding(12).frame(maxWidth: 560, alignment: .leading)
                    .background(Theme.codeBackground, in: RoundedRectangle(cornerRadius: 8))
                Button("Try again", action: reload).buttonStyle(SubtleButtonStyle()).font(.system(size: 13, weight: .medium))
            }.padding(40)
        case .loaded(let file, _, _):
            TraceWebView(file: file, revision: revision)
        }
    }
}

/// Shows the exported, self-contained trace page. It reads only its own folder.
struct TraceWebView: NSViewRepresentable {
    let file: URL
    let revision: Int

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        guard context.coordinator.loaded != file || context.coordinator.revision != revision else { return }
        context.coordinator.loaded = file
        context.coordinator.revision = revision
        view.loadFileURL(file, allowingReadAccessTo: file.deletingLastPathComponent())
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loaded: URL?
        var revision = -1

        /// Links in the page (documentation, source URLs) open in the browser, not in the trace window.
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url, !url.isFileURL {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }
    }
}
