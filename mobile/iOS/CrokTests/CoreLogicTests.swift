import XCTest

@testable import Crok

final class UserCodeTests: XCTestCase {
    func testNormalizesAnySpellingOfACode() {
        XCTAssertEqual(UserCode.normalize("BCDF-GHJK"), "BCDF-GHJK")
        XCTAssertEqual(UserCode.normalize("bcdfghjk"), "BCDF-GHJK")
        XCTAssertEqual(UserCode.normalize(" bcdf ghjk "), "BCDF-GHJK")
        XCTAssertEqual(UserCode.normalize("bcdf_ghjk\n"), "BCDF-GHJK")
    }

    func testRejectsWrongLengthAndLettersOutsideTheAlphabet() {
        XCTAssertNil(UserCode.normalize("BCDF-GHJ"))
        XCTAssertNil(UserCode.normalize("BCDF-GHJKL"))
        XCTAssertNil(UserCode.normalize("ABCD-EFGH"), "vowels are not in the code alphabet")
        XCTAssertNil(UserCode.normalize("1234-5678"))
        XCTAssertNil(UserCode.normalize(""))
    }

    func testReadsTheCodeFromAScannedLinkOrABareCode() {
        XCTAssertEqual(UserCode.fromScan("https://crok.example/link?code=BCDF-GHJK"), "BCDF-GHJK")
        XCTAssertEqual(UserCode.fromScan("http://localhost:3000/link?code=bcdf-ghjk&app=1"), "BCDF-GHJK")
        XCTAssertEqual(UserCode.fromScan("BCDFGHJK"), "BCDF-GHJK")
        XCTAssertNil(UserCode.fromScan("https://example.com/"))
        XCTAssertNil(UserCode.fromScan("https://example.com/link?code=nope"))
    }

    func testFormatsPartialTyping() {
        XCTAssertEqual(UserCode.formatTyping("bc"), "BC")
        XCTAssertEqual(UserCode.formatTyping("bcdf"), "BCDF")
        XCTAssertEqual(UserCode.formatTyping("bcdfg"), "BCDF-G")
        XCTAssertEqual(UserCode.formatTyping("BCDF-GHJKXYZ"), "BCDF-GHJK")
    }
}

final class DeliveryTickTests: XCTestCase {
    func testMapsCommandStatusToTicks() {
        XCTAssertEqual(DeliveryTick(.pending), .sending)
        XCTAssertEqual(DeliveryTick(.delivered), .delivered)
        XCTAssertEqual(DeliveryTick(.done), .done)
        XCTAssertEqual(DeliveryTick(.failed), .failed)
        XCTAssertEqual(DeliveryTick(.unknown), .sending)
    }

    func testUnknownStatusesStillDecode() throws {
        let data = Data(#"["pending","delivered","done","failed","teleported"]"#.utf8)
        let statuses = try JSONDecoder().decode([CommandStatus].self, from: data)
        XCTAssertEqual(statuses, [.pending, .delivered, .done, .failed, .unknown])
    }
}

final class PlanSummaryTests: XCTestCase {
    func testCountsDoneAndPicksTheItemInProgress() throws {
        let plan = [
            PlanEntry(content: "Reproduce", status: "completed"),
            PlanEntry(content: "Fix", status: "completed"),
            PlanEntry(content: "Write\ntests", status: "in_progress"),
            PlanEntry(content: "Ship", status: "pending"),
        ]
        let summary = try XCTUnwrap(PlanSummary.make(plan))
        XCTAssertEqual(summary.done, 2)
        XCTAssertEqual(summary.total, 4)
        XCTAssertEqual(summary.current, "Write tests")
        XCTAssertFalse(summary.isComplete)
    }

    func testFallsBackToTheNextPendingItem() {
        let plan = [PlanEntry(content: "A", status: "completed"), PlanEntry(content: "B", status: "pending")]
        XCTAssertEqual(PlanSummary.make(plan)?.current, "B")
    }

