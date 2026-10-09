import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                GrokMark(size: 36)
                Text(L10n.t("settings", "Settings")).font(.system(size: 24, weight: .semibold))
                Spacer()
                IconButton(icon: "xmark", help: "Close settings") { dismiss() }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    AppearanceSettingsSection().settingsCard()
                    AccountsSettingsSection()
                    DisplaySettingsSection()
                    BehaviorSettingsSection()
                    BrowserSettingsSection()
                    CommandLineSettingsSection()
                    if PerformanceMonitorSettings.isAvailable { DeveloperSettingsSection() }
                }
                .padding(3)
            }
            .scrollIndicators(.hidden)
            .frame(maxHeight: .infinity)

            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "lock.shield")
                Text(L10n.t("most_settings_shared", "Most settings are shared with the Crok CLI. Tasks stay on this Mac."))
                    .lineSpacing(3)
            }
            .font(.system(size: 13)).foregroundStyle(Theme.muted)

            HStack {
                Text("Crok Desktop · \(DesktopVersion.current)").font(.system(size: 12)).foregroundStyle(Theme.muted)
                Spacer()
                Button(L10n.t("done", "Done")) { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 660, height: 680)
        .foregroundStyle(Theme.ink)
        .glassSheetBackground()
    }
}

/// The model providers in Settings: browser sign-in for OpenRouter and OpenAI Codex, and a pasted
/// API key for DeepSeek, the GLM Coding Plan and the Claude API. Sign-ins are shared with the CLI.
struct AccountsSettingsSection: View {
    @EnvironmentObject var store: AppStore
    @StateObject private var accounts: AccountStore
    @State private var signingIn: AccountProvider?
    /// The provider whose API key form is open, the key being typed, and which of its sites issued it.
    @State private var keyEntry: AccountProvider?
    @State private var keyDraft = ""
    @State private var keySourceID: String
    @FocusState private var keyFieldFocused: Bool

