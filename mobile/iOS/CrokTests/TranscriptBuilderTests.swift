import XCTest

@testable import Crok

final class TranscriptBuilderTests: XCTestCase {
    var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// 2027-01-15 12:00 UTC.
    let noon = 1_800_000_000_000.0 - 1_800_000_000_000.0.truncatingRemainder(dividingBy: 86_400_000) + 43_200_000

    func event(
        _ seq: Double, _ kind: EventKind, _ text: String = "x", at: Double, status: String? = nil, origin: String? = nil,
        commandId: String? = nil
    ) -> TranscriptEvent {
        TranscriptEvent(
            id: "e\(Int(seq))", seq: seq, key: "k\(Int(seq))", kind: kind, text: text, title: nil, toolKind: nil, status: status,
            origin: origin, commandId: commandId, at: at)
    }

    func command(
        _ id: String, clientId: String?, status: CommandStatus, at: Double, error: String? = nil, mine: Bool? = true
    ) -> PromptCommand {
        PromptCommand(
            id: id, clientId: clientId, text: "prompt \(id)", status: status, error: error,
            fromLabel: mine == false ? "Web" : "Charlie's iPhone", fromDeviceId: nil, mine: mine, createdAt: at, updatedAt: at)
    }

    func testOnlyThisDevicesPromptsGetTicksAndPendingBubbles() {
        let web = command("w1", clientId: "wc", status: .pending, at: noon, mine: false)
        let webDone = command("w2", clientId: "wd", status: .done, at: noon, mine: false)
        var landed = event(1, .user, "from the web", at: noon + 1, origin: "remote", commandId: "w2")
        landed.fromLabel = "Web"
        let items = TranscriptBuilder.build(
            events: [landed], commands: [web, webDone], local: [], hasOlder: false, calendar: calendar)
        XCTAssertFalse(items.contains { $0.id.hasPrefix("pending-") }, "another sender's queued prompt is not ours to show")
        guard case .user(let message) = contentItems(items).first?.kind else { return XCTFail("expected the web prompt") }
        XCTAssertNil(message.tick, "no ticks on someone else's prompt")
        XCTAssertEqual(message.fromLabel, "Web")
        XCTAssertTrue(message.isRemote)
    }

    func testOlderRelaysWithoutMineCountEveryPromptAsOwn() {
        let legacy = command("c1", clientId: "c", status: .delivered, at: noon, mine: nil)
        let items = TranscriptBuilder.build(events: [], commands: [legacy], local: [], hasOlder: false, calendar: calendar)
        guard case .user(let message) = items.last?.kind else { return XCTFail("expected a pending bubble") }
        XCTAssertEqual(message.tick, .delivered)
    }

    func contentItems(_ items: [TranscriptItem]) -> [TranscriptItem] {
        items.filter { if case .day = $0.kind { return false } else { return true } }
    }

    func testSortsBySeqAndGroupsOneAuthorWithinTenMinutes() {
        let minute = 60_000.0
        let events = [
            event(3, .tool, at: noon + 2 * minute),
            event(1, .user, at: noon),
            event(2, .assistant, at: noon + 1 * minute),
            event(4, .assistant, at: noon + 3 * minute),
            event(5, .assistant, at: noon + 20 * minute),
            event(6, .user, at: noon + 21 * minute),
        ]
        let items = TranscriptBuilder.build(events: events, commands: [], local: [], hasOlder: false, calendar: calendar)
        XCTAssertEqual(items.first?.kind, .day)
        let content = contentItems(items)
        XCTAssertEqual(content.map(\.id), ["e1", "e2", "e3", "e4", "e5", "e6"])
        XCTAssertEqual(content.map(\.position), [.single, .first, .middle, .last, .single, .single])
    }

    func testDayHeadersBreakGroups() {
        // 23:58 and 00:01: two minutes apart, but on two days.
        let clean = [
            event(1, .assistant, at: noon - 12 * 3_600_000 - 120_000),
            event(2, .assistant, at: noon - 12 * 3_600_000 + 60_000),
        ]
        let items = TranscriptBuilder.build(events: clean, commands: [], local: [], hasOlder: false, calendar: calendar)
        XCTAssertEqual(items.map(\.id).filter { $0.hasPrefix("day-") }.count, 2)
        XCTAssertEqual(contentItems(items).map(\.position), [.single, .single])
    }

    func testEndOfTurnMarkersAreHiddenAndCancelledReadsStopped() {
        let events = [
            event(1, .assistant, at: noon),
            event(2, .system, "", at: noon + 1, status: "end_turn"),
            event(3, .system, "", at: noon + 2, status: "cancelled"),
            event(4, .error, "Boom", at: noon + 3),
        ]
        let content = contentItems(
            TranscriptBuilder.build(events: events, commands: [], local: [], hasOlder: false, calendar: calendar))
        XCTAssertEqual(content.map(\.id), ["e1", "e3", "e4"])
        XCTAssertEqual(content[1].kind, .notice(text: "Stopped", style: .stopped))
        XCTAssertEqual(content[2].kind, .notice(text: "Boom", style: .error))
    }

