import SwiftUI

/// The only screen a signed-out phone can reach, besides waiting for approval.
struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @State private var showsAdvanced = false

    var body: some View {
        GeometryReader { geometry in
        ScrollView {
            VStack(spacing: 28) {
                Spacer(minLength: 24)
                header
                features
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

/// Advanced: the name this phone signs in under. (The relay is built into the app; there is nothing to type for it.)
struct AdvancedSignInSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        NavigationStack {
            Form {
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
                        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty { model.deviceName = trimmed }
                        dismiss()
                    }
                }
            }
            .onAppear {
                name = model.deviceName
            }
        }
        .presentationDetents([.medium, .large])
    }
}
