import AppKit
import SwiftUI
import XCTest
@testable import GrokDesktop

/// The expected values below were produced by the terminal's own sources (`xai-grok-gboom` game.rs,
/// engine.rs, assets.rs, compiled unmodified into a small harness): RNG streams, texture and frame
/// hashes (FNV-1a over the RGB8 buffer), and scripted simulation results. The port is bit-exact.
final class GboomTests: XCTestCase {
    private func fnv(_ bytes: [UInt8]) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in bytes { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        return hash
    }

    private func textureHash(_ texture: GboomTexture) -> UInt64 { fnv(texture.pixels.flatMap { [$0.r, $0.g, $0.b] }) }

    private func render(_ game: GboomGame, _ width: Int = 480, _ height: Int = 320) -> GboomFrameBuffer {
        let fb = GboomFrameBuffer()
        fb.resize(width, height)
        GboomRenderer().renderGame(fb, game)
        return fb
    }

    // MARK: Map and randomness

    func testMapParsesLikeTheTerminal() {
        let game = GboomGame()
        XCTAssertEqual(game.map.width, 22)
        XCTAssertEqual(game.map.height, 22)
        XCTAssertEqual(game.totalImps, 9)
        XCTAssertEqual(game.player.x, 1.5)
        XCTAssertEqual(game.player.y, 1.5)
        XCTAssertEqual(game.player.angle, 0)
        XCTAssertEqual(game.player.hp, 100)
        XCTAssertEqual(game.map.cell(0, 0), 1, "brick")
        XCTAssertEqual(game.map.cell(10, 1), 2, "stone")
        XCTAssertEqual(game.map.cell(12, 2), 3, "tech")
        XCTAssertEqual(game.map.cell(1, 10), 4, "hellstone")
        XCTAssertEqual(game.map.cell(1, 1), 0, "the player start is floor")
        XCTAssertEqual(game.map.cell(19, 2), 0, "imp spawns are floor")
        XCTAssertEqual(game.map.cell(-1, 4), 1, "out of bounds is solid")
        XCTAssertEqual(game.map.cell(4, 22), 1)
        let spawns = game.imps.map { [$0.x, $0.y] }
        XCTAssertEqual(spawns, [[19.5, 2.5], [9.5, 4.5], [14.5, 4.5], [11.5, 8.5], [2.5, 12.5], [18.5, 12.5], [4.5, 16.5], [11.5, 16.5], [18.5, 17.5]])
        XCTAssertTrue(game.imps.allSatisfy { $0.state == .idle && $0.hp == 30 })
        XCTAssertEqual(game.imps[0].anim, Float(19 * 7 + 2 * 13) * 0.1, "walk cycles are desynchronised by spawn cell")

        for i in 0..<22 {
            XCTAssertTrue(game.map.solid(i, 0) && game.map.solid(i, 21) && game.map.solid(0, i) && game.map.solid(21, i))
        }
        // Every imp is reachable from the start (the terminal's flood-fill guard).
        var reachable = Set<Int>(), stack = [(1, 1)]
        while let (x, y) = stack.popLast() {
            guard !game.map.solid(x, y), reachable.insert(y * 22 + x).inserted else { continue }
            stack += [(x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)]
        }
        for imp in game.imps { XCTAssertTrue(reachable.contains(Int(imp.y) * 22 + Int(imp.x))) }
    }

    func testXorShiftMatchesTheRustStreams() {
        var game = GboomXorShift64(seed: 0x9E37_79B9_7F4A_7C15)
        XCTAssertEqual((0..<6).map { _ in game.nextU32() }, [113_367_537, 711_075_388, 1_411_578_273, 1_052_181_955, 1_215_064_946, 1_324_574_599])
        var fire = GboomXorShift64(seed: 0xDEAD_BEEF_CAFE_F00D)
        XCTAssertEqual((0..<6).map { _ in fire.nextU32() }, [682_010_465, 1_040_411_035, 1_335_848_244, 430_658_038, 1_716_216_368, 328_405_067])
        var zero = GboomXorShift64(seed: 0)
        XCTAssertEqual(zero.state, 1, "a zero seed would be a fixed point")
        XCTAssertEqual((0..<6).map { _ in zero.nextU32() }, [603_088_677, 1_441_256_276, 1_558_742_727, 651_824_208, 120_638_680, 1_681_106_405])
        var floats = GboomXorShift64(seed: 0x9E37_79B9_7F4A_7C15)
        XCTAssertEqual((0..<4).map { _ in floats.nextFloat() }, [0.02639538, 0.16556013, 0.32865864, 0.24498016])
    }

