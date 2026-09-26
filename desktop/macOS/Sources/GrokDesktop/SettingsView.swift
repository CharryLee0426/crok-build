import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var accounts = AccountStore()
    @State private var signingIn: AccountProvider?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                GrokMark(size: 36)
                Text("Settings").font(.system(size: 24, weight: .semibold))
                Spacer()
                IconButton(icon: "xmark", help: "Close settings") { dismiss() }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    AppearanceSettingsSection().settingsCard()

                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Label("Accounts", systemImage: "person.crop.circle")
                                .font(.system(size: 15, weight: .semibold))
                            Spacer()
                            IconButton(icon: "arrow.clockwise", help: "Refresh accounts") { accounts.refresh() }
                        }
                        VStack(spacing: 0) {
                            ForEach(AccountProvider.allCases) { provider in
                                if provider != AccountProvider.allCases.first { Divider().padding(.leading, 46) }
                                accountRow(provider)
                            }
                        }
                        if store.loginRunning {
                            HStack(spacing: 9) {
                                ProgressView().controlSize(.small)
                                Text("Complete sign-in in your browser…")
                                    .font(.system(size: 13)).foregroundStyle(Theme.muted)
                                Spacer()
                                Button("Cancel") { store.cancelLogin() }
                            }
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
                    DisplaySettingsSection()
                    BehaviorSettingsSection()
                    CommandLineSettingsSection()
                }
                .padding(3)
            }
            .scrollIndicators(.hidden)
            .frame(maxHeight: .infinity)

            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "lock.shield")
                Text("Most settings are shared with the Grok CLI. Tasks stay on this Mac.")
                    .lineSpacing(3)
            }
            .font(.system(size: 13)).foregroundStyle(Theme.muted)

            HStack {
                Text("Grok Desktop · \(DesktopVersion.current)").font(.system(size: 12)).foregroundStyle(Theme.muted)
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 660, height: 680)
        .foregroundStyle(Theme.ink)
        .glassSheetBackground()
        .onAppear { accounts.refresh() }
        .onChange(of: store.loginRunning) { _, running in
            accounts.refresh()
            if !running { signingIn = nil }
        }
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
                Label("Connected", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.green)
                    .fixedSize()
            } else {
                Button(signingIn == provider && store.loginRunning ? "Signing in…" : "Sign in") {
                    signingIn = provider
                    if !accounts.signIn(provider: provider, loginRunning: store.loginRunning, perform: store.login) {
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
}

extension View {
    /// The rounded glass card that holds one group of settings.
    func settingsCard() -> some View {
        padding(18).frame(maxWidth: .infinity, alignment: .leading).glassSurface(cornerRadius: 18)
    }
}
