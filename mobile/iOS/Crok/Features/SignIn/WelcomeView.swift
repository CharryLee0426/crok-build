import SwiftUI

/// The only screen a signed-out phone can reach, besides waiting for approval.
struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @State private var showsAdvanced = false
    @State private var serverDraft = ""

    var body: some View {
        @Bindable var model = model
        GeometryReader { geometry in
        ScrollView {
            VStack(spacing: 28) {
                Spacer(minLength: 24)
                header
                features
                if model.needsServerField {
                    serverField
                }
                VStack(spacing: 12) {
                    continueButton
                    if let notice = model.notice {
                        Text(notice)
                            .font(.footnote)
                            .foregroundStyle(Theme.danger)
                            .multilineTextAlignment(.center)
                            .accessibilityIdentifier("welcomeNotice")
                    }
                    Text("You sign in on the web. This iPhone is then linked to your account until you sign it out.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                Button("Advanced") { showsAdvanced = true }
                    .font(.footnote)
                    .accessibilityIdentifier("advancedButton")
                Spacer(minLength: 12)
            }
            .padding(.horizontal, 28)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity, minHeight: geometry.size.height)
        }
        .scrollBounceBehavior(.basedOnSize)
        }
        .background(Theme.canvas.ignoresSafeArea())
        .sheet(isPresented: $showsAdvanced) {
            AdvancedSignInSheet()
        }
    }

    private var header: some View {
        VStack(spacing: 14) {
            Image("CrokMark")
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .frame(width: 84, height: 92)
                .foregroundStyle(Theme.accent)
                .accessibilityHidden(true)
            Text(verbatim: "Crok")
                .font(.largeTitle.weight(.bold))
            Text("Follow and steer your crok sessions from your phone.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var features: some View {
        VStack(alignment: .leading, spacing: 16) {
            FeatureRow(symbol: "rectangle.stack", text: "See every session on every computer, as it streams.")
            FeatureRow(symbol: "paperplane", text: "Send a prompt, or stop the running turn.")
            FeatureRow(symbol: "gauge.with.dots.needle.33percent", text: "Check the model, tokens, cost and plan.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var serverField: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 6) {
            Text("Server")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField(text: $model.serverOverride, prompt: Text(verbatim: "https://your-relay.convex.cloud")) {
                Text("Server")
            }
                .textContentType(.URL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(12)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityIdentifier("serverField")
        }
    }

    private var continueButton: some View {
        Button {
            Task { await model.startSignIn() }
        } label: {
            HStack(spacing: 10) {
                if model.isStarting {
                    ProgressView().tint(Theme.onAccent)
                }
                Text("Continue with GitHub or Google")
                    .font(.headline)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .foregroundStyle(Theme.onAccent)
        .disabled(model.isStarting || model.serverURL == nil)
        .accessibilityIdentifier("continueButton")
    }
}

private struct FeatureRow: View {
    let symbol: String
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Image(systemName: symbol)
                .font(.body.weight(.medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 28)
            Text(text)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Advanced › Server and the name this phone signs in under.
struct AdvancedSignInSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var server = ""
    @State private var name = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(text: $server, prompt: Text(verbatim: "https://your-relay.convex.cloud")) {
                        Text("Server")
                    }
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("advancedServerField")
                } header: {
                    Text("Server")
                } footer: {
                    if model.environment.bundledServerURL.isEmpty {
                        Text("The address of your Crok relay (a Convex deployment).")
                    } else {
                        Text("Leave empty to use \(model.environment.bundledServerURL).")
                    }
                }
                if !server.isEmpty && ServerURL.normalize(server) == nil {
                    Text("That isn't a valid address.")
                        .foregroundStyle(Theme.danger)
                }
                Section {
                    TextField("iPhone", text: $name)
                        .accessibilityIdentifier("deviceNameField")
                } header: {
                    Text("Device name")
                } footer: {
                    Text("How this phone appears on your other devices.")
                }
            }
            .navigationTitle("Advanced")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        model.serverOverride = server.trimmingCharacters(in: .whitespacesAndNewlines)
                        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty { model.deviceName = trimmed }
                        dismiss()
                    }
                    .disabled(!server.isEmpty && ServerURL.normalize(server) == nil)
                }
            }
            .onAppear {
                server = model.serverOverride
                name = model.deviceName
            }
        }
        .presentationDetents([.medium, .large])
    }
}
