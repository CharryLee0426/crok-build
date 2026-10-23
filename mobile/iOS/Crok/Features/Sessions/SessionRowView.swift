import SwiftUI

/// A session in a project (Telegram's topic row, mobile/DESIGN.md "Project screen"): the topic icon, title and time,
/// where it runs when that adds something, then the preview in up to two lines, an animated "working…", or "Needs
/// approval"; unread badge or pin on the right.
///
/// In the project screen the title bar already names the project and the computer, so the second line only shows the
/// session's own folder when it is not the project's, and "offline"; in a flat list (search, Archived) it starts with
/// the project. It is left out when it has nothing to say.
///
/// A row is dimmed and "offline" only while its computer is offline: a session nobody runs on an online computer takes
/// prompts like any other.
struct SessionRowView: View {
    let row: SessionRow
    /// A flat list (search results, Archived): the second line names the project.
    var showsProject = false

    private var computerOffline: Bool { !row.deviceOnline }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            TopicIconView(sessionDocId: row.id, title: row.title, size: 40, dimmed: computerOffline)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(row.title)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                        .foregroundStyle(computerOffline ? Color.secondary : Color.primary)
                    Spacer(minLength: 4)
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(RelativeTime.compact(row.lastActivity, now: context.date))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(row.unreadCount > 0 && !computerOffline ? Theme.accent : Color.secondary)
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
                HStack(alignment: .top, spacing: 6) {
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

    /// Flat list: `project · folder · offline`; in a project: `folder · offline`, or nothing.
    private var locationLine: String? {
        var parts = showsProject ? [row.projectDisplayName] : []
        if let folder = row.folderIfNotProject { parts.append(folder) }
        if computerOffline { parts.append(String(localized: "offline")) }
        parts = parts.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var previewLine: some View {
        if row.isStarting && !computerOffline {
            // Made from a device; a crok on the computer is opening it.
            Text("Starting…")
                .font(.subheadline)
                .foregroundStyle(Theme.accent)
                .lineLimit(1)
                .accessibilityIdentifier("startingPreview")
        } else if row.online && row.status == .running {
            WorkingIndicator()
        } else if row.online && row.status == .waiting {
            NeedsApprovalChip()
        } else if let preview = row.preview, !preview.isEmpty {
            SessionPreviewText(preview: preview, kind: row.previewKind)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
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

    @ViewBuilder
    private var trailingMark: some View {
        if row.unreadCount > 0 {
            UnreadBadge(count: row.unreadCount, muted: computerOffline)
        } else if row.pinned {
            Image(systemName: "pin.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(45))
                .padding(.top, 3)
                .accessibilityLabel(Text("Pinned"))
        }
    }
}

/// A session's last message as a list shows it: "You: " before a prompt, a glyph before a tool call or an error.
struct SessionPreviewText: View {
    let preview: String
    let kind: EventKind?

    var body: some View {
        text
    }

    private var text: Text {
        let flat = preview.replacingOccurrences(of: "\n", with: " ")
        switch kind {
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
}
