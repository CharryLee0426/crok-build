import AppKit
import AVFoundation
import SwiftUI
import UserNotifications

/// A check that only makes sense for the desktop app: its runtime, sign-in, and permissions.
struct DoctorDesktopCheck: Identifiable, Equatable {
    enum Status: Equatable { case ok, warning, problem, info }

    let id: String
    let title: String
    let value: String
    var detail: String?
    let status: Status
    let symbol: String

    static func collect(binaryPath: String, agentVersion: String?, accounts: [AccountProvider: AccountStatus]) async -> [DoctorDesktopCheck] {
        var checks: [DoctorDesktopCheck] = []
        if FileManager.default.isExecutableFile(atPath: binaryPath) {
            var version = agentVersion
            if version == nil, let output = try? await GrokCLI.run(binaryPath, arguments: ["--version"], timeout: 10), output.status == 0 {
                version = output.text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "grok ", with: "")
            }
            checks.append(DoctorDesktopCheck(id: "runtime", title: "Grok runtime", value: version.map { "Version \($0)" } ?? "Installed",
                                             detail: SessionFormat.abbreviatedPath(binaryPath), status: .ok, symbol: "cpu"))
        } else {
            checks.append(DoctorDesktopCheck(id: "runtime", title: "Grok runtime", value: "Missing",
                                             detail: "Reinstall Grok Desktop, or point GROK_DESKTOP_HARNESS at a grok executable.", status: .problem, symbol: "cpu"))
        }
        checks.append(signIn(accounts))
        checks.append(microphone(AVCaptureDevice.authorizationStatus(for: .audio)))
        checks.append(await notifications())
        return checks
    }

    static func signIn(_ accounts: [AccountProvider: AccountStatus]) -> DoctorDesktopCheck {
        let connected = AccountProvider.allCases.filter { accounts[$0]?.isConnected == true }
        if let first = connected.first {
            let names = connected.map(\.name).joined(separator: ", ")
            return DoctorDesktopCheck(id: "sign-in", title: "Sign-in", value: "Signed in · \(names)", detail: accounts[first]?.identity, status: .ok, symbol: "person.crop.circle.badge.checkmark")
        }
        if accounts.values.contains(where: { $0.state == .expired }) {
            return DoctorDesktopCheck(id: "sign-in", title: "Sign-in", value: "Session expired", detail: "Open Settings and sign in again.", status: .warning, symbol: "person.crop.circle.badge.exclamationmark")
        }
        return DoctorDesktopCheck(id: "sign-in", title: "Sign-in", value: "Not signed in", detail: "Open Settings and sign in to OpenRouter or OpenAI Codex.", status: .problem, symbol: "person.crop.circle.badge.xmark")
    }

    static func microphone(_ status: AVAuthorizationStatus) -> DoctorDesktopCheck {
        switch status {
        case .authorized:
            return DoctorDesktopCheck(id: "microphone", title: "Microphone", value: "Allowed", status: .ok, symbol: "mic")
        case .denied:
            return DoctorDesktopCheck(id: "microphone", title: "Microphone", value: "Denied",
                                      detail: "Allow Grok Desktop in System Settings › Privacy & Security › Microphone to dictate prompts.", status: .problem, symbol: "mic.slash")
        case .restricted:
            return DoctorDesktopCheck(id: "microphone", title: "Microphone", value: "Restricted", detail: "A device policy blocks microphone access.", status: .warning, symbol: "mic.slash")
        default:
            return DoctorDesktopCheck(id: "microphone", title: "Microphone", value: "Not requested yet", detail: "Grok Desktop asks the first time you use voice input.", status: .info, symbol: "mic")
        }
    }

    private static func notifications() async -> DoctorDesktopCheck {
        // The notification center requires an app bundle; the unbundled build (tests, `swift run`) has none.
        guard Bundle.main.bundleURL.pathExtension == "app", Bundle.main.bundleIdentifier != nil else {
            return DoctorDesktopCheck(id: "notifications", title: "Notifications", value: "Unavailable", detail: "Only the installed app can post notifications.", status: .info, symbol: "bell.slash")
        }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return notifications(settings.authorizationStatus)
    }

    static func notifications(_ status: UNAuthorizationStatus) -> DoctorDesktopCheck {
        switch status {
        case .authorized, .provisional:
            return DoctorDesktopCheck(id: "notifications", title: "Notifications", value: "Allowed", status: .ok, symbol: "bell")
        case .denied:
            return DoctorDesktopCheck(id: "notifications", title: "Notifications", value: "Off",
                                      detail: "Turn on notifications for Grok Desktop in System Settings › Notifications to hear when a task needs you.", status: .warning, symbol: "bell.slash")
        default:
            return DoctorDesktopCheck(id: "notifications", title: "Notifications", value: "Not requested yet", status: .info, symbol: "bell")
        }
    }
}

