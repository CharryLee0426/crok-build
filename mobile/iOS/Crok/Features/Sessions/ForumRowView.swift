import SwiftUI

/// A project on the Sessions tab (Telegram's row for a group with topics, mobile/DESIGN.md "Sessions tab"): the
/// rounded-square avatar, the name and time, its newest topics, then what is going on in it and its unread total.
struct ForumRowView: View {
    let group: ProjectGroup

    private var summary: ForumSummary { ForumSummary.make(group) }
    private var offline: Bool { !group.deviceOnline }

    var body: some View {
        let summary = self.summary
        HStack(alignment: .top, spacing: 12) {
            ProjectAvatarView(folder: group.name, dimmed: offline, square: true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(group.name)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                        .foregroundStyle(offline ? Color.secondary : Color.primary)
                    Spacer(minLength: 4)
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(RelativeTime.compact(Date(milliseconds: group.lastActivityAt), now: context.date))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(summary.unread > 0 && !offline ? Theme.accent : Color.secondary)
                    }
                }
                topicStrip(summary.topics)
                HStack(alignment: .center, spacing: 6) {
                    activityLine(summary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if summary.unread > 0 {
                        UnreadBadge(count: summary.unread, muted: offline)
                    }
                }
                .frame(minHeight: 22)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("projectRow-\(group.name)")
    }

    /// The newest topics in one line that truncates at its end: the first in the primary colour, the rest secondary,
    /// each after its small topic icon.
    private func topicStrip(_ topics: [SessionRow]) -> some View {
        topics.enumerated().reduce(Text(verbatim: "")) { line, pair in
            let (index, topic) = pair
            let icon = Text(Image(uiImage: TopicIconImages.image(for: topic.id, title: topic.title, size: 14, dimmed: offline)))
                .baselineOffset(-2)
            let title = Text(verbatim: topic.title)
                .foregroundStyle(index == 0 && !offline ? Color.primary : Color.secondary)
                .fontWeight(index == 0 ? .medium : .regular)
            return line + Text(verbatim: index == 0 ? "" : "   ") + icon + Text(verbatim: " ") + title
        }
        .font(.subheadline)
        .lineLimit(1)
    }

    @ViewBuilder
    private func activityLine(_ summary: ForumSummary) -> some View {
        switch summary.activity {
        case .running:
            WorkingIndicator()
        case .waiting:
            NeedsApprovalChip()
        case .none:
            if let latest = summary.latest, latest.isStarting, !offline {
                Text("Starting…")
                    .font(.subheadline)
                    .foregroundStyle(Theme.accent)
                    .lineLimit(1)
            } else if let latest = summary.latest, let preview = latest.preview, !preview.isEmpty {
                SessionPreviewText(preview: preview, kind: latest.previewKind)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text("No messages yet")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }
}

/// The first row of the Sessions tab while the computer has archived sessions (Telegram's Archived Chats).
struct ArchivedSessionsRow: View {
    let rows: [SessionRow]

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "archivebox.fill")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 54, height: 54)
                .background(Color(uiColor: .systemGray2).gradient, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("Archived Sessions")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    Spacer(minLength: 4)
                    let unread = rows.reduce(0) { $0 + $1.unreadCount }
                    if unread > 0 {
                        UnreadBadge(count: unread, muted: true)
                    }
                }
                Text(rows.map(\.title).joined(separator: ", "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("archivedRow")
    }
}