    /// Tests pass their own `accounts`, and `keyEntry` to open that provider's key form from the start.
    @MainActor
    init(accounts: AccountStore? = nil, keyEntry: AccountProvider? = nil) {
        _accounts = StateObject(wrappedValue: accounts ?? AccountStore())
        _keyEntry = State(initialValue: keyEntry)
        _keySourceID = State(initialValue: keyEntry?.keySources.first?.id ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(L10n.t("accounts", "Accounts"), systemImage: "person.crop.circle")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                IconButton(icon: "arrow.clockwise", help: "Refresh accounts") { accounts.refresh() }
            }
            VStack(spacing: 0) {
                ForEach(AccountProvider.allCases) { provider in
                    if provider != AccountProvider.allCases.first { Divider().padding(.leading, 46) }
                    accountRow(provider)
                    if keyEntry == provider { keyForm(provider) }
                }
            }
            if store.loginRunning {
                HStack(spacing: 9) {
                    ProgressView().controlSize(.small)
                    Text(store.loginUsesKey ? "Checking the API key…" : "Complete sign-in in your browser…")
                        .font(.system(size: 13)).foregroundStyle(Theme.muted)
                    Spacer()
                    Button("Cancel") { store.cancelLogin() }
                }
            } else if let failure = store.loginFailure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 13)).foregroundStyle(Theme.red)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            if !store.loginLog.isEmpty {
                DisclosureGroup("Sign-in details") {
                    ScrollView {
                        Text(store.loginLog)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 90)
                    .padding(10)
                    .background(Theme.sidebar.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                }
                .font(.system(size: 13))
            }
        }
        .padding(18)
        .glassSurface(cornerRadius: 18)
        .onAppear { accounts.refresh() }
        // A reason shown once is not shown again the next time Settings opens.
        .onDisappear { store.loginFailure = nil }
        .onChange(of: store.loginRunning) { _, running in
            accounts.refresh()
            guard !running else { return }
            signingIn = nil
            // A saved key closes its form; a refused one stays so it can be corrected.
            if let provider = keyEntry, accounts.status(for: provider).isConnected { closeKeyForm() }
        }
        .onChange(of: store.accountsChanged) { _, _ in accounts.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in accounts.refresh() }
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in accounts.refresh() }
    }

    private func accountRow(_ provider: AccountProvider) -> some View {
        let status = accounts.status(for: provider)
        return HStack(spacing: 12) {
            Image(systemName: status.isConnected ? "person.crop.circle.badge.checkmark" : "person.crop.circle")
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(status.isConnected ? Theme.green : Theme.muted)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 4) {
                Text(provider.name).font(.system(size: 14, weight: .semibold))
                if let identity = status.identity {
                    Text(identity).font(.system(size: 14)).textSelection(.enabled)
                        .lineLimit(1).truncationMode(.middle).help(identity)
                }
                Text(status.detail).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if status.isConnected {
                Label(L10n.t("connected", "Connected"), systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.green)
                    .fixedSize()
                // A key from the environment is not Crok Desktop's to remove.
                if let saved = status.savedAs {
                    let title = provider.signsInWithKey ? "Remove Key" : "Sign Out"
                    Menu {
                        Button(title, role: .destructive) { store.logout(provider: saved) }
                    } label: {
                        Image(systemName: "ellipsis.circle").font(.system(size: 15))
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .foregroundStyle(Theme.muted)
                    .disabled(store.loginRunning)
                    .help("\(title) for \(provider.name)")
                    .accessibilityLabel("\(provider.name) account options")
                }
            } else if provider.signsInWithKey {
                Button(keyEntry == provider ? "Cancel" : "Add Key…") {
                    if keyEntry == provider { closeKeyForm() } else { openKeyForm(provider) }
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(store.loginRunning)
                .accessibilityLabel(keyEntry == provider ? "Cancel adding a key for \(provider.name)" : "Add an API key for \(provider.name)")
            } else {
                Button(signingIn == provider && store.loginRunning ? "Signing in…" : "Sign in") {
                    signingIn = provider
                    closeKeyForm()
                    if !accounts.signIn(provider: provider, loginRunning: store.loginRunning, perform: { store.login(provider: $0) }) {
                        signingIn = nil
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(store.loginRunning)
                .accessibilityLabel("Sign in to \(provider.name)")
            }
        }
        .padding(.vertical, 10)
    }

    /// Where a key provider's key is pasted. It sits under the provider's row, indented to its text.
    private func keyForm(_ provider: AccountProvider) -> some View {
        let sources = provider.keySources
        let source = sources.first { $0.id == keySourceID } ?? sources.first
        return VStack(alignment: .leading, spacing: 10) {
            if sources.count > 1 {
                HStack(spacing: 10) {
                    Text("Subscribed on").font(.system(size: 13)).foregroundStyle(Theme.muted)
                    Picker("Subscribed on", selection: $keySourceID) {
                        ForEach(sources) { Text("\($0.title) · \($0.site)").tag($0.id) }
                    }
                    .labelsHidden().pickerStyle(.segmented).fixedSize()
                    .disabled(store.loginRunning)
                }
            }
            HStack(spacing: 8) {
                SecureField("Paste your API key", text: $keyDraft)
                    .textFieldStyle(.roundedBorder)
                    .focused($keyFieldFocused)
                    .disabled(store.loginRunning)
                    .onSubmit { saveKey(provider) }
                    .accessibilityLabel("\(provider.name) API key")
                Button(L10n.t("save", "Save")) { saveKey(provider) }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.loginRunning || keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let source, let page = URL(string: source.keyPage) {
                HStack(spacing: 4) {
                    Text("Create a key at")
                    Link(source.site, destination: page).foregroundStyle(Theme.accent).underline()
                    Text("· Saved on this Mac for Crok Desktop and the CLI.")
                }
                .font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
        }
        .padding(.leading, 46).padding(.bottom, 12)
    }

    private func openKeyForm(_ provider: AccountProvider) {
        store.loginFailure = nil
        keyDraft = ""
        keySourceID = provider.keySources.first?.id ?? ""
        keyEntry = provider
        keyFieldFocused = true
    }

    private func closeKeyForm() {
        keyEntry = nil
        keyDraft = ""
    }

    private func saveKey(_ provider: AccountProvider) {
        guard let source = provider.keySources.first(where: { $0.id == keySourceID }) ?? provider.keySources.first else { return }
        let started = accounts.addKey(keyDraft, provider: provider, source: source, loginRunning: store.loginRunning) { name, key in
            store.login(provider: name, apiKey: key)
        }
        // Already connected (a key saved from the terminal meanwhile): nothing to add.
        if !started, accounts.status(for: provider).isConnected { closeKeyForm() }
    }
}

extension View {
    /// The rounded glass card that holds one group of settings.
    func settingsCard() -> some View {
        padding(18).frame(maxWidth: .infinity, alignment: .leading).glassSurface(cornerRadius: 18)
    }
}