    func testEmptyPlanHasNoBarAndAFinishedPlanIsComplete() {
        XCTAssertNil(PlanSummary.make([]))
        let done = PlanSummary.make([PlanEntry(content: "A", status: "completed")])
        XCTAssertEqual(done?.isComplete, true)
        XCTAssertNil(done?.current)
    }
}

final class RelativeTimeTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testCompactScale() {
        func ago(_ seconds: TimeInterval) -> String { RelativeTime.compact(now.addingTimeInterval(-seconds), now: now) }
        XCTAssertEqual(ago(10), "now")
        XCTAssertEqual(ago(5 * 60), "5m")
        XCTAssertEqual(ago(3 * 3600), "3h")
        XCTAssertEqual(ago(2 * 86400), "2d")
        XCTAssertEqual(ago(15 * 86400), "2w")
        XCTAssertEqual(ago(65 * 86400), "2mo")
        XCTAssertEqual(ago(800 * 86400), "2y")
    }

    func testFutureTimesReadAsNow() {
        XCTAssertEqual(RelativeTime.compact(now.addingTimeInterval(120), now: now), "now")
    }

    func testDayHeaders() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(RelativeTime.dayHeader(now, now: now, calendar: calendar), "Today")
        XCTAssertEqual(RelativeTime.dayHeader(now.addingTimeInterval(-86400), now: now, calendar: calendar), "Yesterday")
    }
}

final class ProjectAvatarTests: XCTestCase {
    func testInitials() {
        XCTAssertEqual(ProjectAvatar.initials(forFolder: "crok-build"), "CB")
        XCTAssertEqual(ProjectAvatar.initials(forFolder: "relay"), "R")
        XCTAssertEqual(ProjectAvatar.initials(forFolder: "my_app.ios"), "MA")
        XCTAssertEqual(ProjectAvatar.initials(forFolder: ""), "·")
    }

    func testColourIsStableAndInRange() {
        let first = ProjectAvatar.colorIndex(for: "crok-build", paletteSize: 7)
        XCTAssertEqual(first, ProjectAvatar.colorIndex(for: "crok-build", paletteSize: 7))
        for name in ["a", "relay", "tokenizer", "xai-grok-pager", ""] {
            XCTAssert((0..<7).contains(ProjectAvatar.colorIndex(for: name, paletteSize: 7)))
        }
    }

    func testFolderNames() {
        XCTAssertEqual(PathText.lastComponent("/Users/me/src/crok-build"), "crok-build")
        XCTAssertEqual(PathText.lastComponent("/Users/me/src/crok-build/"), "crok-build")
        XCTAssertEqual(PathText.lastComponent("C:\\work\\app"), "app")
        XCTAssertEqual(PathText.abbreviatingHome("/Users/me/src/x"), "~/src/x")
        XCTAssertEqual(PathText.abbreviatingHome("/Users/me"), "~")
        XCTAssertEqual(PathText.abbreviatingHome("/opt/x"), "/opt/x")
    }
}

/// The session header's status (relay/components/session/SessionView.tsx `SessionHeader`).
final class SessionPresenceTests: XCTestCase {
    func testOnlyAnOfflineComputerMakesASessionOffline() {
        XCTAssertEqual(SessionPresence(online: false, deviceOnline: false, status: .idle), .offline)
        XCTAssertEqual(SessionPresence(online: true, deviceOnline: false, status: .running), .offline)
        XCTAssertEqual(SessionPresence(online: false, deviceOnline: true, status: .idle), .idle, "a prompt opens it there")
        XCTAssertEqual(SessionPresence(online: false, deviceOnline: true, status: .running), .idle, "nobody runs it")
        XCTAssertEqual(SessionPresence(online: true, deviceOnline: true, status: .running), .running)
        XCTAssertEqual(SessionPresence(online: true, deviceOnline: true, status: .waiting), .waiting)
        XCTAssertEqual(SessionPresence(online: true, deviceOnline: true, status: .error), .error)
        XCTAssertEqual(SessionPresence(online: true, deviceOnline: true, status: .idle), .idle)
    }
}

final class ConnectionStatusTests: XCTestCase {
    func testDerivation() {
        XCTAssertEqual(ConnectionStatus.derive(networkAvailable: false, socketConnected: true, synced: true), .waitingForNetwork)
        XCTAssertEqual(ConnectionStatus.derive(networkAvailable: true, socketConnected: false, synced: false), .connecting)
        XCTAssertEqual(ConnectionStatus.derive(networkAvailable: true, socketConnected: true, synced: false), .updating)
        XCTAssertEqual(ConnectionStatus.derive(networkAvailable: true, socketConnected: true, synced: true), .online)
    }