    func testTexturesMatchTheTerminal() {
        let walls = GboomTexture.walls()
        XCTAssertEqual(walls.map(textureHash), [0xb26d_0732_1c8e_1a6a, 0xfc3b_8445_c398_8722, 0x357f_aad7_e61b_3422, 0x2d8a_5c77_fd25_7053])
        XCTAssertEqual(textureHash(GboomTexture.floor()), 0xf1cb_9a6f_b543_1176)
        XCTAssertEqual(textureHash(GboomTexture.ceiling()), 0x768e_ec35_b15c_2ed1)
        let imps = GboomImpSprites()
        for sprite in [imps.walkA, imps.walkB, imps.attack, imps.pain, imps.dieA, imps.dieB, imps.corpse] {
            XCTAssertEqual(sprite.width, 16)
            XCTAssertEqual(sprite.height, 20)
        }
        XCTAssertEqual(GboomGunSprites().idle.width, 24)
        XCTAssertEqual(GboomGunSprites().fire.height, 18)
        for text in ["GBOOM", "KNEE-DEEP IN THE TOKENS", "PRESS ANY KEY", "YOU DIED", "VICTORY!", "PAUSED"] {
            for character in text where character != " " { XCTAssertNotEqual(gboomGlyph(character), [0, 0, 0, 0, 0, 0, 0], "\(character)") }
        }
    }

    // MARK: Simulation

    func testWalkingAndTurningMatchesTheTerminal() {
        let dt: Float = 1.0 / 30.0
        var game = GboomGame()
        game.releaseAware = true
        game.press(.forward)
        game.press(.turnRight)
        for _ in 0..<20 { game.step(dt) }
        game.release(.turnRight)
        for _ in 0..<40 { game.step(dt) }
        XCTAssertEqual(game.player.x, 3.3675947)
        XCTAssertEqual(game.player.y, 3.799179)
        XCTAssertEqual(game.player.angle, 1.4666669)
        XCTAssertEqual(game.player.velForward, 3.2999997)
        XCTAssertEqual(game.player.velRot, 1.1752062e-8)
        XCTAssertEqual(game.player.bob, 6.3871946)
        XCTAssertEqual(fnv(render(game).pixels), 0x48ba_750b_0d85_2ba3)
    }

