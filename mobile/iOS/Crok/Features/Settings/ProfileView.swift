import SwiftUI

/// Profile (mobile/DESIGN.md "Profile", Telegram's Settings): the account, its computers (the accounts under it, one
/// selected), devices, appearance, language, the version and the developer's links, sign out.
struct ProfileView: View {
    @Environment(AppModel.self) private var app
    @Environment(CrokEngine.self) private var engine
    @Environment(\.openURL) private var openURL
    @State private var confirmSignOut = false
    @State private var signingOut = false

    static let githubURL = URL(string: "https://github.com/CharryLee0426")!
    static let xURL = URL(string: "https://x.com/CharryLee426")!

    var body: some View {
        let user = engine.account.value??.user ?? engine.credentials.user
        Form {
            Section {
                VStack(spacing: 6) {
                    AccountAvatarView(user: user, size: 96)
                        .padding(.bottom, 6)
                    Text(user.name ?? user.email ?? String(localized: "Your account"))
                        .font(.title2.weight(.semibold))
                        .multilineTextAlignment(.center)
                    if let email = user.email, user.name != nil {
                        Text(email)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("accountHeader")
            }

            Section {
                ForEach(engine.computerAccounts) { computer in
                    ComputerAccountRow(computer: computer, selected: computer.id == engine.selectedComputerId) {
                        engine.selectComputer(computer.id)
                    }
                }
                NavigationLink {
                    LinkComputerView()
                } label: {
                    Label {
                        Text("Link a computer")
                            .foregroundStyle(Theme.accent)
                    } icon: {
                        Image(systemName: "plus")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 32)
                    }
                }
                .accessibilityIdentifier("linkComputerRow")
            }

            Section {
                NavigationLink {
                    DevicesView()
                } label: {
                    LabeledContent {
                        Text(verbatim: "\(engine.deviceList.value?.count ?? 0)")
                    } label: {
                        SettingsRowLabel("Devices", systemImage: "laptopcomputer.and.iphone", color: Self.orange)
                    }
                }
                .accessibilityIdentifier("devicesRow")
                NavigationLink {
                    AppearanceView()
                } label: {
                    SettingsRowLabel("Appearance", systemImage: "paintbrush.fill", color: Self.blue)
                }
                .accessibilityIdentifier("appearanceRow")
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                } label: {
                    LabeledContent {
                        Text(Locale.current.localizedString(forIdentifier: Locale.current.identifier) ?? "")
                            .foregroundStyle(.secondary)
                    } label: {
                        SettingsRowLabel("Language", systemImage: "globe", color: Self.purple)
                            .foregroundStyle(Color.primary)
                    }
                }
                .accessibilityIdentifier("languageRow")
            }

            Section {
                LabeledContent {
                    Text(verbatim: "\(AppInfo.version) (\(AppInfo.build))")
                } label: {
                    SettingsRowLabel("Version", systemImage: "info", color: Self.grey)
                }
                if engine.isDemo {
                    LabeledContent {
                        Text("Demo")
                    } label: {
                        SettingsRowLabel("Mode", systemImage: "play.rectangle.fill", color: Self.grey)
                    }
                }
                Button {
                    openURL(Self.githubURL)
                } label: {
                    SettingsRowLabel("Contact the developer on GitHub", image: "GitHubMark", color: Self.github)
                        .foregroundStyle(Color.primary)
                }
                .accessibilityIdentifier("githubRow")
                Button {
                    openURL(Self.xURL)
                } label: {
                    SettingsRowLabel("Contact the developer on X", image: "XLogo", color: .black)
                        .foregroundStyle(Color.primary)
                }
                .accessibilityIdentifier("xRow")
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
        .navigationTitle("Profile")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Sign out of Crok on this iPhone?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) {
                signingOut = true
                Task { await app.signOut() }
            }
        } message: {
            Text("This iPhone is unlinked from your account. Your computers and their sessions are not affected.")
        }
    }

    // Telegram's settings icon colours.
    static let orange = Color(uiColor: UIColor(hex: 0xF09A37))
    static let blue = Color(uiColor: UIColor(hex: 0x3D8BF2))
    static let purple = Color(uiColor: UIColor(hex: 0xA65EEB))
    static let grey = Color(uiColor: UIColor(hex: 0x8E8E93))
    static let github = Color(uiColor: UIColor(hex: 0x24292F))
}

/// A computer in Profile (an account under the person): avatar, name, status; its unread count and a checkmark on the
/// selected one. A tap selects it.
struct ComputerAccountRow: View {
    let computer: ComputerAccount
    let selected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 12) {
                ComputerAvatarView(computer: computer, size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(computer.name)
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                    ComputerStatusText(computer: computer)
                }
                Spacer(minLength: 8)
                if computer.unread > 0 {
                    UnreadBadge(count: computer.unread)
                }
                if selected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                        .accessibilityLabel(Text("Selected"))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("computerRow-\(computer.name)")
    }
}

/// A settings row's title after Telegram's coloured square icon.
struct SettingsRowLabel: View {
    let title: LocalizedStringKey
    let icon: Image
    let color: Color

    init(_ title: LocalizedStringKey, systemImage: String, color: Color) {
        self.title = title
        self.icon = Image(systemName: systemImage)
        self.color = color
    }

    init(_ title: LocalizedStringKey, image: String, color: Color) {
        self.title = title
        self.icon = Image(image)
        self.color = color
    }

    var body: some View {
        HStack(spacing: 14) {
            icon
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .fontWeight(.semibold)
                .frame(width: 17, height: 17)
                .foregroundStyle(.white)
                .frame(width: 29, height: 29)
                .background(color, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.white.opacity(color == .black || color == ProfileView.github ? 0.18 : 0), lineWidth: 0.5))
            Text(title)
        }
    }
}
