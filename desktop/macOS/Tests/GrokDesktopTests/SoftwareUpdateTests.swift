import XCTest
@testable import GrokDesktop

/// Check for Updates: the `crok upgrade --json` events and the sheet's phases, with a fake helper.
@MainActor
final class SoftwareUpdateTests: XCTestCase {
    private static let checkLine = ###"{"event":"check","current":"1.4.0","latest":"1.5.0","tag":"desktop-v1.5.0","page":"https://github.com/CharryLee0426/crok-build/releases/tag/desktop-v1.5.0","notes":"## Crok Desktop 1.5.0\n\nCheck for Updates.\n\n<details><summary>简体中文</summary>…</details>","updateAvailable":true,"target":"app","targetPath":"/Applications/Crok Desktop.app","asset":"Crok-Desktop-1.5.0-arm64-macOS26-SDK.dmg","unavailable":null}"###

    private func helper(executable: String? = "/tmp/crok",
                        run: @escaping @Sendable ([String]) async throws -> SoftwareUpdateHelper.Result = { _ in SoftwareUpdateHelper.Result(status: 0, lines: [], stderr: "") },
                        stream: @escaping @MainActor ([String], @escaping @Sendable (String) -> Void, @escaping @Sendable (Int32, String) -> Void) throws -> () -> Void = { _, _, _ in {} }
    ) -> SoftwareUpdateHelper {
        SoftwareUpdateHelper(executable: executable, run: run, stream: stream)
    }

    // MARK: Events