    func testImpWakesBitesDiesAndKillingEveryImpWins() {
        let dt: Float = 1.0 / 30.0
        var game = GboomGame()
        game.releaseAware = true
        game.imps[0].x = 3.5
        game.imps[0].y = 1.5
        var sawChase = false, sawWindup = false
        for frame in 0..<60 {
            game.step(dt)
            sawChase = sawChase || game.imps[0].state == .chasing
            if case .attacking = game.imps[0].state { sawWindup = true }
            if frame == 44 { XCTAssertEqual(fnv(render(game).pixels), 0xd653_07f6_4beb_44f4, "mid-fight frame") }
        }
        XCTAssertTrue(sawChase, "the imp woke on sight")
        XCTAssertTrue(sawWindup, "the imp wound up a bite")
        XCTAssertEqual(game.player.hp, 93, "one bite of 7 + roll")
        XCTAssertEqual(game.imps[0].x, 2.4149985)
        XCTAssertEqual(game.imps[0].state, .chasing)
        XCTAssertEqual(game.kills, 0)

        var frames = 0
        while game.imps[0].alive && frames < 200 { game.queueFire(); game.step(dt); frames += 1 }
        XCTAssertEqual(frames, 21)
        XCTAssertEqual(game.imps[0].hp, -7)
        XCTAssertEqual(game.kills, 1)
        guard case .dying(let t) = game.imps[0].state else { return XCTFail("expected dying, got \(game.imps[0].state)") }
        XCTAssertEqual(t, 0.5167, accuracy: 0.0001)
        XCTAssertEqual(fnv(render(game).pixels), 0x9a86_4892_626d_b5a1)

        var framesPerImp: [Int] = []
        for index in 1..<game.imps.count {
            let (dx, dy) = game.player.direction
            game.imps[index].x = game.player.x + dx * 2
            game.imps[index].y = game.player.y + dy * 2
            game.imps[index].state = .idle
            var count = 0
            while game.imps[index].alive && count < 300 { game.queueFire(); game.step(dt); count += 1 }
            framesPerImp.append(count)
        }
        XCTAssertEqual(framesPerImp, [30, 30, 30, 30, 30, 30, 30, 30])
        var settle = 0
        while !game.imps.allSatisfy({ $0.state == .dead }) && settle < 100 { game.step(dt); settle += 1 }
        XCTAssertEqual(settle, 16)
        XCTAssertEqual(game.kills, 9)
        XCTAssertTrue(game.won)
        XCTAssertFalse(game.dead)
        XCTAssertEqual(game.player.hp, 93)
        XCTAssertEqual(game.time, 11.23337)
        XCTAssertEqual(game.imps.map(\.hp), [-7, -8, -7, -5, -7, -5, -7, -7, -8], "pistol damage is 11 + a 0–6 roll")
        XCTAssertEqual(fnv(render(game).pixels), 0x5e7a_7c54_c8f1_459f)
    }

    func testPistolRespectsCooldownAndLineOfSight() {
        var game = GboomGame()
        let (dx, dy) = game.player.direction
        game.imps[0].x = game.player.x + dx * 2
        game.imps[0].y = game.player.y + dy * 2
        XCTAssertEqual(game.targetInCrosshair(), 0)
        game.queueFire()
        game.step(0.016)
        let afterFirst = game.imps[0].hp
        XCTAssertLessThan(afterFirst, 30)
        guard case .pain = game.imps[0].state else { return XCTFail("a surviving imp flinches") }
        game.queueFire()
        game.step(0.016)
        XCTAssertEqual(game.imps[0].hp, afterFirst, "the second shot is swallowed by the cooldown")
        // Behind the start room's east wall the imp cannot be hit.
        game.imps[0].x = 6.5
        game.imps[0].y = 1.5
        XCTAssertNil(game.targetInCrosshair())
    }

    func testRaycastDistances() {
        var game = GboomGame()
        // Facing +x from (1.5, 1.5) the brick wall at x = 5 is 3.5 away; facing +y the first wall is at y = 10.
        XCTAssertEqual(render(game).depth[240], 3.5)
        game.player.angle = .pi / 2
        XCTAssertEqual(render(game).depth[240], 8.5, accuracy: 1e-4)
        XCTAssertTrue(game.map.lineOfSight(1.5, 1.5, 2.5, 2.5))
        XCTAssertFalse(game.map.lineOfSight(1.5, 1.5, 20.5, 20.5))
        XCTAssertTrue(game.map.blocked(1.1, 1.5, radius: 0.2), "the border wall stops a circle")
        XCTAssertFalse(game.map.blocked(1.5, 1.5, radius: 0.2))
    }

    func testMovementGlidesToRestWithoutReleaseEvents() {
        var game = GboomGame()
        game.press(.forward)
        game.press(.turnRight)
        for _ in 0..<120 { game.step(1.0 / 30.0) }
        XCTAssertLessThan(abs(game.player.velForward), 0.01)
        XCTAssertLessThan(abs(game.player.velRot), 0.01)

        var latched = GboomGame()
        latched.releaseAware = true
        latched.press(.forward)
        latched.press(.turnLeft)
        for _ in 0..<30 { latched.step(1.0 / 30.0) }
        XCTAssertGreaterThan(latched.player.velForward, 1)
        XCTAssertLessThan(latched.player.angle, 0)
        latched.releaseAll()
        XCTAssertFalse(latched.anyHeld)
    }

