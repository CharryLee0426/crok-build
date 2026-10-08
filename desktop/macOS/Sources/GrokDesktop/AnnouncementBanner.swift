import SwiftUI

/// One entry of `x.ai/announcements/update`.
struct GrokAnnouncement: Equatable, Identifiable {
    struct Action: Equatable {
        let label: String
        let url: URL
        let caption: String?
    }

    var id: String { hideKey }
    var identifier: String?
    var title: String?
    var message: String?
    var severity: String?
    var action: Action?
    var expiresAt: Date?
    /// Absent means dismissible; only an explicit `false` pins the banner.
    var dismissible: Bool?

    init(identifier: String? = nil, title: String? = nil, message: String? = nil, severity: String? = nil,
         action: Action? = nil, expiresAt: Date? = nil, dismissible: Bool? = nil) {
        self.identifier = identifier; self.title = title; self.message = message; self.severity = severity
        self.action = action; self.expiresAt = expiresAt; self.dismissible = dismissible
    }

    init(_ value: [String: Any]) {
        identifier = value["id"] as? String
        title = value["title"] as? String
        message = value["message"] as? String
        severity = value["severity"] as? String
        dismissible = value["dismissible"] as? Bool
        expiresAt = (value["expires_at"] as? String).flatMap(UsageFormatting.parseDate)
        if let cta = value["cta"] as? [String: Any],
           let label = AccountJSON.string(cta["label"])?.trimmingCharacters(in: .whitespaces),
           let link = AccountJSON.string(cta["url"])?.trimmingCharacters(in: .whitespaces),
           let url = URL(string: link), ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
            // Only web links: a remote value never opens a file or a custom scheme.
            action = Action(label: label, url: url, caption: AccountJSON.string(cta["caption"])?.trimmingCharacters(in: .whitespaces))
        }
    }

    /// The trimmed id, or a key built from the content so announcements without one can still be hidden.
    /// The unit separator keeps different title/message splits apart.
    var hideKey: String {
        if let identifier = identifier?.trimmingCharacters(in: .whitespacesAndNewlines), !identifier.isEmpty { return identifier }
        return "content:" + (title ?? "") + "\u{1F}" + (message ?? "")
    }

    var isCritical: Bool { severity == "critical" }
    var isPromo: Bool { severity == "promo" }
    var isDismissible: Bool { dismissible != false }
    var hasMessage: Bool { !(message ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    func isExpired(at date: Date) -> Bool { expiresAt.map { $0 <= date } ?? false }
}

/// The terminal's banner rules: one slot, critical beats promo, and a hidden key only hides
/// announcements the server lets people dismiss.
enum AnnouncementRules {
    static func current(_ announcements: [GrokAnnouncement], hidden: Set<String>, now: Date) -> GrokAnnouncement? {
        let live = announcements.filter { $0.hasMessage && !$0.isExpired(at: now) }
        func visible(_ item: GrokAnnouncement) -> Bool { !(item.isDismissible && hidden.contains(item.hideKey)) }
        return live.first { $0.isCritical && visible($0) } ?? live.first { $0.isPromo && visible($0) }
    }

    /// Keys of every live critical or promo announcement: what `/announcements show` clears.
    static func sessionHideKeys(_ announcements: [GrokAnnouncement], now: Date) -> [String] {
        announcements.filter { $0.hasMessage && !$0.isExpired(at: now) && ($0.isCritical || $0.isPromo) }.map(\.hideKey)
    }

    /// Drops keys whose announcement is gone. Returns whether anything changed.
    static func prune(_ hidden: inout Set<String>, active: [GrokAnnouncement]) -> Bool {
        let live = Set(active.map(\.hideKey))
        let before = hidden.count
        hidden = hidden.filter(live.contains)
        return hidden.count != before
    }
}

/// `$CROK_HOME/announcements.json`: `{"hidden_ids": [...]}`, shared with the terminal.
enum AnnouncementHiddenFile {
    static func url(home: URL) -> URL { home.appendingPathComponent("announcements.json") }

    /// Missing or malformed files hide nothing.
    static func read(home: URL) -> Set<String> {
        guard let data = try? Data(contentsOf: url(home: home)), data.count <= 1_048_576,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ids = object["hidden_ids"] as? [Any] else { return [] }
        return Set(ids.compactMap { $0 as? String })
    }

    /// Sorted, so the file stays stable across writes.
    static func write(_ ids: Set<String>, home: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: ["hidden_ids": ids.sorted()], options: [.withoutEscapingSlashes])
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try data.write(to: url(home: home), options: .atomic)
    }
}

/// The announcement banner shown at the top of the conversation.
struct AnnouncementBanner: View {
    @EnvironmentObject var account: AccountFeatureModel

    var body: some View {
        if let announcement = account.currentAnnouncement {
            AnnouncementBannerRow(announcement: announcement,
                                  open: { account.openAnnouncementAction(announcement) },
                                  hide: { account.hideCurrentAnnouncement() })
        }
    }
}

struct AnnouncementBannerRow: View {
    let announcement: GrokAnnouncement
    let open: () -> Void
    let hide: () -> Void

    private var tint: Color { announcement.isCritical ? UsagePalette.warning : Theme.accent }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: announcement.isCritical ? "exclamationmark.triangle.fill" : "megaphone.fill")
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(tint)
                .frame(width: 20).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                if let title = announcement.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
                    Text(title).font(.system(size: 13, weight: .semibold))
                }
                if let message = announcement.message?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty {
                    Text(message).font(.system(size: 12.5)).foregroundStyle(announcement.title == nil ? Theme.ink : Theme.muted)
                        .lineLimit(2).textSelection(.enabled)
                }
            }
            Spacer(minLength: 8)
            if let action = announcement.action {
                if let caption = action.caption, !announcement.isDismissible {
                    Text(caption).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
                }
                Button(action.label, action: open)
                    .buttonStyle(SubtleButtonStyle()).font(.system(size: 12.5, weight: .medium))
                    .help(action.url.absoluteString)
            }
            if announcement.isDismissible {
                Button("Hide", action: hide)
                    .buttonStyle(.plain).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.muted)
                    .help("Hide this announcement · /announcements show brings it back")
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(tint.opacity(0.11))
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line.opacity(0.5)).frame(height: 0.5) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(announcement.isCritical ? "Important announcement" : "Announcement")
    }
}