    func testEventsParse() {
        guard case .check(let check)? = SoftwareUpdateEvent.parse(Self.checkLine) else { return XCTFail("check event") }
        XCTAssertEqual(check.current, "1.4.0")
        XCTAssertEqual(check.latest, "1.5.0")
        XCTAssertTrue(check.updateAvailable)
        XCTAssertEqual(check.asset, "Crok-Desktop-1.5.0-arm64-macOS26-SDK.dmg")
        XCTAssertNil(check.unavailable)
        XCTAssertTrue(check.page.hasSuffix("desktop-v1.5.0"))

        XCTAssertEqual(SoftwareUpdateEvent.parse(#"{"event":"progress","bytes":1048576,"total":4194304}"#), .progress(bytes: 1_048_576, total: 4_194_304))
        XCTAssertEqual(SoftwareUpdateEvent.parse(#"{"event":"progress","bytes":5,"total":null}"#), .progress(bytes: 5, total: nil))
        XCTAssertEqual(SoftwareUpdateEvent.parse(#"{"event":"status","phase":"verify","message":"Verifying the download…"}"#), .status(phase: "verify", message: "Verifying the download…"))
        XCTAssertEqual(SoftwareUpdateEvent.parse(#"{"event":"ready","version":"1.5.0"}"#), .ready)
        XCTAssertEqual(SoftwareUpdateEvent.parse(#"{"event":"installed","version":"1.5.0","path":"/Applications/Crok Desktop.app"}"#), .installed(version: "1.5.0"))
        XCTAssertEqual(SoftwareUpdateEvent.parse(#"{"event":"error","message":"boom"}"#), .error("boom"))
        XCTAssertNil(SoftwareUpdateEvent.parse("not json"))
        XCTAssertNil(SoftwareUpdateEvent.parse(#"{"event":"unknown"}"#))
    }

    func testNotesSummaryKeepsTheEnglishPart() {
        let summary = SoftwareUpdateSheet.summary(of: "## 1.5.0\n\n\n- Check for Updates\n\n<details><summary>简体中文</summary>\n中文\n</details>")
        XCTAssertEqual(summary, "## 1.5.0\n\n- Check for Updates")
        XCTAssertNil(SoftwareUpdateSheet.summary(of: nil))
        XCTAssertNil(SoftwareUpdateSheet.summary(of: "  \n"))
    }

    // MARK: Checking

    func testUnpackagedBuildCannotUpdate() async {
        let model = SoftwareUpdateModel(helper: helper(executable: nil), currentVersion: "1.4.0")
        await model.check()
        guard case .unavailable = model.phase else { return XCTFail("\(model.phase)") }
    }

    func testCheckFindsAnUpdate() async {
        let seen = Recorder()
        let model = SoftwareUpdateModel(helper: helper(run: { arguments in
            seen.record(arguments)
            return SoftwareUpdateHelper.Result(status: 0, lines: ["noise", Self.checkLine], stderr: "")
        }), currentVersion: "1.4.0")
        await model.check()
        XCTAssertEqual(seen.calls, [["upgrade", "--check", "--json"]])
        guard case .available(let check) = model.phase else { return XCTFail("\(model.phase)") }
        XCTAssertEqual(check.latest, "1.5.0")
        XCTAssertTrue(model.canInstall)
        XCTAssertNotNil(model.lastChecked)
    }

    func testCheckReportsUpToDateAndFailures() async {
        let upToDate = Self.checkLine.replacingOccurrences(of: #""updateAvailable":true"#, with: #""updateAvailable":false"#)
        let model = SoftwareUpdateModel(helper: helper(run: { _ in SoftwareUpdateHelper.Result(status: 0, lines: [upToDate], stderr: "") }), currentVersion: "1.5.0")
        await model.check()
        XCTAssertEqual(model.phase, .upToDate)
        XCTAssertFalse(model.canInstall)

        let failing = SoftwareUpdateModel(helper: helper(run: { _ in SoftwareUpdateHelper.Result(status: 0, lines: [#"{"event":"error","message":"no network"}"#], stderr: "") }), currentVersion: "1.4.0")
        await failing.check()
        XCTAssertEqual(failing.phase, .failed("no network"))

        let crashing = SoftwareUpdateModel(helper: helper(run: { _ in SoftwareUpdateHelper.Result(status: 2, lines: [], stderr: "Error: boom") }), currentVersion: "1.4.0")
        await crashing.check()
        XCTAssertEqual(crashing.phase, .failed("Error: boom"))

        let throwing = SoftwareUpdateModel(helper: helper(run: { _ in throw DesktopError.message("missing") }), currentVersion: "1.4.0")
        await throwing.check()
        guard case .failed = throwing.phase else { return XCTFail("\(throwing.phase)") }
    }

    func testAReleaseWithoutAFileForThisMacCannotBeInstalled() async {
        let line = Self.checkLine.replacingOccurrences(of: #""unavailable":null"#, with: #""unavailable":"releases carry no crok for linux x86_64""#)
        let model = SoftwareUpdateModel(helper: helper(run: { _ in SoftwareUpdateHelper.Result(status: 0, lines: [line], stderr: "") }), currentVersion: "1.4.0")
        await model.check()
        guard case .available(let check) = model.phase else { return XCTFail("\(model.phase)") }
        XCTAssertEqual(check.unavailable, "releases carry no crok for linux x86_64")
        XCTAssertFalse(model.canInstall)
        model.install()
        guard case .available = model.phase else { return XCTFail("install must be refused") }
    }

    // MARK: Installing

    func testInstallStreamsProgressThenQuits() async {
        let seen = Recorder()
        let stopped = Recorder()
        var deliver: ((String) -> Void)?
        let model = SoftwareUpdateModel(helper: helper(run: { _ in
            SoftwareUpdateHelper.Result(status: 0, lines: [Self.checkLine], stderr: "")
        }, stream: { arguments, onLine, _ in
            seen.record(arguments)
            deliver = onLine
            return { stopped.record(["stop"]) }
        }), currentVersion: "1.4.0")
        let quits = Recorder()
        model.terminate = { quits.record(["quit"]) }
        await model.check()
        model.install()
        XCTAssertEqual(seen.calls.count, 1)
        XCTAssertEqual(seen.calls[0].prefix(2), ["upgrade", "--json"])
        XCTAssertEqual(seen.calls[0][2], "--wait-for-pid")
        XCTAssertEqual(seen.calls[0][3], String(ProcessInfo.processInfo.processIdentifier))
        XCTAssertEqual(seen.calls[0][4], "--relaunch")
        XCTAssertEqual(model.phase, .downloading(nil))
        XCTAssertTrue(model.isBusy)

        model.handle(#"{"event":"status","phase":"download","message":"Downloading…"}"#)
        XCTAssertEqual(model.phase, .downloading(nil))
        model.handle(#"{"event":"progress","bytes":50,"total":200}"#)
        XCTAssertEqual(model.phase, .downloading(0.25))
        model.handle(#"{"event":"status","phase":"verify","message":"Verifying the download…"}"#)
        XCTAssertEqual(model.phase, .installing("Verifying the download…"))
        model.handle(#"{"event":"ready","version":"1.5.0"}"#)
        XCTAssertEqual(quits.calls, [["quit"]])
        // Still running: the quit was cancelled, and the helper keeps waiting for the next quit.
        XCTAssertEqual(model.phase, .waitingToQuit)
        XCTAssertTrue(stopped.calls.isEmpty)
        model.quitAndInstall()
        XCTAssertEqual(quits.calls.count, 2)

        model.cancel()
        XCTAssertEqual(stopped.calls, [["stop"]])
        guard case .available = model.phase else { return XCTFail("\(model.phase)") }
        _ = deliver
    }

    func testInstallFailureFromTheHelper() async {
        var exit: ((Int32, String) -> Void)?
        let model = SoftwareUpdateModel(helper: helper(run: { _ in
            SoftwareUpdateHelper.Result(status: 0, lines: [Self.checkLine], stderr: "")
        }, stream: { _, _, onExit in
            exit = onExit
            return {}
        }), currentVersion: "1.4.0")
        await model.check()
        model.install()
        model.handle(#"{"event":"error","message":"SHA256SUMS.txt is not signed by a crok release key"}"#)
        XCTAssertEqual(model.phase, .failed("SHA256SUMS.txt is not signed by a crok release key"))
        XCTAssertFalse(model.isBusy)

        // An exit without an error event still reports the failure.
        let silent = SoftwareUpdateModel(helper: helper(run: { _ in
            SoftwareUpdateHelper.Result(status: 0, lines: [Self.checkLine], stderr: "")
        }, stream: { _, _, onExit in
            exit = onExit
            return {}
        }), currentVersion: "1.4.0")
        await silent.check()
        silent.install()
        exit?(1, "Error: hdiutil failed")
        await Task.yield()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(silent.phase, .failed("Error: hdiutil failed"))
    }

    func testCheckForUpdatesOpensTheSheet() {
        let store = AppStore()
        store.showSettings = true
        store.checkForUpdates()
        XCTAssertEqual(store.sheet, .softwareUpdate)
        XCTAssertFalse(store.showSettings)
    }

    // MARK: Localization

    func testStringsExistInEveryLanguage() {
        defer { L10n.setLanguage(.auto) }
        for language in AppLanguage.allCases where language != .auto {
            L10n.setLanguage(language)
            for key in ["check_for_updates", "software_update", "update_checking", "update_up_to_date", "update_available", "update_detail",
                        "install_and_relaunch", "update_downloading", "update_quit_to_install", "update_quit_detail", "quit_and_install",
                        "release_notes", "check_again", "update_unavailable_dev", "update_failed_title", "last_checked"] {
                XCTAssertNotEqual(L10n.t(key, "MISSING"), "MISSING", "\(language.rawValue) lacks \(key)")
            }
        }
        L10n.setLanguage(.zhHans)
        XCTAssertEqual(L10n.t("check_for_updates", "Check for Updates…"), "检查更新…")
    }

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [[String]] = []
        var calls: [[String]] { lock.lock(); defer { lock.unlock() }; return stored }
        func record(_ call: [String]) { lock.lock(); stored.append(call); lock.unlock() }
    }
}