    // MARK: Frames

    func testGameFramesMatchTheTerminalRenderer() {
        XCTAssertEqual(fnv(render(GboomGame()).pixels), 0x1699_3d70_b58b_f007)
        XCTAssertEqual(fnv(render(GboomGame(), 173, 97).pixels), 0x42a0_8104_6640_c923)

        var corridor = GboomGame()
        corridor.player.x = 20.5
        corridor.player.y = 7.5
        corridor.player.angle = -.pi / 2 - 0.12
        corridor.player.hp = 20
        corridor.player.muzzle = 0.05
        corridor.imps[0].state = .pain(t: 0.2)
        corridor.time = 0.7
        corridor.player.bob = 1.3
        XCTAssertEqual(fnv(render(corridor).pixels), 0x3e33_f82e_ddaa_23e8)

        XCTAssertEqual(fnv(render(effectsScene()).pixels), 0x268b_accd_095f_1911, "pain, dying, walking, corpse, muzzle, damage, low health")
    }

    /// Every sprite state and screen effect at once.
    private func effectsScene() -> GboomGame {
        var game = GboomGame()
        game.imps[0].x = 3.0; game.imps[0].y = 1.6; game.imps[0].state = .pain(t: 0.2)
        game.imps[1].x = 3.6; game.imps[1].y = 1.2; game.imps[1].state = .dying(t: 0.2)
        game.imps[2].x = 2.8; game.imps[2].y = 2.4; game.imps[2].state = .chasing
        game.imps[3].x = 4.4; game.imps[3].y = 2.2; game.imps[3].state = .dead
        game.player.hp = 20
        game.player.damageFlash = 0.5
        game.player.muzzle = 0.05
        game.player.bob = 1.3
        game.time = 0.7
        return game
    }

    private func titleSession() -> GboomSession {
        let session = GboomSession(clock: { 0 })
        for _ in 0..<45 { session.advance(0.004) }
        return session
    }

    func testTitleAndEndScreensMatchTheTerminal() {
        let session = titleSession()
        XCTAssertEqual(session.phase, .title)
        session.render(width: 480, height: 320)
        XCTAssertEqual(fnv(session.framebuffer.pixels), 0x9824_b8d9_afbd_a4bc)
        session.render(width: 173, height: 97)
        XCTAssertEqual(fnv(session.framebuffer.pixels), 0x757c_5461_7311_9ab1)

        // Death: the fire takes two more steps while the end screen's clock reaches 1.3 s.
        session.handleKeyDown(.character("x"))
        session.game.player.hp = 0
        session.advance(0.01)
        XCTAssertEqual(session.phase, .dead)
        session.advance(0.65)
        session.advance(0.65)
        session.render(width: 480, height: 320)
        XCTAssertEqual(fnv(session.framebuffer.pixels), 0x8d5e_8c83_7e5c_ac93)

        let victory = titleSession()
        victory.handleKeyDown(.space)
        for index in victory.game.imps.indices { victory.game.imps[index].state = .dead }
        victory.game.kills = victory.game.totalImps
        victory.advance(0.01)
        XCTAssertEqual(victory.phase, .won)
        victory.advance(0.25)
        victory.advance(0.25)
        victory.render(width: 480, height: 320)
        XCTAssertEqual(fnv(victory.framebuffer.pixels), 0x11f6_2108_207d_b693)
    }

    // MARK: Session

    func testAnyKeyStartsAndEscOrQQuitsInEveryPhase() {
        let session = GboomSession(clock: { 0 })
        XCTAssertEqual(session.handleKeyDown(.character("w"), isRepeat: true), .changed)
        XCTAssertEqual(session.phase, .title, "an auto-repeat does not start the game")
        XCTAssertEqual(session.handleKeyDown(.character("w")), .changed)
        XCTAssertEqual(session.phase, .playing)
        XCTAssertFalse(session.game.anyHeld, "the key that starts the game is not also a move")
        for key in [GboomKey.escape, .character("q"), .character("Q")] {
            XCTAssertEqual(GboomSession(clock: { 0 }).handleKeyDown(key), .close)
            XCTAssertEqual(session.handleKeyDown(key), .close)
        }
    }

