import SwiftUI

/// The input panel: a multi-line field with Send, and Stop while a turn runs (Telegram's streaming stop), under the card
/// of a permission request the session waits on. It takes prompts whenever the session's computer is online (a crok
/// there opens a session nobody runs); it is read-only only while the computer is offline.
struct ComposerView: View {
    @Bindable var model: SessionViewModel
    var focused: FocusState<Bool>.Binding
    let onSend: () -> Void

    private var canSend: Bool {
        !model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Group {
            if model.isRemoved {
                EmptyView()
            } else if !model.canSendPrompts {
                offlineNotice
            } else {
                VStack(spacing: 0) {
                    if let request = model.pendingRequest {
                        PermissionCard(
                            request: request, computerName: model.computerName, answering: model.isAnsweringRequest,
                            onAnswer: { option in Task { await model.answer(option, to: request) } }
                        )
                        .padding(.horizontal, 10)
                        .padding(.top, 8)
                        .frame(maxWidth: 760)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    inputRow
                }
                .animation(.snappy, value: model.pendingRequest?.id)
            }
        }
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var inputRow: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(
                "Message crok on \(model.computerName)…", text: $model.draft, axis: .vertical
            )
            .lineLimit(1...6)
            .focused(focused)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.hairline))
            .accessibilityIdentifier("composerField")
            if model.isRunning {
                Button {
                    Task { await model.stop() }
                } label: {
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
            if canSend || !model.isRunning {
                Button {
                    model.send()
                    onSend()
                } label: {
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
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
        .animation(.snappy, value: model.isRunning)
        .animation(.snappy, value: canSend)
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
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("permissionCard")
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
