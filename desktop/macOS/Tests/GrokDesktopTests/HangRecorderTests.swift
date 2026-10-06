import XCTest
@testable import GrokDesktop

/// The test app's hang recorder: when a silent main thread is reported, and what the report holds.
final class HangWatchTests: XCTestCase {
    func testAQuestionIsAskedThenReportedOnceWhenItsAnswerIsLate() {
        var watch = HangWatch()
        let policy = HangPolicy(threshold: 3, spacing: 20)
        XCTAssertEqual(watch.tick(now: 100, policy: policy), .ask)
        XCTAssertEqual(watch.tick(now: 100.25, policy: policy), .wait)
        XCTAssertEqual(watch.tick(now: 102.75, policy: policy), .wait)
        XCTAssertEqual(watch.tick(now: 103.25, policy: policy), .report(waited: 3.25))
        // The same hang is not reported again, however long it lasts.
        XCTAssertEqual(watch.tick(now: 110, policy: policy), .wait)
        XCTAssertEqual(watch.answered(now: 112), HangWatch.Answer(waited: 12, wasReported: true))
        XCTAssertNil(watch.answered(now: 113), "No question is pending once it is answered")
    }

    func testAPromptAnswerIsNoHang() {
        var watch = HangWatch()
        XCTAssertEqual(watch.tick(now: 5, policy: HangPolicy()), .ask)
        XCTAssertEqual(watch.answered(now: 5.125), HangWatch.Answer(waited: 0.125, wasReported: false))
        XCTAssertEqual(watch.tick(now: 5.25, policy: HangPolicy()), .ask)
    }

    func testHangsCloseTogetherShareOneReport() {
        var watch = HangWatch()
        let policy = HangPolicy(threshold: 3, spacing: 20)
        _ = watch.tick(now: 0, policy: policy)
        XCTAssertEqual(watch.tick(now: 3, policy: policy), .report(waited: 3))
        _ = watch.answered(now: 4)
        // A second hang five seconds later is within the spacing: no second report, and no claim of one.
        XCTAssertEqual(watch.tick(now: 9, policy: policy), .ask)
        XCTAssertEqual(watch.tick(now: 13, policy: policy), .wait)
        XCTAssertEqual(watch.answered(now: 14), HangWatch.Answer(waited: 5, wasReported: false))
        // A third, after the spacing, is reported.
        XCTAssertEqual(watch.tick(now: 30, policy: policy), .ask)
        XCTAssertEqual(watch.tick(now: 34, policy: policy), .report(waited: 4))
    }
}

@MainActor
final class HangRecorderTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("crok-hang-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private final class Clock: @unchecked Sendable {
        var now: TimeInterval = 1_000
    }

    private func reports() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { !$0.lastPathComponent.hasSuffix(".sample.txt") }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func testALateAnswerWritesTheNotedStateAndSamplesTheStacks() throws {
        let recorder = HangRecorder()
        let clock = Clock()
        recorder.clock = { clock.now }
        recorder.sample = { pid, output in try? "stacks of \(pid)".write(to: output, atomically: true, encoding: .utf8) }
        recorder.configure(directory: directory, policy: HangPolicy(threshold: 3, spacing: 20, kept: 20))
        recorder.note("Main window: full screen, 3440 × 1440 points")

        // The question goes to the main queue, which this test does not turn: a main thread that is busy.
        recorder.tick()
        clock.now += 2
        recorder.tick()
        XCTAssertTrue(reports().isEmpty, "Two seconds of silence is not a hang yet")
        clock.now += 1.5
        recorder.tick()

        let report = try XCTUnwrap(reports().first)
        let text = try String(contentsOf: report, encoding: .utf8)
        XCTAssertTrue(text.contains("had not answered for 3.5 seconds"), text)
        XCTAssertTrue(text.contains("Main window: full screen, 3440 × 1440 points"), text)
        XCTAssertTrue(text.contains("3.5 seconds before this was written"), "The note's age is given: \(text)")
        let stacks = report.deletingPathExtension().appendingPathExtension("sample.txt")
        XCTAssertEqual(try String(contentsOf: stacks, encoding: .utf8), "stacks of \(ProcessInfo.processInfo.processIdentifier)")
        XCTAssertTrue(text.contains(stacks.lastPathComponent), "The report names its sample")

        // The main thread comes back: the report says how long the hang lasted.
        clock.now += 6
        let answered = expectation(description: "the pending question is answered")
        DispatchQueue.main.async { answered.fulfill() }
        wait(for: [answered], timeout: 5)
        XCTAssertTrue(try String(contentsOf: report, encoding: .utf8).contains("answered again after 9.5 seconds"))
        XCTAssertEqual(reports().count, 1)
    }

    func testOnlyTheNewestReportsAreKept() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for index in 0..<25 {
            let name = String(format: "hang-20261005-1200%02d", index)
            try "report".write(to: directory.appendingPathComponent(name + ".txt"), atomically: true, encoding: .utf8)
            try "stacks".write(to: directory.appendingPathComponent(name + ".sample.txt"), atomically: true, encoding: .utf8)
        }
        try "kept".write(to: directory.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        HangRecorder.prune(directory, keeping: 20)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        XCTAssertEqual(names.filter { $0.hasSuffix(".sample.txt") }.count, 20)
        XCTAssertEqual(names.filter { $0.hasPrefix("hang-") && !$0.hasSuffix(".sample.txt") }.count, 20)
        XCTAssertFalse(names.contains("hang-20261005-120004.txt"), "The oldest go first")
        XCTAssertTrue(names.contains("hang-20261005-120024.sample.txt"))
        XCTAssertTrue(names.contains("notes.txt"), "Other files are left alone")
    }
}
