import SwiftUI

/// Settings: the account, devices, linking a computer, appearance, language, about, sign out.
struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(CrokEngine.self) private var engine
    @Environment(\.openURL) private var openURL
    @AppStorage("crok.appearance") private var appearance = Appearance.system.rawValue
    @State private var confirmSignOut = false
    @State private var signingOut = false

    var body: some View {
        let user = engine.account.value??.user ?? engine.credentials.user
        Form {
            Section {
                HStack(spacing: 14) {
                    AccountAvatarView(user: user, size: 60)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(user.name ?? user.email ?? String(localized: "Your account"))
                            .font(.title3.weight(.semibold))
                        if let email = user.email, user.name != nil {
                            Text(email)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 6)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("accountHeader")
            }

            Section {
                NavigationLink {
                    DevicesView()
                } label: {
                    LabeledContent {
                        Text(verbatim: "\(engine.deviceList.value?.count ?? 0)")
                    } label: {
                        Label("Devices", systemImage: "laptopcomputer.and.iphone")
                    }
                }
                .accessibilityIdentifier("devicesRow")
                NavigationLink {
                    LinkComputerView()
                } label: {
                    Label("Link a computer", systemImage: "qrcode.viewfinder")
                }
                .accessibilityIdentifier("linkComputerRow")
            } footer: {
                Text("Scan the QR code that crok remote login shows on your computer to link it to this account.")
            }

            Section("Appearance") {
                Picker("Appearance", selection: $appearance) {
                    ForEach(Appearance.allCases) { option in
                        Text(option.title).tag(option.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityIdentifier("appearancePicker")
            }

            Section {
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                } label: {
                    LabeledContent {
                        Text(Locale.current.localizedString(forIdentifier: Locale.current.identifier) ?? "")
                            .foregroundStyle(.secondary)
                    } label: {
                        Label("Language", systemImage: "globe")
                            .foregroundStyle(Color.primary)
                    }
                }
            } footer: {
                Text("Crok follows your iPhone's language: English, 简体中文, 日本語, Español, Français or Deutsch. To choose another one for Crok only, open Settings › Apps › Crok › Language.")
            }

            Section("About") {
                LabeledContent("Version", value: "\(AppInfo.version) (\(AppInfo.build))")
                LabeledContent("Server") {
                    Text(engine.credentials.serverURL)
                        .font(.footnote)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                LabeledContent("This device", value: engine.credentials.deviceName)
                if engine.isDemo {
                    LabeledContent("Mode", value: String(localized: "Demo"))
                }
            }

            Section {
                Button(role: .destructive) {
                    confirmSignOut = true
                } label: {
                    HStack {
                        Text("Sign Out")
                        if signingOut {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(signingOut)
                .accessibilityIdentifier("signOutButton")
            }
        }
        .navigationTitle("Settings")
        .confirmationDialog("Sign out of Crok on this iPhone?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) {
                signingOut = true
                Task { await app.signOut() }
            }
        } message: {
            Text("This iPhone is unlinked from your account. Your computers and their sessions are not affected.")
        }
    }
}
