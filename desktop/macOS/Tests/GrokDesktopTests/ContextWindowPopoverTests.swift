import AppKit
import SwiftUI
import XCTest
@testable import GrokDesktop

final class ContextWindowPopoverTests: XCTestCase {
    private func snapshot(used: UInt64, total: UInt64, system: UInt64, messages: UInt64) -> UsageContextSnapshot {
        var snapshot = UsageContextSnapshot()
        snapshot.used = used
        snapshot.total = total
        snapshot.systemPromptTokens = system
        snapshot.messageTokens = messages
        snapshot.usagePercent = total == 0 ? 0 : used * 100 / total
        return snapshot
    }

    func testTheBreakdownDividesTheRing() throws {
        let figures = ContextWindowFigures(snapshot: snapshot(used: 100_000, total: 200_000, system: 10_000, messages: 80_000), usage: nil)
        XCTAssertEqual(figures.legend.map(\.label), ["System prompt", "Messages", "Reasoning/overhead", "Free"])
        XCTAssertEqual(figures.legend.map(\.tokens), [10_000, 80_000, 10_000, 100_000])
        XCTAssertEqual(try XCTUnwrap(figures.fraction), 0.5, accuracy: 0.0001)
        let arcs = figures.arcs
        XCTAssertEqual(arcs.map(\.id), ["System prompt", "Messages", "Reasoning/overhead"], "free space is the track, not an arc")
        XCTAssertEqual(try XCTUnwrap(arcs.first).start, 0, "the first arc starts at the top")
        XCTAssertEqual(try XCTUnwrap(arcs.last).end, 0.5, accuracy: 0.0001, "the last ends where use does")
        for (left, right) in zip(arcs, arcs.dropFirst()) {
            XCTAssertLessThan(left.end, right.start, "arcs are a hair apart")
            XCTAssertLessThan(right.start - left.end, 0.01)
        }
        XCTAssertEqual(try XCTUnwrap(figures.compactThreshold), 0.85, accuracy: 0.0001)
    }

    func testTheRingsOwnFigureStandsInUntilMeasured() throws {
        let coarse = ContextWindowFigures(snapshot: nil, usage: ContextUsage(used: 61_000, window: 256_000))
        XCTAssertEqual(coarse.legend.map(\.label), ["Used", "Free"])
        XCTAssertEqual(coarse.arcs.count, 1)
        XCTAssertNil(coarse.compactThreshold, "the threshold is known only from a measurement")
        // A model the catalog does not size.
        let unsized = ContextWindowFigures(snapshot: nil, usage: ContextUsage(used: 4_000))
        XCTAssertNil(unsized.fraction)
        XCTAssertTrue(unsized.arcs.isEmpty)
        XCTAssertEqual(unsized.legend.map(\.label), ["Used"])
        // Nothing at all yet.
        let none = ContextWindowFigures(snapshot: nil, usage: nil)
        XCTAssertNil(none.used)
        XCTAssertEqual(none.accessibilityValue, "Not measured yet")
        // A harness that sent no breakdown is not a breakdown.
        let empty = ContextWindowFigures(snapshot: UsageContextSnapshot(), usage: ContextUsage(used: 10, window: 100))
        XCTAssertNil(empty.snapshot)
        XCTAssertEqual(empty.legend.first?.label, "Used")
    }

    func testAContextPastItsWindowFillsTheRingAndNoMore() throws {
        let figures = ContextWindowFigures(snapshot: snapshot(used: 300_000, total: 200_000, system: 20_000, messages: 260_000), usage: nil)
        XCTAssertGreaterThan(try XCTUnwrap(figures.fraction), 1)
        XCTAssertLessThanOrEqual(try XCTUnwrap(figures.arcs.last).end, 1)
        XCTAssertEqual(figures.legend.last?.tokens, 0, "nothing is free")
    }
}

/// PNGs of the ring's popover, written when CROK_DESKTOP_SNAPSHOT_DIR is set.
@MainActor
final class ContextWindowPopoverSnapshotTests: XCTestCase {
    private var directory: URL!
    private var output: URL!

    override func setUpWithError() throws {
        guard let path = ProcessInfo.processInfo.environment["CROK_DESKTOP_SNAPSHOT_DIR"] else { throw XCTSkip("Set CROK_DESKTOP_SNAPSHOT_DIR to render snapshots") }
        output = URL(fileURLWithPath: path)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("grok-context-snapshots-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { if let directory { try? FileManager.default.removeItem(at: directory) } }

    func testThePopoverInEachState() throws {
        var measured = UsageContextSnapshot()
        measured.used = 84_200
        measured.total = 200_000
        measured.systemPromptTokens = 8_200
        measured.messageTokens = 70_100
        measured.usagePercent = 42
        measured.turnCount = 12
        measured.toolCallCount = 30
        var nearlyFull = measured
        nearlyFull.used = 182_000
        nearlyFull.messageTokens = 165_000
        nearlyFull.usagePercent = 91
        let states: [(String, ContextBreakdownState, ContextUsage?)] = [
            ("measured", ContextBreakdownState(snapshot: measured, model: "stealth/space-bunny-alpha"), nil),
            ("nearly-full", ContextBreakdownState(snapshot: nearlyFull, model: "anthropic/claude-sonnet-5"), nil),
            ("measuring", ContextBreakdownState(isLoading: true), ContextUsage(used: 61_000, window: 256_000)),
            ("skeleton", ContextBreakdownState(isLoading: true), nil),
            ("failed", ContextBreakdownState(error: "The task is still connecting. Try again when it is ready."), ContextUsage(used: 61_000, window: 256_000)),
        ]
        for (name, state, usage) in states {
            for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let store = AppStore(stateFile: directory.appendingPathComponent("state-\(UUID().uuidString).json"), binaryPath: "/usr/bin/false")
                let id = UUID()
                store.features.account.showPreviewState(contextBreakdown: (id, state))
                if let usage {
                    var context = UsageContextSnapshot()
                    context.used = UInt64(usage.used)
                    context.total = UInt64(usage.window ?? 0)
                    store.features.tokens.noteContext(context, conversationID: id)
                }
                let view = ContextWindowPopover(tokens: store.features.tokens, account: store.features.account, conversationID: id, catalogWindow: nil, openDetails: {})
                    .foregroundStyle(Theme.ink)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
                    .padding(16)
                try SnapshotRenderer.write(view, size: CGSize(width: 480, height: 340), appearance: appearance,
                                           to: output.appendingPathComponent("context-popover-\(name)-\(suffix).png"))
            }
        }
    }
}
