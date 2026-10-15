import SwiftUI

/// The input panel: a multi-line field with Send, and Stop while a turn runs (Telegram's streaming stop). Offline
/// sessions are read-only.
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
            } else if !model.isOnline {
                offlineNotice
            } else {
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
        }
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var offlineNotice: some View {
        HStack(spacing: 10) {
            Image(systemName: "moon.zzz")
                .foregroundStyle(.secondary)
            Text("This session isn't running. Open it on \(model.computerName) to continue.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .accessibilityIdentifier("offlineNotice")
    }
}
