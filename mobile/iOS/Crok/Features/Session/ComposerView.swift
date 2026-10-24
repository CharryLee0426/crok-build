import SwiftUI

/// The input panel: the Menu button and its command list (Telegram's bot menu), a multi-line field with Send, and Stop
/// while a turn runs (Telegram's streaming stop), under the card of a permission request the session waits on and the
/// model and thinking-level pills. It takes prompts whenever the session's computer is online (a crok there opens a
/// session nobody runs); it is read-only only while the computer is offline.
struct ComposerView: View {
    @Bindable var model: SessionViewModel
    var focused: FocusState<Bool>.Binding
    let onSend: () -> Void

    var body: some View {
        Group {
            if model.isRemoved {
                EmptyView()
            } else if !model.canSendPrompts {
                offlineNotice
                    .background(.regularMaterial)
                    .overlay(alignment: .top) { Divider() }
            } else {
                ComposerBar {
                    VStack(spacing: 8) {
                        if let request = model.pendingRequest {
                            PermissionCard(
                                request: request, computerName: model.computerName, answering: model.isAnsweringRequest,
                                onAnswer: { option in Task { await model.answer(option, to: request) } }
                            )
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                        if !model.commandMenuItems.isEmpty {
                            CommandListPanel(items: model.commandMenuItems) { item in
                                model.pick(item)
                                if item.takesArgument { focused.wrappedValue = true }
                            }
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                        } else if let row = model.setupRow {
                            ModelSetupBar(
                                row: row, offersDefault: false, onModel: { model.tapModelPill() },
                                onLevel: { model.chooseLevel($0) })
                            .transition(.opacity)
                        }
                        ComposerInputRow(
                            draft: $model.draft,
                            placeholder: String(localized: "Message crok on \(model.computerName)…"),
                            focused: focused,
                            menu: .init(
                                collapsed: !model.draft.isEmpty, open: !model.commandMenuItems.isEmpty,
                                action: { withAnimation(.snappy) { model.toggleMenu() } }),
                            isRunning: model.isRunning, canSend: model.canSendDraft,
                            onStop: { Task { await model.stop() } },
                            onSend: {
                                model.send()
                                onSend()
                            })
                    }
                    .animation(.snappy, value: model.pendingRequest?.id)
                    .animation(.snappy, value: model.commandMenuItems.map(\.id))
                    .animation(.snappy, value: model.setupRow == nil)
                }
            }
        }
        .sheet(isPresented: $model.showsModelPicker) {
            ModelPickerSheet(
                models: model.models ?? [], computerName: model.computerName, current: model.setupRow?.modelId,
                offersDefault: false, onPick: { id in if let id { model.chooseModel(id) } })
        }
        .alert(
            Text(verbatim: String(localized: "\(model.computerName) doesn't offer model choices yet. Update crok there.")),
            isPresented: $model.showsNotOffered
        ) {
            Button("OK", role: .cancel) {}
        }
        .alert(
            model.configFailure?.title ?? "",
            // Session info shows it while it is open.
            isPresented: Binding(
                get: { model.configFailure != nil && !model.showsInfo },
                set: { if !$0 { model.configFailure = nil } }),
            presenting: model.configFailure
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { failure in
            Text(verbatim: failure.message)
        }
    }

    private var offlineNotice: some View {
        HStack(spacing: 10) {
            Image(systemName: "desktopcomputer")
                .foregroundStyle(.secondary)
            Text("\(model.computerName) is offline. Start crok or Crok Desktop there to continue this session.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("offlineNotice")
    }
}

/// The composer's surface: on iOS 26 its controls float as Liquid Glass over the transcript scrolling beneath; on
/// iOS 17–25 a material bar with a hairline on top.
struct ComposerBar<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        if hasLiquidGlass {
            content()
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 8)
                .frame(maxWidth: 780)
                .frame(maxWidth: .infinity)
        } else {
            content()
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: 780)
                .frame(maxWidth: .infinity)
                .background(.regularMaterial)
                .overlay(alignment: .top) { Divider() }
        }
    }
}

/// The Menu button, the field, Stop and Send. The field is a glass capsule on iOS 26.
struct ComposerInputRow: View {
    struct MenuConfig {
        var collapsed: Bool
        var open: Bool
        var action: () -> Void
    }

