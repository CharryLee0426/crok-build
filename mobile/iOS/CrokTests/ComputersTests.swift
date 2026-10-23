import SwiftUI
import UIKit
import XCTest

@testable import Crok

/// Computers as accounts, projects as groups with topics, and the session themes (mobile/DESIGN.md).
final class ComputersTests: XCTestCase {
    private func device(_ id: String, _ name: String, kind: DeviceKind = .computer, created: Double, online: Bool = false)
        -> DeviceRow
    {
        DeviceRow(
            id: id, kind: kind, name: name, platform: "macOS", client: "crok", createdAt: created, lastSeenAt: created,
            online: online, isCurrent: false, liveSessionCount: 0)
    }

    private func row(_ id: String, title: String = "A session", device: String = "a", last: Double = 0, unread: Double = 0,
                     status: SessionStatus = .idle, online: Bool = false) -> SessionRow
    {
        SessionRow(
            id: id, sessionId: id, title: title, cwd: "/src/p", model: nil, status: status, online: online, app: .tui,
            deviceId: device, deviceName: device.uppercased(), deviceOnline: true, preview: nil, previewKind: nil,
            lastActivityAt: last, pinned: false, archived: false, unread: unread, plan: nil, projectKey: "\(device):/src/p",
            projectPath: "/src/p", projectName: "p", historyState: nil, starting: nil)
    }

    private func group(_ device: String, _ rows: [SessionRow], name: String = "p") -> ProjectGroup {
        ProjectGroup(
            key: "\(device):/src/\(name)", deviceId: device, deviceName: device.uppercased(), deviceOnline: true,
            path: "/src/\(name)", name: name, placed: false, lastActivityAt: rows.map(\.lastActivityAt).max() ?? 0,
            sessions: rows)
    }

    // MARK: Computers

    func testComputersComeInLinkOrderThenTheOnesOnlyTheListKnows() {
        let devices = [
            device("b", "Second", created: 20), device("phone", "Phone", kind: .phone, created: 5),
            device("a", "First", created: 10, online: true),
        ]
        let groups = [
            group("a", [row("1", device: "a", last: 100, unread: 2)]),
            group("b", [row("2", device: "b", last: 300, unread: 1)]),
            group("gone", [row("3", device: "gone", last: 200)]),
            group("a", [row("4", device: "a", last: 50, unread: 3)], name: "q"),
        ]
        let computers = ComputerList.make(devices: devices, groups: groups)
        XCTAssertEqual(computers.map(\.id), ["a", "b", "gone"], "phones are not computers")
        XCTAssertEqual(computers.map(\.unread), [5, 1, 0])
        XCTAssertEqual(computers.map(\.lastActivityAt), [100, 300, 200])
        XCTAssertEqual(computers[2].name, "GONE", "named from the session list")
        XCTAssertNil(computers[2].lastSeenAt)
        XCTAssertTrue(computers[0].online)
    }

    func testTheSelectionFallsBackToTheMostRecentlyActiveComputer() {
        let computers = [
            ComputerAccount(id: "a", name: "A", online: true, unread: 0, lastActivityAt: 100),
            ComputerAccount(id: "b", name: "B", online: false, unread: 0, lastActivityAt: 300),
            ComputerAccount(id: "c", name: "C", online: false, unread: 0, lastActivityAt: 0),
        ]
        XCTAssertEqual(ComputerList.resolve(remembered: "a", in: computers), "a", "the remembered one while linked")
        XCTAssertEqual(ComputerList.resolve(remembered: "gone", in: computers), "b")
        XCTAssertEqual(ComputerList.resolve(remembered: nil, in: computers), "b")
        let idle = computers.map { computer -> ComputerAccount in
            var idle = computer
            idle.lastActivityAt = 0
            return idle
        }
        XCTAssertEqual(ComputerList.resolve(remembered: nil, in: idle), "a", "the first without any activity")
        XCTAssertNil(ComputerList.resolve(remembered: "a", in: []))
    }

