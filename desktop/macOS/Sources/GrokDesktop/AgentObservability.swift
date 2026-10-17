import AppKit
import SwiftUI

/// Grafana Agent Observability: the switch (`[features] agent_observability` in config.toml, shared
/// with the terminal) and where reports go (`agento11y.env` in Crok's home). Every Crok process follows
/// both files while it runs, each task's `crok agent stdio` included, so a change applies to open tasks.
@MainActor
final class AgentObservabilitySettings: ObservableObject {
    /// Tests that open Settings read and write a home of their own, never the user's.
    static let shared = AgentObservabilitySettings(home: NSClassFromString("XCTestCase") == nil ? GrokPaths.home
        : FileManager.default.temporaryDirectory.appendingPathComponent("crok-observability-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true))

    /// The key under `[features]`; off when config.toml says nothing.
    static let featureKey = "agent_observability"

    /// Where reports go, as the settings file says; only the endpoint's host, never a credential.
    enum Destination: Equatable {
        case notSetUp
        case host(String)
        /// The file names a host but also says `AGENTO11Y_ENABLED=false`.
        case disabledInFile(host: String)
    }

    @Published private(set) var isOn = false
    @Published private(set) var destination = Destination.notSetUp

    let home: URL
    var configURL: URL { home.appendingPathComponent("config.toml") }
    var settingsFile: URL { home.appendingPathComponent("agento11y.env") }
    var logFile: URL { home.appendingPathComponent("logs").appendingPathComponent("agento11y.log") }
    /// `~/.crok/agento11y.env`, as the section names it.
    var settingsFileName: String { (settingsFile.path as NSString).abbreviatingWithTildeInPath }

    init(home: URL) {
        self.home = home
        refresh()
    }

    /// Reads the switch from config.toml and the destination from the settings file.
    func refresh() {
        apply(GrokConfig(url: configURL))
        let text = try? String(contentsOf: settingsFile, encoding: .utf8)
        let found = Self.destination(settingsFile: text, environment: ProcessInfo.processInfo.environment)
        if found != destination { destination = found }
    }

    /// The switch as a config.toml says it; the watcher calls this when the terminal changes it.
    func apply(_ config: GrokConfig) {
        let on = config.bool(Self.featureKey, in: "features") ?? false
        if on != isOn { isOn = on }
    }

    /// Saves the switch; returns the banner that says what happened and where reports now go.
    @discardableResult
    func set(_ on: Bool) -> String {
        do {
            try GrokConfig.update(url: configURL) { try $0.set(Self.featureKey, to: .bool(on), in: "features") }
        } catch {
            refresh()
            return L10n.t("device_save_failed", "Could not save [features].{key}: {error}", ["key": Self.featureKey, "error": error.localizedDescription])
        }
        isOn = on
        refresh()
        let state = L10n.onOff(on)
        guard on else { return L10n.t("observability_banner", "✓ Agent Observability: {state}", ["state": state]) }
        if case .host(let host) = destination {
            return L10n.t("observability_banner_reporting", "✓ Agent Observability: {state} · reporting to {host}", ["state": state, "host": host])
        }
        return L10n.t("observability_banner_not_set_up", "✓ Agent Observability: {state} · nothing is sent until {file} is set up",
                      ["state": state, "file": settingsFileName])
    }

    /// What crok reads from the file (or, with no file, from the environment it inherits): the
    /// endpoint, and the `AGENTO11Y_ENABLED` kill switch. The same dotenv subset crok parses.
    nonisolated static func destination(settingsFile text: String?, environment: [String: String]) -> Destination {
        let values = text.map(parse) ?? environment
        guard let endpoint = values["AGENTO11Y_ENDPOINT"], !endpoint.isEmpty else { return .notSetUp }
        let host = host(of: endpoint)
        let off = ["0", "false", "no", "off"].contains(values["AGENTO11Y_ENABLED"]?.lowercased() ?? "")
        return off ? .disabledInFile(host: host) : .host(host)
    }

    /// `KEY=value` lines, `#` comments, an optional `export`, and single or double quotes.
    nonisolated static func parse(_ text: String) -> [String: String] {
        var values: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if line.hasPrefix("export ") { line.removeFirst("export ".count) }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, key.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) else { continue }
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let quote = value.first, quote == "\"" || quote == "'", value.last == quote {
                value = String(value.dropFirst().dropLast())
            } else if let comment = value.range(of: " #") {
                value = value[..<comment.lowerBound].trimmingCharacters(in: .whitespaces)
            }
            values[key] = value
        }
        return values
    }

    /// `https://user:pass@host:443/path` → `host:443`.
    nonisolated static func host(of endpoint: String) -> String {
        var rest = Substring(endpoint)
        if let scheme = rest.range(of: "://") { rest = rest[scheme.upperBound...] }
        let authority = rest.prefix { !"/?#".contains($0) }
        if let at = authority.lastIndex(of: "@") { return String(authority[authority.index(after: at)...]) }
        return String(authority)
    }
}

/// Settings › Agent Observability: the switch, and where reports go.
struct AgentObservabilitySettingsSection: View {
    @ObservedObject private var language = L10n.state
    @EnvironmentObject var store: AppStore
    @ObservedObject private var model: AgentObservabilitySettings

    /// Tests pass a `model` reading a home of their own.
    @MainActor
    init(model: AgentObservabilitySettings? = nil) {
        _model = ObservedObject(wrappedValue: model ?? .shared)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(L10n.t("observability_settings_title", "Agent Observability"), systemImage: "chart.xyaxis.line").font(.system(size: 15, weight: .semibold))
            row(L10n.t("observability_report", "Report model calls"),
                detail: L10n.t("observability_detail", "Sends each model call (prompt, reply, tool calls, tokens, timing) from Crok Desktop and the terminal to your Grafana Agent Observability stack. Applies right away, to open tasks too.")) {
                Toggle(L10n.t("observability_report", "Report model calls"), isOn: binding).labelsHidden().toggleStyle(.switch)
            }
            Divider()
            row(L10n.t("observability_destination", "Destination"), detail: destinationDetail) {
                HStack(spacing: 8) {
                    if FileManager.default.fileExists(atPath: model.logFile.path) {
                        Button(L10n.t("observability_open_log", "Open Log")) { NSWorkspace.shared.open(model.logFile) }
                            .buttonStyle(.bordered)
                    }
                    if FileManager.default.fileExists(atPath: model.settingsFile.path) {
                        Button(L10n.t("show_in_finder", "Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([model.settingsFile]) }
                            .buttonStyle(.bordered)
                    }
                }
            }
        }
        .settingsCard()
        .onAppear { model.refresh() }
        // Back from writing the settings file in a terminal.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refresh() }
    }

    private var binding: Binding<Bool> {
        Binding(get: { model.isOn }, set: { store.banner = model.set($0) })
    }

    private var destinationDetail: String {
        let file = model.settingsFileName
        switch model.destination {
        case .host(let host):
            return L10n.t("observability_destination_host", "{host}, set in {file}.", ["host": host, "file": file])
        case .disabledInFile(let host):
            return L10n.t("observability_destination_disabled", "{host}, but {file} turns sending off (AGENTO11Y_ENABLED=false).", ["host": host, "file": file])
        case .notSetUp:
            return L10n.t("observability_destination_missing", "Not set up: nothing is sent until {file} holds your Grafana stack's endpoint and token. The agento11y setup.sh in the crok repository writes it.", ["file": file])
        }
    }

    private func row<Control: View>(_ title: String, detail: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 14, weight: .medium))
                Text(detail).font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            control()
        }
    }
}