    func testOptimisticPromptShowsAClockUntilTheRelayKnowsIt() {
        let local = LocalPrompt(clientId: "c1", text: "Run the tests", createdAt: noon + 5_000)
        let items = TranscriptBuilder.build(
            events: [event(1, .assistant, at: noon)], commands: [], local: [local], hasOlder: false, calendar: calendar)
        guard case .user(let message) = items.last?.kind else { return XCTFail("expected the pending bubble last") }
        XCTAssertEqual(message.text, "Run the tests")
        XCTAssertEqual(message.tick, .sending)
        XCTAssertTrue(message.isPending)
    }

    func testCommandTakesOverTheLocalBubbleThenTheEventReplacesIt() {
        var local = LocalPrompt(clientId: "c1", text: "Run the tests", createdAt: noon + 5_000)
        local.commandId = "cmd1"
        let delivered = command("cmd1", clientId: "c1", status: .delivered, at: noon + 5_000)

        let queued = TranscriptBuilder.build(
            events: [event(1, .assistant, at: noon)], commands: [delivered], local: [local], hasOlder: false,
            calendar: calendar)
        let pendingBubbles = contentItems(queued).filter { $0.id.hasPrefix("pending-") }
        XCTAssertEqual(pendingBubbles.count, 1, "one bubble, not one from the command and one local")
        if case .user(let message) = pendingBubbles.first?.kind {
            XCTAssertEqual(message.tick, .delivered)
        } else {
            XCTFail("expected a user bubble")
        }

        let done = command("cmd1", clientId: "c1", status: .done, at: noon + 5_000)
        let landed = TranscriptBuilder.build(
            events: [event(1, .assistant, at: noon), event(2, .user, "Run the tests", at: noon + 6_000, origin: "remote", commandId: "cmd1")],
            commands: [done], local: [local], hasOlder: false, calendar: calendar)
        let users = contentItems(landed).compactMap { item -> UserMessage? in
            if case .user(let message) = item.kind { return message } else { return nil }
        }
        XCTAssertEqual(users.count, 1, "the optimistic bubble is gone once the transcript has the prompt")
        XCTAssertEqual(users.first?.tick, .done)
        XCTAssertEqual(users.first?.fromLabel, "Charlie's iPhone")
        XCTAssertFalse(users.first?.isPending ?? true)
    }

    func testFailedPromptsShowTheirError() {
        let failed = command("cmd9", clientId: "c9", status: .failed, at: noon, error: "The computer was busy.")
        let items = TranscriptBuilder.build(events: [], commands: [failed], local: [], hasOlder: false, calendar: calendar)
        guard case .user(let message) = items.last?.kind else { return XCTFail("expected a user bubble") }
        XCTAssertEqual(message.tick, .failed)
        XCTAssertEqual(message.error, "The computer was busy.")
        XCTAssertEqual(message.commandId, "cmd9")
    }

    func testAFailedPromptKeepsItsPlaceInTimeWhileQueuedOnesStayLast() {
        let failed = command("f", clientId: "cf", status: .failed, at: noon + 60_000, error: "busy")
        let queued = command("q", clientId: "cq", status: .pending, at: noon + 30_000)
        let events = [event(1, .assistant, at: noon), event(2, .assistant, at: noon + 120_000)]
        let ids = contentItems(
            TranscriptBuilder.build(events: events, commands: [failed, queued], local: [], hasOlder: false, calendar: calendar)
        ).map(\.id)
        XCTAssertEqual(ids, ["e1", "pending-cf", "e2", "pending-cq"])
    }

    func testLocalSendFailureShowsFailed() {
        var local = LocalPrompt(clientId: "c2", text: "hello", createdAt: noon)
        local.failure = "This session is not running on its computer right now."
        let items = TranscriptBuilder.build(events: [], commands: [], local: [local], hasOlder: false, calendar: calendar)
        guard case .user(let message) = items.last?.kind else { return XCTFail("expected a user bubble") }
        XCTAssertEqual(message.tick, .failed)
        XCTAssertNil(message.commandId)
    }

    func testOldDeliveredPromptsAreAssumedToBeInUnloadedPages() {
        let old = command("old", clientId: "c0", status: .delivered, at: noon - 3_600_000)
        let events = [event(50, .assistant, at: noon)]
        let withOlder = TranscriptBuilder.build(events: events, commands: [old], local: [], hasOlder: true, calendar: calendar)
        XCTAssertFalse(withOlder.contains { $0.id.hasPrefix("pending-") })
        let allLoaded = TranscriptBuilder.build(events: events, commands: [old], local: [], hasOlder: false, calendar: calendar)
        XCTAssertTrue(allLoaded.contains { $0.id.hasPrefix("pending-") }, "with everything loaded it is still queued")
    }

    func testDuplicateEventsFromOverlappingPagesAppearOnce() {
        let one = event(1, .assistant, at: noon)
        let items = TranscriptBuilder.build(events: [one, one], commands: [], local: [], hasOlder: false, calendar: calendar)
        XCTAssertEqual(contentItems(items).count, 1)
    }
}