    func testTheSelectedComputerIsStoredPerPhone() {
        let defaults = UserDefaults(suiteName: "crok.selected.\(UUID().uuidString)")!
        let store = SelectedComputerStore(defaults: defaults)
        XCTAssertNil(store.load())
        store.save("mbp")
        XCTAssertEqual(SelectedComputerStore(defaults: defaults).load(), "mbp")
        store.save(nil)
        XCTAssertNil(store.load())
    }

    // MARK: Projects as groups

    func testAForumRowShowsTheNewestThreeTopicsAndWhatIsGoingOn() {
        let rows = [
            row("old", title: "Old", last: 10), row("new", title: "New", last: 40, unread: 1),
            row("mid", title: "Mid", last: 30), row("older", title: "Older", last: 5, unread: 2),
        ]
        let summary = ForumSummary.make(group("a", rows))
        XCTAssertEqual(summary.topics.map(\.title), ["New", "Mid", "Old"])
        XCTAssertEqual(summary.latest?.title, "New")
        XCTAssertEqual(summary.unread, 3)
        XCTAssertEqual(summary.activity, .none)

        let waiting = ForumSummary.make(group("a", rows + [row("w", status: .waiting, online: true)]))
        XCTAssertEqual(waiting.activity, .waiting)
        let running = ForumSummary.make(
            group("a", rows + [row("w", status: .waiting, online: true), row("r", status: .running, online: true)]))
        XCTAssertEqual(running.activity, .running, "a running turn wins over a question")
        let notRun = ForumSummary.make(group("a", [row("r", status: .running, online: false)]))
        XCTAssertEqual(notRun.activity, .none, "nobody runs it: not working")
    }

    func testMarkingReadClearsOnlyTheGivenSessions() {
        let groups = [
            group("a", [row("1", unread: 2), row("2", unread: 1)]),
            group("b", [row("3", device: "b", unread: 4)]),
        ]
        XCTAssertEqual(ReadAll.unreadIDs(in: groups), ["1", "2", "3"])
        let read = ProjectOrder.markingRead(["1", "3"], in: groups)
        XCTAssertEqual(read.flatMap(\.sessions).map(\.unreadCount), [0, 1, 0])
        XCTAssertEqual(ReadAll.unreadIDs(in: read), ["2"])
        XCTAssertEqual(ProjectOrder.markingRead([], in: groups), groups)
    }

    func testTopicIconsTakeTheFirstLetterAndAStableColour() {
        XCTAssertEqual(TopicIcon.letter(for: "fix the flaky test"), "F")
        XCTAssertEqual(TopicIcon.letter(for: "  42 things"), "4")
        XCTAssertEqual(TopicIcon.letter(for: "/compact"), "C")
        XCTAssertEqual(TopicIcon.letter(for: "éclair"), "É")
        XCTAssertEqual(TopicIcon.letter(for: "修复测试"), "修")
        XCTAssertEqual(TopicIcon.letter(for: "🎉"), "·")
        XCTAssertEqual(TopicIcon.letter(for: ""), "·")
        for id in ["s-flaky", "s-bench", "k57a…", ""] {
            let index = TopicIcon.colorIndex(for: id)
            XCTAssertTrue(TopicIcon.colors.indices.contains(index))
            XCTAssertEqual(index, TopicIcon.colorIndex(for: id), "the same on every call and launch")
        }
        XCTAssertEqual(TopicIcon.colors, [0x6FB9F0, 0xFFD67E, 0xCB86DB, 0x8EEE98, 0xFF93B2, 0xFB6F5F])
    }

    // MARK: Session themes

