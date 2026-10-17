import SwiftUI

/// The Menu button at the start of the composer (Telegram's bot menu button): a blue pill with "Menu" while the field
/// is empty, just the icon while typing. It opens the command list.
struct MenuPill: View {
    let collapsed: Bool
    let open: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: open ? "xmark" : "line.3.horizontal")
                    .font(.system(size: 14, weight: .bold))
                    .contentTransition(.symbolEffect(.replace))
                if !collapsed {
                    Text("Menu")
                        .font(.subheadline.weight(.semibold))
                        .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .leading)))
                }
            }
            .foregroundStyle(Theme.onAccent)
            .padding(.horizontal, collapsed ? 11 : 13)
            .frame(height: 38)
            .background(Theme.accent, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(.snappy, value: collapsed)
        .accessibilityLabel(Text("Menu"))
        .accessibilityHint(Text("Shows the commands"))
        .accessibilityIdentifier("menuButton")
    }
}

/// The command list above the composer (Telegram's command panel): the phone's own commands, then the session's;
/// `/name` in bold, its input hint greyed, the description underneath.
struct CommandListPanel: View {
    let items: [CommandMenuItem]
    let onPick: (CommandMenuItem) -> Void

    /// About five rows; more scroll.
    static let maxHeight: CGFloat = 5.5 * 52

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 {
                        Divider().padding(.leading, 52)
                    }
                    row(item)
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: min(Self.maxHeight, CGFloat(items.count) * 52 + 2))
        .glassSurface(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            if !hasLiquidGlass {
                RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.hairline)
            }
        }
        .shadow(color: .black.opacity(hasLiquidGlass ? 0 : 0.08), radius: 8, y: 2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("commandList")
    }

    private func row(_ item: CommandMenuItem) -> some View {
        Button {
            onPick(item)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: Self.symbol(for: item))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.onAccent)
                    .frame(width: 28, height: 28)
                    .background(item.source == .session ? Theme.mutedBadge : Theme.accent, in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(verbatim: "/\(item.name)")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        if let hint = item.hint {
                            Text(verbatim: hint)
                                .font(.subheadline)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .lineLimit(1)
                    if !item.description.isEmpty {
                        Text(verbatim: item.description)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("commandRow-\(item.name)")
    }

    private static func symbol(for item: CommandMenuItem) -> String {
        switch item.source {
        case .device(.new): "square.and.pencil"
        case .device(.model): "cpu"
        case .device(.think): "brain"
        case .device(.stop): "stop.fill"
        case .device(.info): "info"
        case .session: "chevron.right"
        }
    }
}
