import AppKit
import SwiftUI

/// Settings › Remote control: signs this Mac in to the relay so the Crok app on a phone, or the web,
/// can follow and steer its tasks. It is apart from the model providers under Accounts.
struct RemoteControlSettingsSection: View {
    @EnvironmentObject var store: AppStore
    /// Tests pass a model with a home of their own.
    var model: RemoteControlModel?

    var body: some View {
        RemoteControlCard(model: model ?? store.remoteControl)
    }
}

private struct RemoteControlCard: View {
    @ObservedObject private var language = L10n.state
    @EnvironmentObject var store: AppStore
    @ObservedObject var model: RemoteControlModel
    /// The relay address being typed; it follows `[remote] url` until it is edited.
    @State private var relay = ""
    @State private var relayEdited = false
    @State private var confirmSignOut = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(L10n.t("remote_settings_title", "Remote control"), systemImage: "iphone.radiowaves.left.and.right")
                .font(.system(size: 15, weight: .semibold))
            Text(L10n.t("remote_settings_detail", "Follow and steer this Mac's tasks from the Crok app on your phone or from the web. This sign-in is separate from the model providers under Accounts."))
                .font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            if let link = model.link { signedIn(link) } else { signedOut }
            if let failure = model.failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 13)).foregroundStyle(Theme.red)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            } else if let notice = model.notice {
                Label(notice.text, systemImage: "info.circle")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
        .settingsCard()
        .onAppear {
            model.refresh()
            if !relayEdited { relay = model.configuredURL ?? "" }
            model.checkStatus()
        }
        // A sign-in or sign-out made in the terminal shows within a couple of seconds.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                model.refreshIfChanged()
            }
        }
        .onChange(of: model.configuredURL) { _, url in if !relayEdited { relay = url ?? "" } }
        // A reason shown once is not shown again the next time Settings opens.
        .onDisappear { model.failure = nil }
        .alert(L10n.t("remote_sign_out_title", "Sign this Mac out of remote control?"), isPresented: $confirmSignOut) {
            Button(L10n.t("accounts_sign_out", "Sign Out"), role: .destructive) { model.signOut() }
            Button(L10n.t("cancel", "Cancel"), role: .cancel) {}
        } message: {
            Text(L10n.t("remote_sign_out_message", "Your phone and the web stop seeing this Mac's tasks. The tasks keep running here."))
        }
    }

    // MARK: Signed out

    private var relayIsValid: Bool {
        relay.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || RemoteRelayAddress.normalized(relay) != nil
    }

    @ViewBuilder private var signedOut: some View {
        HStack(spacing: 12) {
            Image(systemName: "iphone.slash")
                .font(.system(size: 24, weight: .regular)).foregroundStyle(Theme.muted)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.t("remote_not_signed_in", "This Mac is not signed in")).font(.system(size: 14, weight: .semibold))
                Text(L10n.t("remote_sign_in_detail", "A page opens in your browser: sign in with the account you use in the Crok app, then approve this Mac."))
                    .font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if model.phase == .idle {
                Button(L10n.t("remote_sign_in", "Sign in…")) { model.signIn(relay: relay) }
                    .buttonStyle(.bordered)
                    .disabled(!relayIsValid)
                    .accessibilityLabel(L10n.t("remote_sign_in_label", "Sign in to remote control"))
            }
        }
        Divider()
        row(L10n.t("remote_relay", "Relay"), detail: L10n.t("remote_relay_detail", "The address of your relay, which the Crok app on your phone uses too.")) {
            VStack(alignment: .trailing, spacing: 4) {
                TextField("https://your-deployment.convex.cloud", text: Binding(get: { relay }, set: { relay = $0; relayEdited = true }))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 270)
                    .disabled(model.isBusy)
                    .onSubmit { if model.phase == .idle, relayIsValid { model.signIn(relay: relay) } }
                    .accessibilityLabel(L10n.t("remote_relay", "Relay"))
                if !relayIsValid {
                    Text(L10n.t("remote_invalid_relay", "Enter the relay's address, starting with https:// or http://."))
                        .font(.system(size: 11)).foregroundStyle(Theme.red).frame(width: 270, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        switch model.phase {
        case .starting:
            HStack(spacing: 9) {
                ProgressView().controlSize(.small)
                Text(L10n.t("remote_starting", "Starting sign-in…")).font(.system(size: 13)).foregroundStyle(Theme.muted)
                Spacer()
                Button(L10n.t("cancel", "Cancel")) { model.cancelSignIn() }
            }
        case .waiting(let code):
            codePanel(code)
        case .idle, .signingOut:
            EmptyView()
        }
    }

    /// The code to approve, large enough to compare with the one the page shows.
    private func codePanel(_ code: RemoteCLIEvent.Code) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(code.page == nil
                 ? L10n.t("remote_code_no_page", "This relay has no sign-in page. Approve this code from the Crok app on your phone.")
                 : L10n.t("remote_code_hint", "Check that the page in your browser shows this code, then approve this Mac."))
                .font(.system(size: 13)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            Text(code.userCode)
                .font(.system(size: 30, weight: .semibold, design: .monospaced))
                .kerning(2)
                .textSelection(.enabled)
                .accessibilityLabel(L10n.t("remote_code_label", "Sign-in code {code}", ["code": code.userCode]))
            HStack(spacing: 8) {
                if code.page != nil {
                    Button(L10n.t("remote_open_page", "Open Sign-in Page")) { model.openSignInPage() }
                        .buttonStyle(.bordered)
                }
                Button(copied ? L10n.t("remote_copied", "Copied") : L10n.t("remote_copy_code", "Copy Code")) {
                    model.copyCode()
                    copied = true
                    Task { try? await Task.sleep(nanoseconds: 1_500_000_000); copied = false }
                }
                .buttonStyle(.bordered)
                Spacer(minLength: 8)
                ProgressView().controlSize(.small)
                Text(L10n.t("remote_waiting", "Waiting for approval…"))
                    .font(.system(size: 13)).foregroundStyle(Theme.muted).lineLimit(1).fixedSize()
                Button(L10n.t("cancel", "Cancel")) { model.cancelSignIn() }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.sidebar.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: Signed in

    @ViewBuilder private func signedIn(_ link: RemoteLink) -> some View {
        HStack(spacing: 12) {
            avatar(link.account)
            VStack(alignment: .leading, spacing: 3) {
                Text(link.account.title ?? L10n.t("remote_account_unnamed", "Your account"))
                    .font(.system(size: 14, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                if let subtitle = link.account.subtitle {
                    Text(subtitle).font(.system(size: 13)).foregroundStyle(Theme.muted)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if model.phase == .signingOut {
                ProgressView().controlSize(.small)
                Text(L10n.t("remote_signing_out", "Signing out…")).font(.system(size: 13)).foregroundStyle(Theme.muted).fixedSize()
            } else {
                Button(L10n.t("accounts_sign_out", "Sign Out")) { confirmSignOut = true }
                    .buttonStyle(.bordered)
                    .disabled(model.isBusy)
                    .accessibilityLabel(L10n.t("remote_sign_out_label", "Sign out of remote control"))
            }
        }
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 7) {
            GridRow {
                Text(L10n.t("remote_this_mac", "This Mac")).foregroundStyle(Theme.muted)
                Text(link.deviceName.isEmpty ? "—" : link.deviceName).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
            }
            GridRow {
                Text(L10n.t("remote_relay", "Relay")).foregroundStyle(Theme.muted)
                Text(link.server).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
            }
        }
        .font(.system(size: 13))
        .padding(.leading, 46)
        Divider()
        row(L10n.t("remote_share", "Share tasks with my phone"),
            detail: L10n.t("remote_share_detail", "Your phone and the web see the tasks open on this Mac as they run, and can send them prompts and stop them.")) {
            Toggle(L10n.t("remote_share", "Share tasks with my phone"), isOn: Binding(get: { model.enabled }, set: { on in
                if let failure = model.setEnabled(on) { model.failure = failure }
            }))
            .labelsHidden().toggleStyle(.switch)
        }
        Divider()
        row(L10n.t("remote_connection", "Connection"), detail: nil) { connectionState }
    }

    /// The bridge's link as the open tasks report it.
    @ViewBuilder private var connectionState: some View {
        if !model.enabled {
            Text(L10n.t("remote_state_paused", "Sharing is off")).font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize()
        } else {
            switch store.remoteLink?.state {
            case .connected?:
                Label(L10n.t("connected", "Connected"), systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.green).fixedSize()
            case .connecting?:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(L10n.t("remote_state_connecting", "Connecting…")).font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
                .fixedSize()
            case .off?:
                Text(L10n.t("remote_state_off", "Off")).font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize()
            case nil:
                Text(L10n.t("remote_state_no_task", "Opens when a task is open")).font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize()
            }
        }
    }

    private func avatar(_ account: RemoteAccount) -> some View {
        let placeholder = Image(systemName: "person.crop.circle.badge.checkmark")
            .font(.system(size: 26, weight: .regular)).foregroundStyle(Theme.green)
        return Group {
            if let url = account.imageURL {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill().frame(width: 32, height: 32).clipShape(Circle())
                    } else {
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: 34, height: 34)
        .accessibilityHidden(true)
    }

    private func row<Control: View>(_ title: String, detail: String?, @ViewBuilder control: () -> Control) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 14, weight: .medium))
                if let detail {
                    Text(detail).font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control()
        }
    }
}