    func testEveryThemeIsComplete() {
        let ids = SessionTheme.all.map(\.id)
        XCTAssertEqual(
            ids, ["none", "classic", "home", "duck", "snowman", "diamond", "teacher", "tulip", "purple", "christmas", "game", "photo"])
        for theme in SessionTheme.all where theme.kind == .pattern {
            for variant in [theme.light, theme.dark] {
                XCTAssertEqual(variant?.colors.count, 4, theme.id)
            }
            XCTAssertFalse(theme.emoji.isEmpty, theme.id)
            XCTAssertGreaterThanOrEqual(theme.symbols.count, 10, theme.id)
            for symbol in theme.symbols {
                XCTAssertNotNil(UIImage(systemName: symbol), "\(theme.id): no SF Symbol \(symbol)")
            }
        }
        XCTAssertEqual(SessionTheme.named("nope").id, "none")
        XCTAssertEqual(SessionTheme.named("tulip").id, "tulip")
    }

    func testTheGradientMixesFourColoursNearTheirPoints() {
        for (x, y) in [(0.0, 0.0), (0.5, 0.5), (1.0, 1.0), (0.3, 0.7)] {
            XCTAssertEqual(SessionWallpaper.weights(x: x, y: y).reduce(0, +), 1, accuracy: 1e-9)
        }
        for (index, point) in SessionWallpaper.points.enumerated() {
            let weights = SessionWallpaper.weights(x: point.0, y: point.1)
            XCTAssertGreaterThan(weights[index], 0.85, "colour \(index) leads at its own point")
        }
        let image = SessionWallpaper.gradient([0xFF0000, 0x00FF00, 0x0000FF, 0xFFFFFF], width: 8, height: 8)
        XCTAssertEqual(image?.width, 8)
        XCTAssertNil(SessionWallpaper.gradient([0xFF0000]))
    }

    func testThePatternIsTheSameOnEveryLaunch() {
        let theme = SessionTheme.named("classic")
        let size = CGSize(width: 390, height: 844)
        let first = SessionWallpaper.layout(theme, size: size).map(\.symbol)
        XCTAssertEqual(first, SessionWallpaper.layout(theme, size: size).map(\.symbol))
        XCTAssertGreaterThan(first.count, 60, "covers the screen")
        XCTAssertNotEqual(first, SessionWallpaper.layout(SessionTheme.named("home"), size: size).map(\.symbol))
        XCTAssertTrue(SessionWallpaper.layout(SessionTheme.named("none"), size: size).isEmpty)
        let glyphs = SessionWallpaper.layout(theme, size: size)
        XCTAssertTrue(glyphs.allSatisfy { $0.size >= 22 && $0.size <= 30 })
        XCTAssertTrue(glyphs.allSatisfy { abs($0.angle) <= 25 * .pi / 180 + 1e-9 })
    }

    func testThemesSetThePersonsBubblesAndTheServiceCapsules() {
        let plain = SessionPalette.make(.none, dark: false)
        XCTAssertEqual(plain, .standard)
        XCTAssertFalse(plain.onWallpaper)
        let classic = SessionPalette.make(SessionTheme.named("classic"), dark: false)
        XCTAssertTrue(classic.onWallpaper)
        XCTAssertEqual(classic.userBubble, Color(uiColor: UIColor(hex: 0xEFFDDE)))
        XCTAssertEqual(classic.serviceText, .white)
        let photo = SessionPalette.make(.photo, dark: true)
        XCTAssertTrue(photo.onWallpaper)
        XCTAssertEqual(photo.userBubble, SessionPalette.standard.userBubble, "a photo keeps the default bubbles")
    }

    @MainActor
    func testAWallpaperRendersInBothVariants() {
        let theme = SessionTheme.named("snowman")
        for dark in [false, true] {
            let image = SessionWallpaper.render(theme, dark: dark, size: CGSize(width: 120, height: 200), scale: 1)
            XCTAssertEqual(image?.size, CGSize(width: 120, height: 200))
        }
        XCTAssertNil(SessionWallpaper.render(.none, dark: false, size: CGSize(width: 10, height: 10), scale: 1))
    }
}