/// A `.command` file that runs one `grok doctor fix` in Terminal, where the fix shows its own
/// preview and asks before changing anything.
enum DoctorTerminalScript {
    static func contents(binary: String, fix: DoctorFixSpec) -> String {
        let quoted = "'" + binary.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return """
        #!/bin/zsh
        # Written by Grok Desktop for /doctor fix \(fix.handle). It removes itself when it starts.
        rm -f -- "$0"
        clear
        print -r -- 'Grok Doctor · \(fix.label)'
        print
        \(quoted) doctor fix \(fix.handle)
        print
        read -rs -k 1 '?Press any key to close this window.'

        """
    }

    static func write(binary: String, fix: DoctorFixSpec) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GrokDesktopDoctor", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent("doctor-fix-\(fix.handle)-\(UUID().uuidString.prefix(8)).command")
        try Data(contents(binary: binary, fix: fix).utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
}

/// `/doctor [fix [name]]`: the terminal's environment report from `grok doctor --json`, desktop
/// checks, and the automatic fixes, which run in Terminal.
struct DoctorSheet: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var sessions: SessionFeatureModel
    let arguments: String

    var body: some View {
        let request = (try? DoctorRequest.parse(arguments)) ?? .report
        DesktopPanel(title: "Doctor", subtitle: "Check this environment and see available fixes.", width: 740, height: 680, onClose: close) {
            ScrollView {
                DoctorReportView(request: request, report: sessions.doctorReport, checks: sessions.desktopChecks,
                                 loading: sessions.doctorLoading, error: sessions.doctorError,
                                 runFix: sessions.runFixInTerminal, retry: { Task { await sessions.runDoctor() } })
                    .padding(24)
            }
        } footer: {
            Text(summary).font(.system(size: 12)).foregroundStyle(Theme.muted)
            Spacer(minLength: 0)
            Button("Check again") { Task { await sessions.runDoctor() } }.disabled(sessions.doctorLoading)
            Button("Done", action: close).keyboardShortcut(.defaultAction)
        }
        .task { await sessions.runDoctor() }
    }

    private var summary: String {
        if sessions.doctorLoading { return "Checking…" }
        guard let report = sessions.doctorReport else { return "" }
        let issues = report.issueCount, recommendations = report.recommendationCount
        if issues + recommendations == 0 { return "No issues found" }
        return "\(issues) issue\(issues == 1 ? "" : "s") · \(recommendations) recommendation\(recommendations == 1 ? "" : "s")"
    }

    private func close() { store.sheet = nil }
}

/// The report body, separate from the model so it renders from plain values.
struct DoctorReportView: View {
    let request: DoctorRequest
    let report: DoctorReport?
    let checks: [DoctorDesktopCheck]
    let loading: Bool
    let error: String?
    let runFix: (DoctorFixSpec) -> Void
    let retry: () -> Void
    @State private var expandedGroups: Set<String> = []