    @Binding var draft: String
    let placeholder: String
    var focused: FocusState<Bool>.Binding
    let menu: MenuConfig?
    let isRunning: Bool
    let canSend: Bool
    let onStop: () -> Void
    let onSend: () -> Void

    private var hasText: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if let menu {
                MenuPill(collapsed: menu.collapsed, open: menu.open, action: menu.action)
            }
            TextField(placeholder, text: $draft, axis: .vertical)
                .lineLimit(1...6)
                .focused(focused)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .modifier(FieldSurface())
                .accessibilityIdentifier("composerField")
            if isRunning {
                Button(action: onStop) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(Theme.danger, in: Circle())
                }
                .accessibilityLabel(Text("Stop"))
                .accessibilityIdentifier("stopButton")
                .transition(.scale.combined(with: .opacity))
            }
            if hasText || !isRunning {
                Button(action: onSend) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(Theme.onAccent)
                        .frame(width: 38, height: 38)
                        .background(canSend ? Theme.accent : Color.secondary.opacity(0.35), in: Circle())
                }
                .disabled(!canSend)
                .accessibilityLabel(Text("Send"))
                .accessibilityIdentifier("sendButton")
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.snappy, value: isRunning)
        .animation(.snappy, value: hasText)
    }

    private struct FieldSurface: ViewModifier {
        func body(content: Content) -> some View {
            if hasLiquidGlass {
                content.glassSurface(in: RoundedRectangle(cornerRadius: 20, style: .continuous), interactive: true)
            } else {
                content
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.hairline))
            }
        }
    }
}

/// A permission request the session waits on (run this command, edit that file), with one button per choice: allowing
/// ones prominent, the others plain. Any of the person's devices may answer; the first answer counts, and the card
/// goes once the computer has it (Telegram's bot keyboard above the input panel, in spirit).
struct PermissionCard: View {
    let request: PendingInteraction
    let computerName: String
    /// This phone's answer is on its way: the buttons are disabled and a spinner shows.
    let answering: Bool
    let onAnswer: (PendingOption) -> Void
    @State private var detailHeight: CGFloat = 0

    /// About five lines of the detail; a longer one scrolls in its box.
    static let detailMaxHeight: CGFloat = 92

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised.fill")
                    .accessibilityHidden(true)
                Text("Crok on \(computerName) asks:")
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 4)
                if answering {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(Text("Sending"))
                        .accessibilityIdentifier("permissionAnswering")
                }
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(Theme.waiting)
            Text(verbatim: request.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            if let detail = request.detail, !detail.isEmpty {
                ScrollView {
                    Text(verbatim: detail)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .textSelection(.enabled)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { detailHeight = $0 }
                }
                // As tall as the text, up to a few lines.
                .frame(height: min(max(detailHeight, 1), Self.detailMaxHeight))
                .scrollBounceBehavior(.basedOnSize)
                .background(Theme.codeBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityIdentifier("permissionDetail")
            }
            // One row when the choices fit, else one full-width button per line.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { optionButtons(fill: false) }
                VStack(spacing: 8) { optionButtons(fill: true) }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.waiting.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .modifier(CardGlass())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("permissionCard")
    }

    /// Over a glass composer the card needs its own surface to stay legible.
    private struct CardGlass: ViewModifier {
        func body(content: Content) -> some View {
            if hasLiquidGlass {
                content.glassSurface(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else {
                content
            }
        }
    }

    private func optionButtons(fill: Bool) -> some View {
        ForEach(request.options) { option in
            Button {
                onAnswer(option)
            } label: {
                Text(verbatim: option.label)
                    .font(.subheadline.weight(option.isAllow ? .semibold : .regular))
                    .lineLimit(1)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .frame(maxWidth: fill ? .infinity : nil)
                    .foregroundStyle(option.isAllow ? Theme.onAccent : Color.primary)
                    .background(option.isAllow ? Theme.accent : Color(uiColor: .systemBackground), in: Capsule())
                    .overlay(Capsule().strokeBorder(option.isAllow ? Color.clear : Theme.hairline))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(answering)
            .opacity(answering ? 0.5 : 1)
            // "Allow once, button. Run npm test" — the choice, then what it answers.
            .accessibilityLabel(Text(verbatim: option.label))
            .accessibilityHint(Text(verbatim: request.title))
            .accessibilityIdentifier("permissionOption-\(option.optionId)")
        }
    }
}