    @MainActor
    func testProblemsShowOnlyAfterTheDelayAndOnlineShowsAtOnce() async throws {
        var shown: [ConnectionStatus] = []
        let delayed = DelayedConnectionStatus(initial: .online, delay: .milliseconds(80)) { shown.append($0) }
        delayed.update(.connecting)
        delayed.update(.online)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(shown, [], "a blip shorter than the delay never shows")
        delayed.update(.connecting)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(shown, [.connecting])
        delayed.update(.updating)
        XCTAssertEqual(shown, [.connecting, .updating], "moving between problem states is immediate")
        delayed.update(.online)
        XCTAssertEqual(shown, [.connecting, .updating, .online])
    }
}

final class BottomFollowerTests: XCTestCase {
    func testFollowsUntilThePersonScrollsAwayEvenInsideATallLastReply() {
        var follower = BottomFollower()
        XCTAssertFalse(follower.phaseChanged(.user))
        // 190 pt up: still inside the last reply, but its end is off screen.
        for distance in stride(from: 0.0, through: 190, by: 10) {
            XCTAssertFalse(follower.geometryChanged(distance: distance), "no pins while the finger moves")
        }
        XCTAssertFalse(follower.follows)
        XCTAssertFalse(follower.phaseChanged(.idle))
        XCTAssertFalse(follower.follows, "away from the end once the fling stops")
        XCTAssertFalse(follower.geometryChanged(distance: 480), "a reply growing below the reader moves nothing")
        XCTAssertFalse(follower.follows)
    }

    func testScrollingBackWithinTheSlopFollowsAgain() {
        var follower = BottomFollower()
        _ = follower.phaseChanged(.user)
        _ = follower.geometryChanged(distance: 300)
        XCTAssertFalse(follower.follows)
        _ = follower.geometryChanged(distance: BottomFollower.slop - 4)
        XCTAssertTrue(follower.follows)
        XCTAssertFalse(follower.phaseChanged(.idle))
        XCTAssertTrue(follower.follows)
    }

    func testPinsWhenTheEndMovesWhileFollowing() {
        var follower = BottomFollower()
        XCTAssertFalse(follower.geometryChanged(distance: 0))
        XCTAssertTrue(follower.geometryChanged(distance: 640), "rows measured taller than estimated: back to the end")
        XCTAssertTrue(follower.follows)
        XCTAssertFalse(follower.geometryChanged(distance: 0))
    }

    func testPinsWhenRestingPastTheEnd() {
        var follower = BottomFollower()
        _ = follower.phaseChanged(.user)
        _ = follower.geometryChanged(distance: 900)
        _ = follower.phaseChanged(.idle)
        XCTAssertFalse(follower.follows)
        XCTAssertTrue(follower.geometryChanged(distance: -300), "a blank stretch under the end (the estimate shrank)")
        XCTAssertTrue(follower.follows)
    }

    func testTheButtonFollowsAndCorrectsALandingShortOfTheEnd() {
        var follower = BottomFollower()
        _ = follower.phaseChanged(.user)
        _ = follower.geometryChanged(distance: 2_000)
        _ = follower.phaseChanged(.idle)
        follower.follow()
        XCTAssertTrue(follower.follows)
        XCTAssertFalse(follower.phaseChanged(.animating))
        XCTAssertFalse(follower.geometryChanged(distance: 900), "no pins while the button's scroll animates")
        XCTAssertFalse(follower.geometryChanged(distance: 120))
        XCTAssertTrue(follower.phaseChanged(.idle), "landed 120 pt short: pin the rest of the way")
        XCTAssertFalse(follower.geometryChanged(distance: 0))
        XCTAssertTrue(follower.follows)
    }

    func testTheButtonsAnimationIsNotDriftEvenWhenThePhaseNeverReportsIt() {
        var follower = BottomFollower()
        _ = follower.phaseChanged(.user)
        _ = follower.geometryChanged(distance: 2_867)
        _ = follower.phaseChanged(.idle)
        follower.follow()
        // The animated scroll moves the geometry while the phase still says idle.
        XCTAssertFalse(follower.geometryChanged(distance: 2_865), "no pin cuts the button's animation short")
        XCTAssertFalse(follower.geometryChanged(distance: 900))
        XCTAssertFalse(follower.geometryChanged(distance: 8))
        XCTAssertFalse(follower.animationEnded(), "landed at the end")
        XCTAssertTrue(follower.follows)
        XCTAssertFalse(follower.animationEnded(), "only once")

        follower.follow()
        _ = follower.geometryChanged(distance: 300)
        XCTAssertTrue(follower.animationEnded(), "landed short: pin the rest of the way")
    }

