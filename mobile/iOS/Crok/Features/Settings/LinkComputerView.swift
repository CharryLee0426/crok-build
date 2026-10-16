import SwiftUI

/// Settings › Link a computer: scan the QR code `crok remote login` prints (or type its code), check which computer
/// asks, then approve or deny it (Telegram's QR login, from the signed-in side).
struct LinkComputerView: View {
    var showsClose = false
    @Environment(CrokEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var camera: CameraAccess = .current
    @State private var manual = ""
    @State private var code: String?
    @State private var scanProblem = false
    @State private var pending: LiveQuery<PendingLoginInfo?>?
    @State private var busy = false
    @State private var linked: ApprovedDevice?
    @State private var denied = false
    @State private var actionError: RelayError?

    var body: some View {
        Form {
            if let linked {
                resultSection(
                    symbol: "checkmark.circle.fill", color: Theme.accent,
                    title: String(localized: "\(linked.name) is linked"),
                    detail: String(localized: "Its sessions show up in Sessions as soon as crok runs there."))
            } else if denied {
                resultSection(
                    symbol: "xmark.circle.fill", color: Theme.danger, title: String(localized: "Sign-in denied"),
                    detail: String(localized: "The computer was not linked."))
            } else if let code {
                reviewSection(code)
            } else {
                scanSection
                manualSection
            }
        }
        .safeAreaInset(edge: .bottom) {
            if linked == nil, !denied, let code, let info = pending?.value ?? nil, info.status == "pending" {
                decisionButtons(code)
            }
        }
        .navigationTitle("Link a computer")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsClose || linked != nil || denied {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task {
            if camera == .notDetermined { camera = await CameraAccess.request() }
        }
        .onDisappear { pending?.stop() }
        .alert(
            "Couldn't do that", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } }),
            presenting: actionError
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { error in
            Text(error.message)
        }
    }

    // MARK: Entering a code

    @ViewBuilder
    private var scanSection: some View {
        Section {
            switch camera {
            case .authorized:
                QRScannerView { payload in
                    if let found = UserCode.fromScan(payload) {
                        review(found)
                    } else {
                        scanProblem = true
                    }
                }
                .frame(height: 280)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(.white.opacity(0.85), lineWidth: 3)
                        .frame(width: 180, height: 180)
                )
                .listRowInsets(EdgeInsets())
            case .denied:
                cameraMessage(
                    String(localized: "Crok can't use the camera. Allow it in Settings to scan, or type the code below."),
                    action: String(localized: "Open Settings")
                ) {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
            case .unavailable:
                cameraMessage(String(localized: "No camera here. Type the code from your computer below."), action: nil) {}
            case .notDetermined:
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 120)
            }
        } header: {
            Text("Scan the QR code")
        } footer: {
            if scanProblem {
                Text("That QR code isn't a Crok sign-in code.")
                    .foregroundStyle(Theme.danger)
            } else {
                Text("On the computer, run crok remote login. It shows a QR code and a code like BCDF-GHJK.")
            }
        }
    }

    private func cameraMessage(_ text: String, action: String?, perform: @escaping () -> Void) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "camera.metering.unknown")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let action {
                Button(action, action: perform)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
    }

    private var manualSection: some View {
        Section {
            HStack {
                TextField(text: $manual, prompt: Text(verbatim: "BCDF-GHJK")) {
                    Text("Code")
                }
                    .font(.system(.title3, design: .monospaced))
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .onSubmit { if let valid = UserCode.normalize(manual) { review(valid) } }
                    .accessibilityIdentifier("manualCodeField")
                Button("Continue") {
                    if let valid = UserCode.normalize(manual) { review(valid) }
                }
                .disabled(UserCode.normalize(manual) == nil)
                .accessibilityIdentifier("manualCodeContinue")
            }
        } header: {
            Text("Or type the code")
        }
    }

    private func review(_ found: String) {
        scanProblem = false
        code = found
        let account = engine.accountAPI
        let query = LiveQuery<PendingLoginInfo?>(engine: engine) { account.pendingLogin(userCode: found) }
        pending?.stop()
        pending = query
        query.start()
    }

    // MARK: Reviewing

    @ViewBuilder
    private func reviewSection(_ code: String) -> some View {
        if let pending, pending.isLoading {
            Section {
                ProgressView().frame(maxWidth: .infinity, minHeight: 100)
            }
        } else if let info = pending?.value ?? nil {
            Section {
                VStack(spacing: 10) {
                    Image(systemName: info.kind == .computer ? "desktopcomputer" : "iphone")
                        .font(.system(size: 40))
                        .foregroundStyle(Theme.accent)
                    Text(info.name)
                        .font(.title3.weight(.semibold))
                    Text("wants to sign in to your Crok account")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                LabeledContent("Code", value: info.userCode)
                LabeledContent("Platform", value: info.platform)
                LabeledContent("App", value: info.client)
                LabeledContent("Asked", value: RelativeTime.ago(Date(milliseconds: info.createdAt), now: Date()))
            } footer: {
                Text("Approve only a sign-in you just started yourself. The computer can then read your sessions and take prompts.")
            }
            if info.status != "pending" {
                Section {
                    Text(Self.statusText(info.status))
                        .foregroundStyle(.secondary)
                    Button("Scan another code") { reset() }
                }
            }
        } else {
            Section {
                Text("No sign-in is waiting for \(code). Check the code on the computer and try again.")
                    .foregroundStyle(.secondary)
                Button("Try another code") { reset() }
            }
        }
    }

    private func decisionButtons(_ code: String) -> some View {
        VStack(spacing: 10) {
            Button {
                Task { await approve(code) }
            } label: {
                HStack(spacing: 8) {
                    if busy { ProgressView().tint(Theme.onAccent) }
                    Text("Approve")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .foregroundStyle(Theme.onAccent)
            .accessibilityIdentifier("approveButton")
            Button(role: .destructive) {
                Task { await deny(code) }
            } label: {
                Text("Deny")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.bordered)
            .tint(Theme.danger)
            .accessibilityIdentifier("denyButton")
        }
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .disabled(busy)
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background(.bar)
    }

    private func resultSection(symbol: String, color: Color, title: String, detail: String) -> some View {
        Section {
            VStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 52))
                    .foregroundStyle(color)
                Text(title)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .accessibilityIdentifier("linkResult")
        }
    }

    static func statusText(_ status: String) -> String {
        switch status {
        case "approved", "consumed": String(localized: "This code was already used.")
        case "denied": String(localized: "This sign-in was denied.")
        case "expired": String(localized: "This code expired. Start the sign-in again on the computer.")
        default: status
        }
    }

    private func reset() {
        pending?.stop()
        pending = nil
        code = nil
        manual = ""
    }

    private func approve(_ code: String) async {
        busy = true
        defer { busy = false }
        do {
            linked = try await engine.accountAPI.approve(userCode: code)
            pending?.stop()
        } catch {
            let relayError = (error as? RelayError) ?? RelayError(.server, error.localizedDescription)
            if relayError.isRevoked { engine.handleRevoked() } else { actionError = relayError }
        }
    }

    private func deny(_ code: String) async {
        busy = true
        defer { busy = false }
        let account = engine.accountAPI
        if let error = await engine.perform({ try await account.deny(userCode: code) }) {
            actionError = error
        } else {
            denied = true
            pending?.stop()
        }
    }
}
