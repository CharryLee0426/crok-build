import PhotosUI
import SwiftUI

/// Profile › Appearance (Telegram's Settings › Appearance, mobile/DESIGN.md "Appearance"): a preview of a session, the
/// session themes, a photo as the background, and light or dark.
struct AppearanceView: View {
    @AppStorage("crok.appearance") private var appearance = Appearance.system.rawValue
    @AppStorage(SessionTheme.storageKey) private var themeID = SessionTheme.noneID
    @AppStorage(SessionTheme.blurKey) private var blur = false
    @Environment(\.colorScheme) private var colorScheme
    @State private var pickedPhoto: PhotosPickerItem?
    @State private var savingPhoto = false
    @State private var photoFailed = false
    private var photo = SessionPhoto.shared

    var body: some View {
        let themes = SessionTheme.all.filter { $0.kind != .photo || photo.hasPhoto }
        let selected = SessionTheme.named(themeID)
        Form {
            Section {
                ThemePreview(theme: selected)
                    .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 4, trailing: 12))
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(themes) { theme in
                                ThemeCard(theme: theme, selected: theme.id == selected.id) {
                                    withAnimation(.snappy) { themeID = theme.id }
                                }
                                .id(theme.id)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                    }
                    .onAppear { proxy.scrollTo(selected.id, anchor: .center) }
                }
                .listRowInsets(EdgeInsets())
                Text(selected.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("selectedThemeName")
            } header: {
                Text("Session Theme")
            }

            Section {
                PhotosPicker(selection: $pickedPhoto, matching: .images, photoLibrary: .shared()) {
                    HStack {
                        SettingsRowLabel("Choose a Photo", systemImage: "photo.on.rectangle", color: ProfileView.blue)
                            .foregroundStyle(Color.primary)
                        if savingPhoto {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .accessibilityIdentifier("choosePhoto")
                if selected.kind == .photo {
                    Toggle(isOn: $blur) {
                        SettingsRowLabel("Blur", systemImage: "drop.halffull", color: ProfileView.grey)
                    }
                    .accessibilityIdentifier("blurToggle")
                }
            }

            Section("Color Mode") {
                Picker("Color Mode", selection: $appearance) {
                    ForEach(Appearance.allCases) { option in
                        Text(option.title).tag(option.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityIdentifier("appearancePicker")
            }
        }
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: pickedPhoto) { _, item in
            guard let item else { return }
            savingPhoto = true
            Task {
                let data = try? await item.loadTransferable(type: Data.self)
                let saved = if let data { await photo.save(data) } else { false }
                savingPhoto = false
                pickedPhoto = nil
                if saved {
                    withAnimation(.snappy) { themeID = SessionTheme.photoID }
                } else {
                    photoFailed = true
                }
            }
        }
        .alert("Couldn't do that", isPresented: $photoFailed) {
            Button("OK", role: .cancel) {}
        }
    }
}

/// The top of Appearance: a short exchange on the chosen background, in the theme's colours.
private struct ThemePreview: View {
    let theme: SessionTheme
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = SessionPalette.make(theme, dark: colorScheme == .dark)
        VStack(spacing: 8) {
            Text("Today")
                .font(.caption.weight(.semibold))
                .foregroundStyle(palette.serviceText)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(palette.serviceBackground, in: Capsule())
            HStack {
                Text("All 214 tests pass. Want me to open a PR?")
                    .foregroundStyle(Theme.agentBubbleText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Theme.agentBubble, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                Spacer(minLength: 48)
            }
            HStack {
                Spacer(minLength: 48)
                HStack(alignment: .lastTextBaseline, spacing: 6) {
                    Text("Yes, please.")
                        .foregroundStyle(palette.userBubbleText)
                    HStack(spacing: 3) {
                        Text(verbatim: "9:41")
                        DeliveryTickView(tick: .done, color: palette.userBubbleMeta)
                    }
                    .font(.caption2)
                    .foregroundStyle(palette.userBubbleMeta)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(palette.userBubble, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        }
        .font(.subheadline)
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 190)
        .background(SessionBackgroundView(themeID: theme.id))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("themePreview")
    }
}

/// One theme in the strip: its background with two small bubbles and its emoji; ringed while selected.
private struct ThemeCard: View {
    let theme: SessionTheme
    let selected: Bool
    let select: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = SessionPalette.make(theme, dark: colorScheme == .dark)
        Button(action: select) {
            VStack(spacing: 6) {
                Capsule()
                    .fill(Theme.agentBubble)
                    .frame(width: 44, height: 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Capsule()
                    .fill(palette.userBubble)
                    .frame(width: 44, height: 14)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                Spacer(minLength: 0)
                badge
            }
            .padding(10)
            .frame(width: 84, height: 116)
            .background(SessionBackgroundView(themeID: theme.id, patternScale: 0.5))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline))
            .padding(4)
            .overlay(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .strokeBorder(selected ? Theme.accent : Color.clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(theme.name))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("themeCard-\(theme.id)")
    }

    @ViewBuilder
    private var badge: some View {
        switch theme.kind {
        case .plain:
            Image(systemName: "xmark")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.secondary)
        case .photo:
            Image(systemName: "photo")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(radius: 2)
        case .pattern:
            Text(verbatim: theme.emoji)
                .font(.system(size: 24))
        }
    }
}