    func testPinsThatKeepMissingStopUntilNewContent() {
        var follower = BottomFollower()
        var pins = 0
        // A layout that answers every pin with another wrong place.
        for step in 0..<40 {
            if follower.geometryChanged(distance: step % 2 == 0 ? 204 : 955) { pins += 1 }
        }
        XCTAssertEqual(pins, BottomFollower.maxMissedPins, "a layout that cannot settle does not spin")
        XCTAssertFalse(follower.follows, "away from the end: the scroll-to-bottom button shows")
        follower.follow()
        _ = follower.geometryChanged(distance: 300)
        XCTAssertTrue(follower.animationEnded(), "the button: pins try again")
        XCTAssertFalse(follower.geometryChanged(distance: 0))
        XCTAssertEqual(follower.missedPins, 0, "reaching the end clears the count")
    }

    func testNewContentLetsPinsTryAgainWhileFollowing() {
        var follower = BottomFollower()
        for _ in 0..<(BottomFollower.maxMissedPins - 1) { _ = follower.geometryChanged(distance: 500) }
        follower.contentChanged()
        for _ in 0..<(BottomFollower.maxMissedPins - 1) {
            XCTAssertTrue(follower.geometryChanged(distance: 500), "a reply growing faster than pins land")
        }
        XCTAssertTrue(follower.follows)
    }
}

final class TextRevealPacerTests: XCTestCase {
    func testRevealsGraduallyAndNeverPastTheText() {
        var pacer = TextRevealPacer(shown: 0, length: 0)
        pacer.receive(length: 120, at: 0)
        var last = 0
        for frame in 1...30 {
            let count = pacer.advance(to: Double(frame) / 60)
            XCTAssertGreaterThanOrEqual(count, last)
            XCTAssertLessThanOrEqual(count, 120)
            last = count
        }
        XCTAssertGreaterThan(last, 0)
        XCTAssertLessThan(last, 120, "half a second at the start rate shows only part of a 120-character burst")
    }

    func testFinishesWithinTheFinishWindow() {
        var pacer = TextRevealPacer(shown: 0, length: 0)
        pacer.receive(length: 500, at: 0)
        pacer.advance(to: 0.05)
        pacer.finish(at: 0.1)
        var time = 0.1
        while time < 0.1 + TextRevealPacer.finishWindow + 0.001 {
            time += 1.0 / 60
            pacer.advance(to: time)
        }
        XCTAssertEqual(pacer.shownCount, 500)
        XCTAssertTrue(pacer.isDone)
    }

    func testLearnsTheChunkRate() {
        var pacer = TextRevealPacer(shown: 0, length: 0)
        var time = 0.0
        var length = 0
        for _ in 0..<6 {
            length += 60
            pacer.receive(length: length, at: time)
            let next = time + 0.75
            while time < next {
                time += 1.0 / 60
                pacer.advance(to: time)
            }
        }
        // With chunks every 0.75 s the reveal keeps up: little is left over when the next chunk is due.
        XCTAssertGreaterThan(pacer.shownCount, length - 60)
    }

    func testShrinkingTextClampsTheReveal() {
        var pacer = TextRevealPacer(shown: 100, length: 100)
        pacer.receive(length: 40, at: 1)
        XCTAssertEqual(pacer.shownCount, 40)
    }
}

final class ServerURLTests: XCTestCase {
    func testNormalizes() {
        XCTAssertEqual(ServerURL.normalize("happy-otter-123.convex.cloud"), "https://happy-otter-123.convex.cloud")
        XCTAssertEqual(ServerURL.normalize(" http://127.0.0.1:3210/ "), "http://127.0.0.1:3210")
        XCTAssertNil(ServerURL.normalize(""))
        XCTAssertNil(ServerURL.normalize("ftp://example.com"))
    }

    func testBrowserLinkAddsTheAppFlag() {
        let pending = PendingSignIn(
            serverURL: "http://127.0.0.1:3210", deviceName: "iPhone", deviceCode: "crd_x", userCode: "BCDF-GHJK",
            verificationURL: "http://localhost:3000/link?code=BCDF-GHJK", expiresAt: 0, interval: 2)
        XCTAssertEqual(pending.browserURL?.absoluteString, "http://localhost:3000/link?code=BCDF-GHJK&app=1")
    }
}