    func testKeysLatchUntilReleasedAndFocusLossReleasesThem() {
        let session = GboomSession(clock: { 0 })
        session.handleKeyDown(.space)
        session.handleKeyDown(.character("W"))
        session.handleKeyDown(.left)
        for _ in 0..<30 { session.advance(1.0 / 30.0) }
        XCTAssertGreaterThan(session.game.player.velForward, 1)
        XCTAssertLessThan(session.game.player.angle, 0)
        session.handleKeyUp(.character("w"))
        for _ in 0..<30 { session.advance(1.0 / 30.0) }
        XCTAssertLessThan(abs(session.game.player.velForward), 0.2)
        XCTAssertLessThan(session.game.player.velRot, -0.1, "turning is still held")
        session.releaseAll()
        XCTAssertFalse(session.game.anyHeld)

        session.handleKeyDown(.enter)
        session.advance(0.01)
        XCTAssertGreaterThan(session.game.player.muzzle, 0, "Enter fires")
    }

    func testEndScreensHaveAGracePeriod() {
        let session = GboomSession(clock: { 0 })
        session.handleKeyDown(.space)
        session.game.player.hp = 0
        session.advance(0.01)
        XCTAssertEqual(session.phase, .dead)
        session.advance(0.1)
        XCTAssertEqual(session.handleKeyDown(.space), .changed, "keys are swallowed for 0.8 s")
        session.advance(0.8)
        XCTAssertEqual(session.handleKeyDown(.space, isRepeat: true), .changed, "a held key does not dismiss")
        XCTAssertEqual(session.handleKeyDown(.space), .close)
    }

    func testWinWaitsForTheLastDeathAnimation() {
        let session = GboomSession(clock: { 0 })
        session.handleKeyDown(.space)
        for index in session.game.imps.indices { session.game.imps[index].state = .dead }
        session.game.imps[8].state = .dying(t: 0.2)
        session.game.kills = session.game.totalImps
        session.advance(0.1)
        XCTAssertEqual(session.phase, .playing)
        session.advance(0.1)
        session.advance(0.1)
        XCTAssertEqual(session.phase, .won)
    }

    func testMouseAimsAndClicksFireOnlyWhilePlaying() {
        let session = GboomSession(clock: { 0 })
        session.aim(columns: 5)
        session.click()
        session.advance(0.01)
        XCTAssertEqual(session.game.player.angle, 0, "the title screen ignores the mouse")
        XCTAssertEqual(session.game.player.muzzle, 0)
        session.handleKeyDown(.space)
        session.aim(columns: 5)
        XCTAssertEqual(session.game.player.angle, 5 * 0.06)
        session.aim(columns: -3)
        XCTAssertEqual(session.game.player.angle, 2 * 0.06, accuracy: 1e-5)
        session.aim(columns: 13)
        XCTAssertEqual(session.game.player.angle, 2 * 0.06, accuracy: 1e-5, "jumps over 12 columns are ignored")
        session.click()
        session.advance(0.01)
        XCTAssertGreaterThan(session.game.player.muzzle, 0)
    }

    func testClockStepsAreCappedAndResetOnStart() {
        var now: TimeInterval = 100
        let session = GboomSession(clock: { now })
        session.handleKeyDown(.space)
        now += 5
        session.tick()
        XCTAssertEqual(session.game.time, 0.1, accuracy: 1e-6, "long gaps are clamped to 0.1 s")
        now += 0.02
        session.tick()
        XCTAssertEqual(session.game.time, 0.12, accuracy: 1e-5)
        now += 3
        session.resetClock()
        session.tick()
        XCTAssertEqual(session.game.time, 0.12, accuracy: 1e-5, "a pause does not count")
    }

