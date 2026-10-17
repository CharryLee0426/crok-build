import AppKit
import XCTest
@testable import GrokDesktop

/// The desktop's own look (`Atelier.swift`): which thinking orb a turn's phase shows, the metal
/// finish setting, and the effects switch.
@MainActor
final class AtelierTests: XCTestCase {
    private var savedFinish: String?
    private var savedEffects: Any?

    override func setUp() {
        savedFinish = UserDefaults.standard.string(forKey: MetalFinish.key)
        savedEffects = UserDefaults.standard.object(forKey: EffectsPreference.key)
    }

    override func tearDown() {
        let defaults = UserDefaults.standard
        if let savedFinish { defaults.set(savedFinish, forKey: MetalFinish.key) } else { defaults.removeObject(forKey: MetalFinish.key) }
        if let savedEffects { defaults.set(savedEffects, forKey: EffectsPreference.key) } else { defaults.removeObject(forKey: EffectsPreference.key) }
    }

    func testAPhaseShowsTheOrbForWhatTheTurnDoes() {
        XCTAssertEqual(AgentActivity.phase("Thinking…"), .thinking)
        XCTAssertEqual(AgentActivity.phase("Reasoning"), .thinking)
        XCTAssertEqual(AgentActivity.phase("Reading files…"), .searching)
        XCTAssertEqual(AgentActivity.phase("Searching the web"), .searching)
        XCTAssertEqual(AgentActivity.phase("Writing the reply"), .writing)
        XCTAssertEqual(AgentActivity.phase("Editing App.swift"), .writing)
        XCTAssertEqual(AgentActivity.phase("Connecting…"), .connecting)
        XCTAssertEqual(AgentActivity.phase("Working…"), .working)
        XCTAssertEqual(AgentActivity.phase("Waiting for your response"), .working)
        // Each activity has its own orb.
        let orbs = [AgentActivity.thinking, .working, .searching, .writing, .connecting, .listening].map(\.orb)
        XCTAssertEqual(Set(orbs.map(\.rawValue)).count, orbs.count)
    }

    func testTheFinishDefaultsToChampagneAndRebuildsTheWindow() throws {
        UserDefaults.standard.removeObject(forKey: MetalFinish.key)
        XCTAssertEqual(MetalFinish.current, .champagne)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("atelier-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(stateFile: directory.appendingPathComponent("state.json"), binaryPath: "/usr/bin/false")
        defer { store.shutdown() }
        let extras = store.features.extras
        let revision = extras.themeRevision
        extras.setMetalFinish(.champagne)
        XCTAssertEqual(extras.themeRevision, revision, "choosing the finish already in use rebuilds nothing")
        extras.setMetalFinish(.platinum)
        XCTAssertEqual(MetalFinish.current, .platinum)
        XCTAssertGreaterThan(extras.themeRevision, revision)
        // The reasoning sweep takes the finish too, and still ends as it begins.
        let sweep = ThinkingPalette.nsColors
        XCTAssertEqual(sweep, MetalFinish.platinum.sweepNS)
        XCTAssertEqual(sweep.first, sweep.last)
    }

    func testEveryFinishMapsToItsOwnMetal() {
        XCTAssertEqual(Set(MetalFinish.allCases.map { "\($0.preset)" }).count, MetalFinish.allCases.count)
        XCTAssertEqual(Set(MetalFinish.allCases.map { "\($0.beam)" }).count, MetalFinish.allCases.count)
        XCTAssertEqual(Set(MetalFinish.allCases.map { "\($0.voice)" }).count, MetalFinish.allCases.count)
        for finish in MetalFinish.allCases { XCTAssertFalse(finish.displayName.isEmpty) }
    }

    func testTheEffectsAreOnUntilSwitchedOff() {
        UserDefaults.standard.removeObject(forKey: EffectsPreference.key)
        XCTAssertTrue(EffectsPreference.enabled)
        UserDefaults.standard.set(false, forKey: EffectsPreference.key)
        XCTAssertFalse(EffectsPreference.enabled)
    }
}
