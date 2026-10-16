import SwiftUI

/// One row of the session list (Telegram's chat-list item): avatar with online dot, title and time, where it runs,
/// then the preview, an animated "working…", or "Needs approval"; unread badge or pin on the right.
///
/// In a project's section (`grouped`) the header already names the project and the computer, so the second line only
/// shows the session's own folder when it is not the project's, and "offline"; it is left out when it has neither.
struct SessionRowView: View {
    let row: SessionRow
    var grouped = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ProjectAvatarView(folder: row.projectDisplayName, online: row.online, dimmed: !row.online)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(row.title)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                        .foregroundStyle(row.online ? Color.primary : Color.secondary)
                    Spacer(minLength: 4)
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(RelativeTime.compact(row.lastActivity, now: context.date))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(row.unreadCount > 0 && row.online ? Theme.accent : Color.secondary)
                    }
                }
                if let locationLine {
                    HStack(spacing: 4) {
                        Image(systemName: row.app == .desktop ? "macwindow" : "terminal")
                            .font(.caption2)
                        Text(locationLine)
                            .lineLimit(1)
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                HStack(alignment: .center, spacing: 6) {
                    previewLine
                        .frame(maxWidth: .infinity, alignment: .leading)
                    trailingMark
                }
                .frame(minHeight: 22)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("sessionRow-\(row.title)")
    }

    /// Flat list: `computer · project · folder · offline`; in a project's section: `folder · offline`, or nothing.
    private var locationLine: String? {
        var parts = grouped ? [] : [row.deviceName, row.projectDisplayName]
        if let folder = row.folderIfNotProject { parts.append(folder) }
        if !row.online { parts.append(String(localized: "offline")) }
        parts = parts.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var previewLine: some View {
        if row.online && row.status == .running {
            WorkingIndicator()
        } else if row.online && row.status == .waiting {
            NeedsApprovalChip()
        } else if let preview = row.preview, !preview.isEmpty {
            previewText(preview)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else if row.historyState?.isOnComputerOnly == true {
            // Listed from the computer's disk; the transcript comes over when the session is opened.
            Text("History on \(row.deviceName)")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        } else {
            Text("No messages yet")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
        }
    }

    private func previewText(_ preview: String) -> Text {
        let flat = preview.replacingOccurrences(of: "\n", with: " ")
        switch row.previewKind {
        case .user:
            return Text("You: ").foregroundStyle(Color.primary.opacity(0.8)) + Text(flat)
        case .tool:
            return Text(Image(systemName: "wrench.and.screwdriver")) + Text(verbatim: " ") + Text(flat)
        case .error:
            return Text(Image(systemName: "exclamationmark.triangle")) + Text(verbatim: " ") + Text(flat)
        default:
            return Text(flat)
        }
    }

    @ViewBuilder
    private var trailingMark: some View {
        if row.unreadCount > 0 {
            UnreadBadge(count: row.unreadCount, muted: !row.online)
        } else if row.pinned {
            Image(systemName: "pin.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(45))
                .accessibilityLabel(Text("Pinned"))
        }
    }
}