    @MainActor
    func testGameViewMapsKeyEventsToGameInput() throws {
        func event(_ type: NSEvent.EventType, _ characters: String, _ keyCode: UInt16, repeating: Bool = false) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                           characters: characters, charactersIgnoringModifiers: characters, isARepeat: repeating, keyCode: keyCode))
        }
        XCTAssertEqual(GboomGameNSView.key(for: try event(.keyDown, "\u{F700}", 126)), .up)
        XCTAssertEqual(GboomGameNSView.key(for: try event(.keyDown, "\u{F702}", 123)), .left)
        XCTAssertEqual(GboomGameNSView.key(for: try event(.keyDown, "\u{1B}", 53)), .escape)
        XCTAssertEqual(GboomGameNSView.key(for: try event(.keyDown, " ", 49)), .space)
        XCTAssertEqual(GboomGameNSView.key(for: try event(.keyDown, "\r", 36)), .enter)
        XCTAssertEqual(GboomGameNSView.key(for: try event(.keyDown, "d", 2)), .character("d"))

        let view = GboomGameNSView(frame: CGRect(x: 0, y: 0, width: 480, height: 320))
        view.keyDown(with: try event(.keyDown, "w", 13))
        XCTAssertEqual(view.session.phase, .playing)
        view.keyDown(with: try event(.keyDown, "w", 13, repeating: true))
        XCTAssertTrue(view.session.game.anyHeld, "holding W walks")
        view.keyUp(with: try event(.keyUp, "w", 13))
        XCTAssertFalse(view.session.game.anyHeld)
        view.keyDown(with: try event(.keyDown, "a", 0))
        XCTAssertTrue(view.resignFirstResponder())
        XCTAssertFalse(view.session.game.anyHeld, "losing focus releases held keys")
    }

    /// The view's lifecycle in a real window: it runs while its window is key, pauses when it is not,
    /// and Esc closes the window. (Test windows never become key, so the notifications are posted.)
    @MainActor
    func testGameViewRunsWhileKeyPausesOtherwiseAndEscCloses() throws {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 480, height: 320), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = GboomGameNSView(frame: window.contentLayoutRect)
        var statuses: [(GboomHUD, Bool)] = []
        view.onStatus = { statuses.append(($0, $1)) }
        window.contentView = view
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertTrue(view.paused, "a window that is not key does not run the game")
        XCTAssertEqual(view.session.phaseTime, 0)

        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))
        XCTAssertFalse(view.paused)
        XCTAssertGreaterThan(view.session.phaseTime, 0.2, "the title screen animates while key")
        XCTAssertEqual(view.session.framebuffer.width, 480)

        let space = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                                   context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
        view.keyDown(with: space)
        let w = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                               context: nil, characters: "w", charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13))
        view.keyDown(with: w)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertGreaterThan(view.session.game.player.x, 1.5, "holding W walks")
        XCTAssertEqual(statuses.last?.0.playing, true)

        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(view.paused)
        XCTAssertFalse(view.session.game.anyHeld, "keys are released when focus leaves")
        let time = view.session.game.time
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(view.session.game.time, time, "paused")
        XCTAssertEqual(statuses.last?.1, true)

        window.orderFront(nil)
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                                    context: nil, characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53))
        view.keyDown(with: escape)
        XCTAssertFalse(window.isVisible, "Esc closes the window")
    }

    func testHUDMatchesTheTerminalOverlay() {
        var hud = GboomHUD(hp: 100, kills: 0, total: 9, playing: true)
        XCTAssertEqual(hud.statsText, " HP 100 · KILLS 0/9 ")
        XCTAssertEqual(hud.hint, " WASD/←→ move · SPACE fire · ESC quit ")
        XCTAssertEqual(hud.healthColor, GboomRGB(126, 200, 96))
        hud.hp = 7; hud.kills = 3; hud.playing = false
        XCTAssertEqual(hud.statsText, " HP 7   · KILLS 3/9 ")
        XCTAssertEqual(hud.hint, " ESC quit ")
        XCTAssertEqual(hud.healthColor, GboomPalette.red)
        hud.hp = 45
        XCTAssertEqual(hud.healthColor, GboomRGB(235, 198, 82))
        XCTAssertEqual(GboomSession(clock: { 0 }).hud, GboomHUD(hp: 100, kills: 0, total: 9, playing: false))
    }

    func testFrameSizeFollowsTheViewInsideTheCap() {
        XCTAssertTrue(GboomSession.frameSize(for: CGSize(width: 960, height: 640)) == (480, 320))
        XCTAssertTrue(GboomSession.frameSize(for: CGSize(width: 1200, height: 400)) == (480, 160))
        XCTAssertTrue(GboomSession.frameSize(for: CGSize(width: 300, height: 600)) == (160, 320))
        let tiny = GboomSession.frameSize(for: CGSize(width: 1, height: 1))
        XCTAssertTrue(tiny.width >= 64 && tiny.height >= 64)
        let session = GboomSession(clock: { 0 })
        session.render(width: 480, height: 320)
        let image = session.makeImage()
        XCTAssertEqual(image?.width, 480)
        XCTAssertEqual(image?.height, 320)
    }

    /// One 480×320 gameplay frame. Debug builds are several times slower than release, so this only
    /// guards against pathological regressions; run `swift test -c release -Xswiftc -enable-testing
    /// --filter GboomTests/testRenderCost` to see the real cost (under 8 ms is the target).
    func testRenderCost() {
        let session = GboomSession(clock: { 0 })
        session.handleKeyDown(.space)
        session.game = effectsScene()
        session.render(width: 480, height: 320)
        let start = Date()
        let frames = 20
        for _ in 0..<frames { session.render(width: 480, height: 320); _ = session.makeImage() }
        let perFrame = Date().timeIntervalSince(start) / Double(frames)
        print("GBOOM frame cost: \(String(format: "%.2f", perFrame * 1000)) ms")
        XCTAssertLessThan(perFrame, 0.25)
    }

    // MARK: Snapshots

    /// Writes the frames and the window when GROK_DESKTOP_SNAPSHOT_DIR is set, for visual review.
    @MainActor
    func testRenderGboomSnapshots() throws {
        guard let output = ProcessInfo.processInfo.environment["CROK_DESKTOP_SNAPSHOT_DIR"] else { throw XCTSkip("Set CROK_DESKTOP_SNAPSHOT_DIR to render snapshots") }
        let directory = URL(fileURLWithPath: output)
        func write(_ session: GboomSession, _ name: String, paused: Bool = false) throws {
            session.render(width: 480, height: 320, paused: paused)
            let image = try XCTUnwrap(session.makeImage())
            let bitmap = NSBitmapImageRep(cgImage: image)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name + ".png"))
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let title = titleSession()
        try write(title, "gboom-title")
        let game = GboomSession(clock: { 0 })
        game.handleKeyDown(.space)
        game.game = effectsScene()
        try write(game, "gboom-effects")
        game.game = GboomGame()
        try write(game, "gboom-start")
        try write(game, "gboom-paused", paused: true)
        let dead = titleSession()
        dead.handleKeyDown(.space)
        dead.game.player.hp = 0
        dead.advance(0.01)
        dead.advance(1.3)
        try write(dead, "gboom-dead")
        let won = titleSession()
        won.handleKeyDown(.space)
        for index in won.game.imps.indices { won.game.imps[index].state = .dead }
        won.game.kills = won.game.totalImps
        won.advance(0.01)
        won.advance(1.3)
        try write(won, "gboom-won")

        try SnapshotRenderer.write(GboomWindow().frame(width: 960, height: 670), size: CGSize(width: 960, height: 670), appearance: .aqua,
                                   to: directory.appendingPathComponent("gboom-window-full.png"))
        for (name, appearance) in [("gboom-window-light", NSAppearance.Name.aqua), ("gboom-window-dark", .darkAqua)] {
            let bar = VStack(spacing: 0) {
                Color.black
                GboomStatusBar(hud: GboomHUD(hp: 42, kills: 3, total: 9, playing: true), paused: false)
                GboomStatusBar(hud: GboomHUD(hp: 100, kills: 0, total: 9, playing: false), paused: true)
            }
            try SnapshotRenderer.write(bar.frame(width: 720, height: 120), size: CGSize(width: 720, height: 120), appearance: appearance,
                                       to: directory.appendingPathComponent(name + ".png"))
        }
    }
}
