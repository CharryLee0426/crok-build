import AuthenticationServices
import OSLog
import SwiftUI

private let signInLog = Logger(subsystem: "dev.chenli.crok.mobile", category: "sign-in")

/// "Waiting for approval": the code in large type, the browser sheet, and polling underneath. Survives the app being
/// killed (the pending sign-in is in the Keychain).
struct WaitingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @State private var copied = false
    /// The last browser request this screen opened (changing it does not restart the task below).
    @State private var openedRequest: UUID?

    var body: some View {
        GeometryReader { geometry in
        ScrollView {
            VStack(spacing: 26) {
                Spacer(minLength: 24)
                VStack(spacing: 10) {
                    Image(systemName: "iphone.and.arrow.forward")
                        .font(.system(size: 44, weight: .regular))
                        .foregroundStyle(Theme.accent)
                        .accessibilityHidden(true)
                    Text("Waiting for approval")
                        .font(.title.weight(.bold))
                        .accessibilityIdentifier("waitingTitle")
                    Text("Sign in on the page that opened, then approve this iPhone. The page shows the same code.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                if let pending = model.pending {
                    codeCard(pending)
                }
                status
                VStack(spacing: 12) {
                    Button {
                        model.openBrowserAgain()
                    } label: {
                        Text("Open again")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                    .foregroundStyle(Theme.onAccent)
                    .disabled(model.pending?.browserURL == nil)
                    .accessibilityIdentifier("openAgainButton")
                    Button(role: .cancel) {
                        model.cancelSignIn()
                    } label: {
                        Text("Cancel")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                    .accessibilityIdentifier("cancelSignInButton")
                }
                Spacer(minLength: 12)
            }
            .padding(.horizontal, 28)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity, minHeight: geometry.size.height)
        }
        .scrollBounceBehavior(.basedOnSize)
        }
        .background(Theme.canvas.ignoresSafeArea())
        .task(id: model.browserRequest?.id) {
            guard let request = model.browserRequest, request.id != openedRequest else { return }
            openedRequest = request.id
            let url = request.url
            // Present once this screen has settled: a sheet requested during the transition from the welcome screen
            // has no window to attach to and fails at once.
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            for attempt in 1...2 {
                do {
                    // The web page ends on crok://signed-in just to close the sheet; approval arrives by polling.
                    _ = try await webAuthenticationSession.authenticate(
                        using: url, callbackURLScheme: "crok", preferredBrowserSession: .shared)
                    signInLog.info("browser sheet finished")
                    break
                } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
                    signInLog.info("browser sheet closed by the person")
                    break
                } catch {
                    signInLog.error("browser sheet failed (attempt \(attempt)): \(String(describing: error), privacy: .public)")
                    if attempt == 1 { try? await Task.sleep(for: .seconds(1)) }
                }
            }
            await model.pollOnce()
        }
    }

    private func codeCard(_ pending: PendingSignIn) -> some View {
        VStack(spacing: 10) {
            Text(pending.userCode)
                .font(.system(size: 40, weight: .semibold, design: .monospaced))
                .tracking(4)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .textSelection(.enabled)
                .accessibilityIdentifier("userCode")
                .accessibilityLabel(Text(pending.userCode.map(String.init).joined(separator: " ")))
            Text("Signing in as “\(pending.deviceName)”")
                .font(.footnote)
                .foregroundStyle(.secondary)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let left = max(0, Int((pending.expiresAt - context.date.milliseconds) / 1000))
                Text("Code expires in \(String(format: "%d:%02d", left / 60, left % 60))")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 22)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.hairline))
        .contextMenu {
            Button {
                UIPasteboard.general.string = pending.userCode
            } label: {
                Label("Copy Code", systemImage: "doc.on.doc")
            }
        }
    }

    private var status: some View {
        HStack(spacing: 10) {
            ProgressView()
            if let problem = model.pollProblem {
                Text(problem)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text("Waiting for you to approve…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
