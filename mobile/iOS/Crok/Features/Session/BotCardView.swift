import SwiftUI

/// `/model` and `/think` answered in the transcript (Telegram's bot message with an inline keyboard under it): what
/// the card asks, then one button per choice, the current one marked ✓. A tap applies it on the computer; the button
/// spins until it is done, then the card says what was chosen and the keyboard folds away.
struct BotCardView: View {
    let card: BotCard
    let choices: BotChoices
    let onChoose: (BotChoice) -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                bubble
                if showsKeyboard, case .choices(let list) = choices {
                    keyboard(list)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .frame(maxWidth: 420, alignment: .leading)
            Spacer(minLength: 28)
        }
        .animation(.snappy, value: card.state)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("botCard")
    }

    private var showsKeyboard: Bool { !card.isDone }

    private var title: String {
        switch card.kind {
        case .model: String(localized: "Model for this session")
        case .think: String(localized: "Thinking level for this session")
        }
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: card.kind == .model ? "cpu" : "brain")
                    .foregroundStyle(Theme.accent)
                if case .done(let label) = card.state {
                    Text(doneText(label))
                        .accessibilityIdentifier("botCardDone")
                } else {
                    Text(title)
                }
            }
            .font(.subheadline.weight(.semibold))
            switch choices {
            case .computerOffline(let computer):
                note(String(localized: "\(computer) is offline. Its models show here once crok runs there again."))
            case .notOffered(let computer):
                note(String(localized: "\(computer) doesn't offer model choices yet. Update crok there."))
            case .noThinking(let model):
                note(String(localized: "\(model) has no thinking levels."))
            case .choices:
                EmptyView()
            }
            switch card.state {
            case .choosing(let note?):
                self.note(note)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("botCardError")
            default:
                EmptyView()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Theme.agentBubble, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func doneText(_ label: String) -> String {
        switch card.kind {
        case .model: String(localized: "Model: \(label) ✓")
        case .think: String(localized: "Thinking level: \(label) ✓")
        }
    }

    private func note(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Models one per row with their description; thinking levels two per row.
    @ViewBuilder
    private func keyboard(_ list: [BotChoice]) -> some View {
        if card.kind == .model {
            VStack(spacing: 4) {
                ForEach(list) { choice in button(choice, showsDetail: true) }
            }
        } else {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4)], spacing: 4) {
                ForEach(list) { choice in button(choice, showsDetail: false) }
            }
        }
    }

    private func button(_ choice: BotChoice, showsDetail: Bool) -> some View {
        let spinning = card.state == .applying(choiceId: choice.id)
        return Button {
            onChoose(choice)
        } label: {
            HStack(spacing: 6) {
                Group {
                    if spinning {
                        ProgressView().controlSize(.small)
                    } else if choice.isCurrent {
                        Image(systemName: "checkmark")
                            .font(.footnote.weight(.bold))
                    }
                }
                .frame(width: spinning || choice.isCurrent ? 16 : 0)
                VStack(spacing: 1) {
                    Text(verbatim: choice.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if showsDetail, let detail = choice.detail, !detail.isEmpty {
                        Text(verbatim: detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .foregroundStyle(Theme.accent)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 10)
            .padding(.vertical, showsDetail ? 7 : 9)
            .background(Theme.agentBubble.opacity(0.85), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(card.isApplying)
        .accessibilityLabel(Text(verbatim: choice.title))
        .accessibilityValue(choice.isCurrent ? Text("Current") : Text(verbatim: ""))
        .accessibilityIdentifier("botChoice-\(choice.id)")
    }
}