    private var highlightedFix: DoctorFixSpec? { if case .fix(let spec) = request { return spec }; return nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if request != .report { fixes }
            if !checks.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    SessionSectionTitle(title: "Grok Desktop", symbol: "macwindow")
                    VStack(spacing: 0) {
                        ForEach(Array(checks.enumerated()), id: \.element.id) { index, check in
                            if index > 0 { Divider().padding(.leading, 44) }
                            checkRow(check)
                        }
                    }.sessionCard(padding: 4)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                SessionSectionTitle(title: "Findings", count: report.map { $0.allFindings.count }, symbol: "stethoscope")
                if loading && report == nil {
                    HStack(spacing: 10) { ProgressView().controlSize(.small); Text("Checking your environment…").foregroundStyle(Theme.muted) }
                        .font(.system(size: 13)).frame(maxWidth: .infinity).padding(24)
                } else if let error {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                        Text("grok doctor could not run: \(error)").textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button("Retry", action: retry).buttonStyle(SubtleButtonStyle())
                    }.font(.system(size: 13)).sessionCard()
                } else if let report, report.allFindings.isEmpty {
                    Label("No issues found.", systemImage: "checkmark.circle").font(.system(size: 13)).foregroundStyle(Theme.green)
                        .frame(maxWidth: .infinity, alignment: .leading).sessionCard()
                } else if let report {
                    ForEach(report.allFindings) { finding(for: $0) }
                }
            }
            if let report, !report.factGroups.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    SessionSectionTitle(title: "Environment", symbol: "list.bullet.rectangle")
                    Text("Terminal facts describe where Grok Desktop runs. Run grok doctor in your terminal to check that terminal.")
                        .font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                    VStack(spacing: 0) {
                        ForEach(Array(report.factGroups.enumerated()), id: \.offset) { index, group in
                            if index > 0 { Divider().padding(.horizontal, 12) }
                            FoldableSection(isExpanded: Binding(get: { expandedGroups.contains(group.title) },
                                                                set: { if $0 { expandedGroups.insert(group.title) } else { expandedGroups.remove(group.title) } })) {
                                Label(group.title, systemImage: group.symbol).font(.system(size: 13, weight: .medium))
                            } content: {
                                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                                    ForEach(Array(group.rows.enumerated()), id: \.offset) { _, row in
                                        GridRow {
                                            Text(row.0).foregroundStyle(Theme.muted).gridColumnAlignment(.trailing)
                                            Text(row.1).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                        }
                                    }
                                }.font(.system(size: 12)).padding(.leading, 44).padding(.trailing, 12).padding(.bottom, 12)
                            }
                        }
                    }.sessionCard(padding: 4)
                }
            }
        }
    }

    private var fixes: some View {
        let recommended = Set((report?.allFindings ?? []).compactMap { $0.automaticFix?.handle })
        return VStack(alignment: .leading, spacing: 8) {
            SessionSectionTitle(title: "Automatic fixes", symbol: "wrench.and.screwdriver")
            Text("Each fix changes your terminal or shell configuration. It opens in Terminal, shows the change, and asks before applying it.")
                .font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            ForEach(DoctorFixSpec.registry) { fix in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(fix.label).font(.system(size: 13, weight: .semibold))
                            if recommended.contains(fix.handle) { SessionStatusPill(text: "Recommended here", tone: .accent) }
                        }
                        Text(fix.command).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.muted).textSelection(.enabled)
                    }
                    Spacer(minLength: 8)
                    Button("Run in Terminal") { runFix(fix) }.buttonStyle(SubtleButtonStyle()).font(.system(size: 12, weight: .medium))
                }
                .sessionCard(highlighted: fix == highlightedFix, padding: 12)
            }
        }
    }

    private func checkRow(_ check: DoctorDesktopCheck) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: check.symbol).font(.system(size: 14)).foregroundStyle(Theme.muted).frame(width: 20).padding(.top, 1).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(check.title).font(.system(size: 13, weight: .medium))
                    Spacer(minLength: 8)
                    Text(check.value).font(.system(size: 12)).foregroundStyle(tone(check.status).color == Theme.muted ? Theme.muted : Theme.ink)
                    Image(systemName: statusSymbol(check.status)).font(.system(size: 12)).foregroundStyle(tone(check.status).color)
                        .accessibilityLabel(statusLabel(check.status))
                }
                if let detail = check.detail {
                    Text(detail).font(.system(size: 11)).foregroundStyle(Theme.muted).textSelection(.enabled).lineLimit(3)
                }
            }
        }.padding(.horizontal, 12).padding(.vertical, 10)
    }

    private func finding(for finding: DoctorReport.Finding) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                SessionStatusPill(text: finding.isIssue ? "Issue" : "Recommendation", tone: finding.isIssue ? .orange : .accent)
                Text(DoctorReport.humanize(finding.area)).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.muted)
                Spacer(minLength: 8)
                Text(finding.id).font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.muted).textSelection(.enabled)
            }
            if let message = finding.message { Text(message).font(.system(size: 13, weight: .medium)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled) }
            if let note = finding.note { Text(note).font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true).textSelection(.enabled) }
            if let remediation = finding.remediation, let fix = remediation.fix, !fix.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(remediation.configPath.map { "Add to \(SessionFormat.abbreviatedPath($0))" } ?? "Fix").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.muted)
                    Text(fix).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.codeBackground, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            if let fix = finding.automaticFix {
                HStack(spacing: 10) {
                    Image(systemName: "wand.and.stars").foregroundStyle(Theme.accent).accessibilityHidden(true)
                    Text(fix.command).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    Spacer(minLength: 8)
                    Button("Run in Terminal") { runFix(fix) }.buttonStyle(SubtleButtonStyle()).font(.system(size: 12, weight: .medium))
                }
            }
        }
        .sessionCard(highlighted: finding.automaticFix != nil && finding.automaticFix == highlightedFix)
    }

    private func tone(_ status: DoctorDesktopCheck.Status) -> SessionTone {
        switch status {
        case .ok: return .green
        case .warning: return .orange
        case .problem: return .red
        case .info: return .muted
        }
    }

    private func statusSymbol(_ status: DoctorDesktopCheck.Status) -> String {
        switch status {
        case .ok: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .problem: return "xmark.octagon.fill"
        case .info: return "info.circle"
        }
    }

    private func statusLabel(_ status: DoctorDesktopCheck.Status) -> String {
        switch status {
        case .ok: return "OK"
        case .warning: return "Warning"
        case .problem: return "Problem"
        case .info: return "Information"
        }
    }
}
