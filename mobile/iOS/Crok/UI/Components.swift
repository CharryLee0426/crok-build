import SwiftUI

/// A project's avatar: its initials on the project's colour. A rounded square on the Sessions tab, where a project is
/// a group with topics (Telegram draws forum avatars that way); a circle with an online dot elsewhere.
struct ProjectAvatarView: View {
    let folder: String
    var online = false
    var dimmed = false
    var size: CGFloat = 54
    var square = false

    var body: some View {
        ZStack {
            if square {
                RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                    .fill(Theme.avatarColor(for: folder).gradient)
            } else {
                Circle()
                    .fill(Theme.avatarColor(for: folder).gradient)
            }
            Text(ProjectAvatar.initials(forFolder: folder))
                .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .minimumScaleFactor(0.5)
        }
        .frame(width: size, height: size)
        .saturation(dimmed ? 0 : 1)
        .opacity(dimmed ? 0.55 : 1)
        .overlay(alignment: .bottomTrailing) {
            if online {
                Circle()
                    .fill(Theme.online)
                    .frame(width: size * 0.26, height: size * 0.26)
                    .overlay(Circle().strokeBorder(Color(uiColor: .systemBackground), lineWidth: size * 0.05))
                    .offset(x: size * 0.02, y: size * 0.02)
                    .accessibilityLabel(Text("Online"))
            }
        }
        .accessibilityHidden(!online)
    }
}

/// "working…" with three pulsing dots, for a running session (Telegram's typing indicator in the chat list).
struct WorkingIndicator: View {
    var font: Font = .subheadline
    var showsText = true

    var body: some View {
        HStack(spacing: 5) {
            TimelineView(.animation(minimumInterval: 1.0 / 20)) { context in
                let phase = context.date.timeIntervalSinceReferenceDate * 3.2
                HStack(spacing: 2.5) {
                    ForEach(0..<3) { index in
                        Circle()
                            .frame(width: 4.5, height: 4.5)
                            .opacity(0.35 + 0.65 * max(0, sin(phase - Double(index) * 0.9)))
                    }
                }
            }
            .frame(width: 19)
            if showsText {
                Text("working…")
                    .font(font)
            }
        }
        .foregroundStyle(Theme.accent)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("working…"))
    }
}

/// The orange "Needs approval" chip: the agent asked something on the computer.
struct NeedsApprovalChip: View {
    var body: some View {
        Label("Needs approval", systemImage: "hand.raised.fill")
            .font(.caption.weight(.semibold))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(Theme.waiting)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Theme.waiting.opacity(0.14), in: Capsule())
    }
}

/// Clock, ✓, ✓✓ or a red "!" (Telegram's message status).
struct DeliveryTickView: View {
    let tick: DeliveryTick
    var color: Color = Theme.accent

    var body: some View {
        Group {
            switch tick {
            case .sending:
                Image(systemName: "clock")
                    .accessibilityLabel(Text("Sending"))
            case .delivered:
                Image(systemName: "checkmark")
                    .accessibilityLabel(Text("Delivered"))
            case .done:
                ZStack {
                    Image(systemName: "checkmark").offset(x: -3.5)
                    Image(systemName: "checkmark").offset(x: 2)
                }
                .frame(width: 18)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Done"))
            case .failed:
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(Theme.danger)
                    .accessibilityLabel(Text("Not sent"))
            }
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(color)
        .accessibilityIdentifier("tick-\(tick.identifier)")
    }
}

extension DeliveryTick {
    var identifier: String {
        switch self {
        case .sending: "sending"
        case .delivered: "delivered"
        case .done: "done"
        case .failed: "failed"
        }
    }
}

/// A title that turns into the connection state with a spinner while the relay is not live (Telegram's chat list and
/// chat titles).
struct ConnectionTitleView: View {
    let title: String
    let subtitle: AnyView?
    let connection: ConnectionStatus
    /// A small chevron after the title: a tap on it opens a menu (the computer switcher).
    let chevron: Bool

    init(title: String, connection: ConnectionStatus, subtitle: AnyView? = nil, chevron: Bool = false) {
        self.title = title
        self.connection = connection
        self.subtitle = subtitle
        self.chevron = chevron
    }

    var body: some View {
        VStack(spacing: 1) {
            if subtitle == nil, let state = connection.title {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(state)
                        .font(.headline)
                }
                .accessibilityIdentifier("connectionTitle")
            } else {
                HStack(spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .lineLimit(1)
                    if chevron {
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(Color.primary)
                if let subtitle {
                    if let state = connection.title {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.mini)
                            Text(state)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("connectionTitle")
                    } else {
                        subtitle
                    }
                }
            }
        }
        .frame(maxWidth: 260)
        .animation(.default, value: connection)
    }
}

/// An unread counter (accent, or grey when the session is offline).
struct UnreadBadge: View {
    let count: Int
    var muted = false

    var body: some View {
        Text(verbatim: count > 99 ? "99+" : "\(count)")
            .font(.caption.weight(.semibold).monospacedDigit())
            .foregroundStyle(Theme.onAccent)
            .padding(.horizontal, 7)
            .frame(minWidth: 22, minHeight: 22)
            .background(muted ? Theme.mutedBadge : Theme.unreadBadge, in: Capsule())
            .accessibilityLabel(Text("\(count) unread"))
    }
}

/// The person's picture from the account, or their initials.
struct AccountAvatarView: View {
    let user: AccountUser
    var size: CGFloat = 64

    var body: some View {
        Group {
            if let string = user.imageUrl, let url = URL(string: string) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        initials
                    }
                }
            } else {
                initials
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }

    private var initials: some View {
        let name = user.name ?? user.email ?? "?"
        return ZStack {
            Circle().fill(Theme.accent.gradient)
            Text(ProjectAvatar.initials(forFolder: name))
                .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.onAccent)
        }
    }
}
