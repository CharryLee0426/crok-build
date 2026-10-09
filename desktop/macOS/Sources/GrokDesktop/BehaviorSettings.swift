import SwiftUI

/// Permission mode, input, and voice preferences in Settings. Everything except multiline input is
/// shared with the terminal through `config.toml`.
struct BehaviorSettingsSection: View {
    @EnvironmentObject var composer: ComposerFeatureModel
    @AppStorage("composerMultiline") private var multiline = false
    @State private var uiLanguage: AppLanguage = AppLanguage.parse(GrokConfig().string("ui_language", in: "ui"))

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(L10n.t("behavior", "Behavior"), systemImage: "slider.horizontal.3").font(.system(size: 15, weight: .semibold))
            row(L10n.t("permissions", "Permissions"), detail: composer.permissionMode.detail, warning: composer.permissionMode.isAlwaysApprove) {
                Picker(L10n.t("permissions", "Permissions"), selection: Binding(get: { composer.permissionMode }, set: { composer.setPermissionMode($0) })) {
                    ForEach(permissionModes) { mode in Text(mode.title).tag(mode) }
                }.labelsHidden().pickerStyle(.menu).fixedSize()
            }
            Divider()
            row(L10n.t("multiline_input", "Multiline input"),
                detail: multiline
                    ? L10n.t("multiline_on_detail", "Return inserts a new line; ⌘Return sends.")
                    : L10n.t("multiline_off_detail", "Return sends; ⇧Return inserts a new line.")) {
                Toggle(L10n.t("multiline_input", "Multiline input"), isOn: $multiline).toggleStyle(.switch).labelsHidden().controlSize(.small)
            }
            Divider()
            row(L10n.t("while_working", "While Crok is working"), detail: composer.followUpBehavior.detail) {
                Picker(L10n.t("while_working", "While Crok is working"), selection: Binding(get: { composer.followUpBehavior }, set: { composer.setFollowUpBehavior($0) })) {
                    ForEach(ComposerFollowUpBehavior.allCases) { Text($0.title).tag($0) }
                }.labelsHidden().pickerStyle(.segmented).fixedSize()
            }
            Divider()
            row(L10n.t("dictation_shortcut", "Dictation shortcut"), detail: "\(ComposerFeatureModel.voiceShortcut) starts and stops dictation.") {
                Toggle(L10n.t("dictation_shortcut", "Dictation shortcut"), isOn: Binding(get: { composer.voiceShortcutEnabled }, set: { composer.setVoiceShortcutEnabled($0) }))
                    .toggleStyle(.switch).labelsHidden().controlSize(.small)
            }
            row(L10n.t("dictation_language", "Dictation language"),
                detail: L10n.t("dictation_language_detail", "Automatic follows your Mac's language.")) {
                Picker(L10n.t("dictation_language", "Dictation language"), selection: Binding(get: { composer.voiceLanguage }, set: { composer.setVoiceLanguage($0) })) {
                    Text(L10n.t("automatic", "Automatic")).tag("auto")
                    Divider()
                    ForEach(VoiceSTTSettings.languages, id: \.code) { Text($0.name).tag($0.code) }
                }.labelsHidden().pickerStyle(.menu).fixedSize()
            }
            row(L10n.t("dictation_model", "Dictation model"), detail: "Any OpenRouter transcription model. Pick one or type its ID and press Return. Without an OpenRouter sign-in, dictation runs on this Mac.") {
                VoiceModelControl()
            }
            Divider()
            row(L10n.t("interface_language", "Interface language"),
                detail: L10n.t("interface_language_detail", "Shared with the Crok terminal. System follows this Mac's language.")) {
                Picker(L10n.t("interface_language", "Interface language"), selection: $uiLanguage) {
                    ForEach(AppLanguage.allCases) { lang in Text(lang.menuTitle).tag(lang) }
                }
                .labelsHidden().pickerStyle(.menu).fixedSize()
                .onChange(of: uiLanguage) { _, lang in
                    L10n.setLanguage(lang)
                    let code = lang == .auto ? "auto" : lang.rawValue
                    guard NSClassFromString("XCTestCase") == nil else { return }
                    let url = GrokPaths.configFile
                    Task {
                        do { try await ComposerFeatureModel.writeConfig(url) { try $0.set("ui_language", to: .string(code), in: "ui") } }
                        catch { /* config write failures are non-fatal for UI language */ }
                    }
                }
            }
        }
        .settingsCard()
    }

    private var permissionModes: [ComposerPermissionMode] {
        ComposerPermissionMode.allCases.filter { $0 != .auto || composer.autoModeAvailable || composer.permissionMode == .auto }
    }

    /// The OpenRouter model ID with a menu of OpenRouter's transcription models (fetched live, with a built-in fallback).
    private struct VoiceModelControl: View {
        @EnvironmentObject var composer: ComposerFeatureModel
        @State private var draft = ""
        @State private var catalog: [VoiceModelOption] = []

        var body: some View {
            HStack(spacing: 4) {
                TextField("Model ID", text: $draft)
                    .textFieldStyle(.roundedBorder).frame(width: 250)
                    .onSubmit { composer.setVoiceModel(draft); draft = composer.voiceModel }
                    .accessibilityLabel("Dictation model")
                Menu {
                    ForEach(models) { model in
                        Button(model.id == composer.voiceModel ? "✓ \(model.name)" : model.name) {
                            composer.setVoiceModel(model.id)
                            draft = composer.voiceModel
                        }
                    }
                } label: { Image(systemName: "chevron.down") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("Transcription models on OpenRouter")
            }
            .onAppear { draft = composer.voiceModel }
            .onChange(of: composer.voiceModel) { _, model in draft = model }
            .task {
                let fetched = await VoiceModelCatalog.fetch()
                if !fetched.isEmpty { catalog = fetched }
            }
        }

        private var models: [VoiceModelOption] { catalog.isEmpty ? VoiceSTTSettings.suggestedModels : catalog }
    }

    private func row<Control: View>(_ title: String, detail: String, warning: Bool = false, @ViewBuilder control: () -> Control) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 14, weight: .medium))
                Text(detail).font(.system(size: 12)).foregroundStyle(warning ? ComposerPalette.warning : Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            control()
        }
    }
}
