import XCTest

/// Drives demo mode (`-CrokDemo YES`) through every main screen and saves a screenshot of each: as test attachments,
/// and as PNG files in `$CROK_SCREENSHOT_DIR` when set (pass `TEST_RUNNER_CROK_SCREENSHOT_DIR=…` to xcodebuild).
///
/// The demo has two computers: MacBook Pro (online; projects crok-build and website, one archived session) and Studio
/// (offline; tokenizer and xai-grok-pager). The Sessions tab shows one computer at a time (mobile/DESIGN.md).
final class DemoTourUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// `theme`: a session theme id, set through the arguments domain (it wins over what the app stores, so nil when
    /// the test picks one in the app).
    private func launch(_ extra: [String] = [], appearance: String = "light", theme: String? = "none") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments =
            ["-CrokDemo", "YES", "-CrokAppearance", appearance, "-crok.selectedComputer", "mbp"]
            + (theme.map { ["-crok.sessionTheme", $0] } ?? []) + extra
        app.launch()
        return app
    }

    private func snap(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["CROK_SCREENSHOT_DIR"], !dir.isEmpty {
            let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? shot.pngRepresentation.write(to: url)
        }
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.element(identifier)
    }

    /// The Profile tab: a tab bar on iPhone, the floating top bar on iPad (not an XCUI tab bar).
    private func openProfile(_ app: XCUIApplication) {
        let tabBar = app.tabBars.firstMatch
        if tabBar.exists {
            tabBar.buttons.element(boundBy: 1).tap()
        } else {
            app.buttons["Profile"].firstMatch.tap()
        }
        XCTAssertTrue(element(app, "accountHeader").waitForExistence(timeout: 5))
    }

    private func openSessions(_ app: XCUIApplication) {
        let tabBar = app.tabBars.firstMatch
        if tabBar.exists {
            tabBar.buttons.element(boundBy: 0).tap()
        } else {
            app.buttons["Sessions"].firstMatch.tap()
        }
    }

    /// The Sessions tab's root, settled: the computer in the title, its projects listed.
    private func waitForList(_ app: XCUIApplication, computer: String = "MacBook Pro") {
        XCTAssertTrue(app.computerTitle.waitForExistence(timeout: 10))
        XCTAssertTrue(app.waitFor(10) { app.computerTitle.label.hasPrefix(computer) }, app.computerTitle.label)
    }

    func testSignInScreens() {
        let app = launch(["-CrokDemoSignIn", "YES"])
        let continueButton = element(app, "continueButton")
        XCTAssertTrue(continueButton.waitForExistence(timeout: 10))
        snap("01-welcome")
        continueButton.tap()
        let code = element(app, "userCode")
        XCTAssertTrue(code.waitForExistence(timeout: 10))
        XCTAssertEqual(code.label, "B C D F - G H J K", "VoiceOver reads the code letter by letter")
        snap("02-waiting-for-approval")
        element(app, "cancelSignInButton").tap()
        XCTAssertTrue(continueButton.waitForExistence(timeout: 5))
    }

    func testSignInCompletesWhenApproved() {
        let app = launch(["-CrokDemoSignIn", "YES", "-CrokDemoApproveAfter", "1"])
        element(app, "continueButton").tap()
        XCTAssertTrue(element(app, "userCode").waitForExistence(timeout: 10))
        // Polling every 2 s picks up the approval and lands on the session list.
        XCTAssertTrue(element(app, "projectRow-crok-build").waitForExistence(timeout: 15))
    }

    func testMainScreens() {
        let app = launch()
        waitForList(app)
        XCTAssertTrue(element(app, "projectRow-crok-build").waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, "projectRow-website").exists)
        XCTAssertTrue(element(app, "archivedRow").exists, "MacBook Pro has an archived session")
        XCTAssertFalse(element(app, "projectRow-tokenizer").exists, "Studio's projects are on Studio's list")
        snap("03-sessions-light")

        // A project: its sessions as topics.
        app.openProject("crok-build")
        XCTAssertTrue(element(app, "sessionRow-Fix the flaky upload test").waitForExistence(timeout: 5))
        snap("04-project")

        // A running session: plan bar, transcript, Stop.
        app.tapSessionRow("Fix the flaky upload test")
        let stop = element(app, "stopButton")
        XCTAssertTrue(stop.waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, "planBar").exists)
        snap("05-session-running")

        element(app, "planBar").tap()
        XCTAssertTrue(app.staticTexts["Reproduce the flaky upload test"].waitForExistence(timeout: 5))
        snap("06-session-plan-expanded")
        element(app, "planBar").tap()
        XCTAssertTrue(app.staticTexts["Reproduce the flaky upload test"].waitForNonExistence(timeout: 5))

        // The failed prompt offers Retry / Delete.
        let failed = element(app, "failedPromptMenu")
        XCTAssertTrue(failed.waitForExistence(timeout: 5))

        // Stop ends the turn: the Stop button goes away.
        stop.tap()
        XCTAssertTrue(stop.waitForNonExistence(timeout: 5))

        // Send a prompt: clock → ✓ → ✓✓, with the reply streaming in.
        let field = element(app, "composerField")
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("Also run the download test")
        element(app, "sendButton").tap()
        XCTAssertTrue(app.staticTexts["Also run the download test"].waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "tick-sending").waitForExistence(timeout: 3) || element(app, "tick-delivered").exists)
        XCTAssertTrue(stop.waitForExistence(timeout: 5), "the turn runs: Stop is back")
        snap("07-session-streaming")
        let replyEnd = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Ran the test 50 times")).firstMatch
        XCTAssertTrue(replyEnd.waitForExistence(timeout: 20))
        XCTAssertTrue(stop.waitForNonExistence(timeout: 10))
        XCTAssertTrue(replyEnd.isHittable, "the finished reply is on screen, above the keyboard")
        snap("08-session-reply-done")

        // Session info, from the topic icon in the title bar: refreshed from the computer.
        element(app, "sessionInfoButton").tap()
        XCTAssertTrue(app.staticTexts["Session info"].waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "infoRefreshing").waitForNonExistence(timeout: 10))
        snap("09-session-info")
        app.swipeUp()
        snap("10-session-info-more")
        element(app, "infoDone").tap()

        // A session nobody runs on the online MacBook still takes prompts (a crok there opens it).
        app.goBack()
        app.tapSessionRow("Release notes for 1.5")
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertFalse(element(app, "offlineNotice").exists)
        let subtitle = element(app, "sessionSubtitle")
        XCTAssertTrue(subtitle.waitForExistence(timeout: 5))
        XCTAssertTrue(subtitle.label.contains("MacBook Pro"), "idle · MacBook Pro, not offline: \(subtitle.label)")
        snap("11-session-not-running")
        app.goBack()
        app.goBack()

        // Studio, picked from the title's menu: offline, so its sessions are read-only.
        app.computerTitle.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Studio")).firstMatch.waitForExistence(timeout: 5))
        snap("11d-computer-switcher")
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Studio")).firstMatch.tap()
        XCTAssertTrue(element(app, "projectRow-tokenizer").waitForExistence(timeout: 5))
        XCTAssertFalse(element(app, "projectRow-crok-build").exists)
        snap("11e-sessions-studio")
        app.openProject("tokenizer")
        app.tapSessionRow("Benchmark the tokenizer")
        XCTAssertTrue(element(app, "offlineNotice").waitForExistence(timeout: 5))
        XCTAssertFalse(field.exists)
        snap("11a-session-offline")
        app.goBack()
        app.goBack()

        // Profile: the account, its computers (Studio selected), Devices, Link a computer.
        openProfile(app)
        XCTAssertTrue(element(app, "computerRow-Studio").isSelected)
        snap("12-profile")
        let macBook = element(app, "computerRow-MacBook Pro")
        macBook.tap()
        XCTAssertTrue(app.waitFor(5) { macBook.isSelected })
        app.swipeUp()
        XCTAssertTrue(element(app, "githubRow").exists)
        XCTAssertTrue(element(app, "xRow").exists)
        snap("12a-profile-more")
        app.swipeDown()
        element(app, "devicesRow").tap()
        XCTAssertTrue(app.staticTexts["MacBook Pro"].waitForExistence(timeout: 5))
        snap("13-devices")
        element(app, "deviceRow-MacBook Pro").tap()
        XCTAssertTrue(element(app, "signOutDevice").waitForExistence(timeout: 5))
        snap("14-device-detail")
        app.buttons["Done"].firstMatch.tap()
        app.goBack()

        element(app, "linkComputerRow").tap()
        let codeField = element(app, "manualCodeField")
        XCTAssertTrue(codeField.waitForExistence(timeout: 5))
        snap("15-link-computer")
        codeField.tap()
        codeField.typeText("bcdfghjk")
        element(app, "manualCodeContinue").tap()
        let approve = element(app, "approveButton")
        XCTAssertTrue(approve.waitForExistence(timeout: 5))
        snap("16-link-review")
        approve.tap()
        XCTAssertTrue(element(app, "linkResult").waitForExistence(timeout: 5))
        snap("17-link-done")
    }

    /// Holding the tabs (Telegram's tab bar menus): Sessions → Mark All as Read; Profile → the computers.
    func testTabBarMenus() throws {
        let app = launch()
        waitForList(app)
        let crokBuild = element(app, "projectRow-crok-build")
        XCTAssertTrue(crokBuild.waitForExistence(timeout: 10))
        XCTAssertTrue(crokBuild.label.contains("unread"), crokBuild.label)
        let tabBar = app.tabBars.firstMatch
        guard tabBar.exists else { throw XCTSkip("no tab bar (iPad)") }

        tabBar.buttons.element(boundBy: 0).press(forDuration: 1.2)
        let markAll = app.buttons["Mark All as Read"].firstMatch
        XCTAssertTrue(markAll.waitForExistence(timeout: 5))
        snap("34-tab-mark-all-read")
        markAll.tap()
        XCTAssertTrue(app.waitFor(5) { !crokBuild.label.contains("unread") }, crokBuild.label)

        tabBar.buttons.element(boundBy: 1).press(forDuration: 1.2)
        let studio = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Studio")).firstMatch
        XCTAssertTrue(studio.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Link a computer"].firstMatch.exists)
        snap("35-tab-computer-switcher")
        studio.tap()
        XCTAssertTrue(element(app, "projectRow-tokenizer").waitForExistence(timeout: 5))
        XCTAssertTrue(app.computerTitle.label.hasPrefix("Studio"))
    }

    func testDarkScreens() {
        let app = launch(appearance: "dark")
        waitForList(app)
        XCTAssertTrue(element(app, "projectRow-crok-build").waitForExistence(timeout: 10))
        snap("03b-sessions-dark")
        app.openProject("crok-build")
        snap("04b-project-dark")
        app.tapSessionRow("Fix the flaky upload test")
        XCTAssertTrue(element(app, "stopButton").waitForExistence(timeout: 10))
        snap("05b-session-running-dark")
        element(app, "sessionInfoButton").tap()
        XCTAssertTrue(element(app, "infoRefreshing").waitForNonExistence(timeout: 10))
        snap("09b-session-info-dark")
        element(app, "infoDone").tap()
        app.goBack()
        app.goBack()
        openProfile(app)
        snap("12b-profile-dark")
    }

    /// Profile › Appearance: the session themes in light and dark, and a session on one.
    func testSessionThemes() {
        let app = launch(theme: nil)
        waitForList(app)
        openProfile(app)
        element(app, "appearanceRow").tap()
        XCTAssertTrue(element(app, "themePreview").waitForExistence(timeout: 5))
        let selectedName = element(app, "selectedThemeName")
        let none = element(app, "themeCard-none")
        if !none.isHittable { app.swipeRight() }
        none.tap()
        XCTAssertTrue(app.waitFor(5) { selectedName.label == "No Theme" })
        snap("36-appearance-no-theme")
        element(app, "themeCard-classic").tap()
        XCTAssertTrue(app.waitFor(5) { selectedName.label == "Classic" })
        snap("37-appearance-classic")
        let tulip = element(app, "themeCard-tulip")
        if !tulip.isHittable { element(app, "themeCard-classic").swipeLeft() }
        tulip.tap()
        XCTAssertTrue(app.waitFor(5) { selectedName.label == "Tulip" })
        snap("38-appearance-tulip")
        app.terminate()

        for (theme, appearance) in [("classic", "light"), ("snowman", "dark"), ("christmas", "light"), ("game", "dark")] {
            let themed = launch(appearance: appearance, theme: theme)
            waitForList(themed)
            themed.openSession("Fix the flaky upload test", in: "crok-build")
            XCTAssertTrue(element(themed, "stopButton").waitForExistence(timeout: 10))
            // The doodles fade in once drawn.
            Thread.sleep(forTimeInterval: 1.5)
            snap("39-session-\(theme)-\(appearance)")
            if appearance == "dark" {
                themed.goBack()
                themed.goBack()
                openProfile(themed)
                element(themed, "appearanceRow").tap()
                XCTAssertTrue(element(themed, "themePreview").waitForExistence(timeout: 5))
                Thread.sleep(forTimeInterval: 1)
                snap("40-appearance-\(theme)-dark")
            }
            themed.terminate()
        }
    }

    /// German has the longest strings and Chinese the densest: check nothing is cut off.
    func testLocalizedScreens() {
        for (language, locale) in [("de", "de_DE"), ("zh-Hans", "zh_CN")] {
            let app = launch(["-AppleLanguages", "(\(language))", "-AppleLocale", locale])
            waitForList(app)
            XCTAssertTrue(element(app, "projectRow-crok-build").waitForExistence(timeout: 10))
            snap("18-\(language)-sessions")
            app.openProject("crok-build")
            app.tapSessionRow("Fix the flaky upload test")
            XCTAssertTrue(element(app, "stopButton").waitForExistence(timeout: 10))
            snap("19-\(language)-session")
            element(app, "sessionInfoButton").tap()
            XCTAssertTrue(element(app, "infoDone").waitForExistence(timeout: 5))
            snap("20-\(language)-info")
            element(app, "infoDone").tap()
            app.goBack()
            app.goBack()
            openProfile(app)
            snap("21-\(language)-profile")
            element(app, "appearanceRow").tap()
            XCTAssertTrue(element(app, "themePreview").waitForExistence(timeout: 5))
            snap("21a-\(language)-appearance")
            app.terminate()
        }
    }

    func testSignInScreensInJapanese() {
        let app = launch(["-CrokDemoSignIn", "YES", "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"])
        let continueButton = element(app, "continueButton")
        XCTAssertTrue(continueButton.waitForExistence(timeout: 10))
        snap("22-ja-welcome")
        continueButton.tap()
        XCTAssertTrue(element(app, "userCode").waitForExistence(timeout: 10))
        snap("23-ja-waiting")
    }

    /// Projects as groups: moving one, Edit mode, every session of a project on its screen, and sessions only on a
    /// computer's disk (loading from an online computer; an offline one's notice).
    func testProjectsAndListedSessions() {
        let app = launch()
        waitForList(app)
        let crokBuild = element(app, "projectRow-crok-build")
        let website = element(app, "projectRow-website")
        XCTAssertTrue(crokBuild.waitForExistence(timeout: 10))
        XCTAssertTrue(website.exists)
        XCTAssertGreaterThan(website.frame.minY, crokBuild.frame.minY)

        // A project's menu: Move Up puts "website" above "crok-build".
        website.press(forDuration: 1.2)
        let moveUp = app.buttons["Move Up"].firstMatch
        XCTAssertTrue(moveUp.waitForExistence(timeout: 5))
        snap("03e-project-menu")
        moveUp.tap()
        XCTAssertTrue(app.waitFor(5) { website.frame.minY < crokBuild.frame.minY }, "website moved above crok-build")

        // Edit: move handles, and Read All / Sort by Recent Activity in place of the tab bar.
        element(app, "editButton").tap()
        XCTAssertTrue(element(app, "readAllButton").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "sortProjectsButton").exists)
        snap("03f-edit-mode")
        element(app, "sortProjectsButton").tap()
        XCTAssertTrue(app.waitFor(5) { crokBuild.frame.minY < website.frame.minY }, "back to most recent first")
        element(app, "reorderDone").tap()
        XCTAssertTrue(element(app, "readAllButton").waitForNonExistence(timeout: 5))

        // Every session of a project on its screen, none hidden behind "Show more".
        app.openProject("crok-build")
        let i18n = element(app, "sessionRow-Translate the settings pane")
        if !i18n.waitForExistence(timeout: 3) { app.swipeUp() }
        XCTAssertTrue(i18n.waitForExistence(timeout: 5))
        app.goBack()

        // A session only on the online MacBook's disk: loading, then its history.
        app.openSession("Fix the pricing page layout", in: "website")
        XCTAssertTrue(element(app, "historyLoading").waitForExistence(timeout: 5))
        snap("11b-session-loading-from-computer")
        let history = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "CSS grid")).firstMatch
        XCTAssertTrue(history.waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, "composerField").exists, "not running anywhere, but the MacBook can open it")
        XCTAssertFalse(element(app, "offlineNotice").exists)
        app.goBack()
        app.goBack()

        // One on Studio, which is offline.
        app.openSession("Port the lexer to Rust", in: "tokenizer", on: "Studio")
        XCTAssertTrue(element(app, "historyOffline").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "offlineNotice").exists)
        snap("11c-session-computer-offline")
    }

    /// A session waiting on a permission request: the card above the composer, answered from the phone.
    func testPermissionRequest() {
        let app = launch()
        waitForList(app)
        app.openSession("Bump the relay's dependencies", in: "crok-build")
        let card = element(app, "permissionCard")
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "permissionDetail").exists)
        XCTAssertTrue(element(app, "permissionOption-reject-once").exists)
        XCTAssertTrue(element(app, "composerField").exists, "a prompt can still be queued")
        snap("05c-session-permission")

        element(app, "permissionOption-allow-once").tap()
        XCTAssertTrue(card.waitForNonExistence(timeout: 5), "the computer took the answer")
        let reply = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "no code changes")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 10), "the turn went on")
        snap("05d-session-permission-answered")
    }

    /// New sessions (relay/DESIGN.md §5 "New sessions"): a project's compose button, the list's project picker, the
    /// new-session screen turning into the session, and `/new <prompt>` inside a session.
    func testNewSessions() {
        let app = launch()
        waitForList(app)
        app.openProject("crok-build")
        let compose = element(app, "newSessionInProject")
        XCTAssertTrue(compose.waitForExistence(timeout: 5))
        XCTAssertTrue(compose.isEnabled)
        compose.tap()
        XCTAssertTrue(element(app, "newSessionPlaceholder").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "newSessionSubtitle").label.contains("MacBook Pro"))
        snap("24-new-session")

        let field = element(app, "composerField")
        field.tap()
        field.typeText("Add a health check endpoint")
        element(app, "sendButton").tap()
        XCTAssertTrue(app.staticTexts["Add a health check endpoint"].waitForExistence(timeout: 5))
        // The screen became the session: its subtitle and the info button.
        XCTAssertTrue(element(app, "sessionInfoButton").waitForExistence(timeout: 5))
        snap("25-new-session-started")
        XCTAssertTrue(element(app, "stopButton").waitForExistence(timeout: 10), "a crok there opened it and runs the prompt")
        let reply = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Ran the test 50 times")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 20))
        snap("25b-new-session-reply")
        app.goBack()
        XCTAssertTrue(element(app, "sessionRow-Add a health check endpoint").waitForExistence(timeout: 5), "listed in its project")
        app.goBack()

        // The list's compose button asks for one of this computer's projects first.
        element(app, "composeButton").tap()
        let website = element(app, "newSessionProject-website")
        XCTAssertTrue(website.waitForExistence(timeout: 5))
        XCTAssertFalse(element(app, "newSessionProject-tokenizer").exists, "only the selected computer's projects")
        snap("26-new-session-picker")
        website.tap()
        XCTAssertTrue(element(app, "newSessionPlaceholder").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "newSessionSubtitle").label.contains("website"))
        app.goBack()

        // `/new <prompt>` in a session starts one in its project at once.
        app.openSession("Relay: device sign-in", in: "crok-build")
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("/new Write the relay README")
        element(app, "sendButton").tap()
        XCTAssertTrue(app.staticTexts["Write the relay README"].waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "stopButton").waitForExistence(timeout: 10))
        snap("27-new-session-from-command")
        app.goBack()
        app.goBack()
        app.goBack()

        // No new sessions on an offline computer.
        app.openProject("tokenizer", on: "Studio")
        XCTAssertFalse(element(app, "newSessionInProject").isEnabled, "Studio is offline")
    }

    /// The composer's commands (relay/DESIGN.md §5 "Commands in the composer"): the Menu button and command list, `/`
    /// filtering, bot cards for `/model` and `/think` with inline keyboards, arguments, and a session command sent as
    /// a prompt.
    func testComposerCommands() {
        let app = launch()
        waitForList(app)
        app.openSession("Relay: device sign-in", in: "crok-build")
        let field = element(app, "composerField")
        XCTAssertTrue(field.waitForExistence(timeout: 5))

        element(app, "menuButton").tap()
        XCTAssertTrue(element(app, "commandList").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "commandRow-new").exists)
        XCTAssertTrue(element(app, "commandRow-think").exists)
        XCTAssertFalse(element(app, "commandRow-stop").exists, "only while a turn runs")
        XCTAssertTrue(element(app, "commandRow-compact").exists, "the session's own commands follow")
        snap("28-command-menu")

        // /model fills the field; sending it without a name answers with the card.
        element(app, "commandRow-model").tap()
        XCTAssertTrue(element(app, "commandList").waitForNonExistence(timeout: 5))
        element(app, "sendButton").tap()
        XCTAssertTrue(element(app, "botCard").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "botChoice-grok-4").waitForExistence(timeout: 5))
        snap("29-model-card")
        element(app, "botChoice-grok-4").tap()
        let done = element(app, "botCardDone")
        XCTAssertTrue(done.waitForExistence(timeout: 10))
        XCTAssertTrue(done.label.contains("Grok 4"), done.label)
        XCTAssertFalse(element(app, "botChoice-grok-4").exists, "the keyboard folded away")
        snap("30-model-card-done")

        // Typing / opens the list and filters it.
        field.tap()
        field.typeText("/th")
        XCTAssertTrue(element(app, "commandRow-think").waitForExistence(timeout: 5))
        XCTAssertFalse(element(app, "commandRow-model").exists)
        snap("31-command-filter")
        field.typeText("ink")
        element(app, "sendButton").tap()
        let low = element(app, "botChoice-low")
        XCTAssertTrue(low.waitForExistence(timeout: 5), "Grok 4's thinking levels")
        snap("32-think-card")
        low.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Low ✓")).firstMatch.waitForExistence(timeout: 10))

        // With an argument it applies at once.
        field.tap()
        field.typeText("/model claude")
        element(app, "sendButton").tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Claude Sonnet 4.5 ✓")).firstMatch.waitForExistence(timeout: 10))

        // A session command goes to the computer as a prompt.
        element(app, "menuButton").tap()
        XCTAssertTrue(element(app, "commandRow-compact").waitForExistence(timeout: 5))
        element(app, "commandRow-compact").tap()
        XCTAssertTrue(app.staticTexts["/compact"].waitForExistence(timeout: 5))
        snap("33-session-command-sent")
    }

    // MARK: Model and thinking level

    /// A thinking menu's item (the menu shows above everything else).
    private func menuItem(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", name, "\(name),")).firstMatch
    }

    /// The model and thinking level (mobile/DESIGN.md "Model and thinking level"): a new session started on a model
    /// picked in Choose a Model (by search) and a level from the thinking menu; then, in a session, both changed from
    /// the pills and from Session info.
    func testModelAndThinkingLevel() {
        let app = launch()
        waitForList(app)
        app.openProject("crok-build")
        element(app, "newSessionInProject").tap()
        XCTAssertTrue(element(app, "newSessionPlaceholder").waitForExistence(timeout: 5))
        let modelPill = element(app, "modelPill")
        let thinkingPill = element(app, "thinkingPill")
        XCTAssertTrue(modelPill.waitForExistence(timeout: 5))
        XCTAssertEqual(modelPill.pillValue, "Default")
        XCTAssertFalse(thinkingPill.exists, "Default hides the thinking pill")
        snap("41-new-session-pills")

        // Choose a Model: Default first, then the computer's models by provider; search narrows them.
        modelPill.tap()
        XCTAssertTrue(element(app, "modelRow-default").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "modelRow-grok-code-fast-1").exists)
        snap("42-choose-model-new-session")
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("gpt")
        let gpt = element(app, "modelRow-openrouter/openai/gpt-5")
        XCTAssertTrue(gpt.waitForExistence(timeout: 5))
        XCTAssertFalse(element(app, "modelRow-grok-code-fast-1").exists, "only the matches")
        XCTAssertFalse(element(app, "modelRow-default").exists)
        snap("43-choose-model-search")
        search.typeText("zzz")
        XCTAssertTrue(element(app, "modelNoResults").waitForExistence(timeout: 5))
        search.typeText(XCUIKeyboardKey.delete.rawValue + XCUIKeyboardKey.delete.rawValue + XCUIKeyboardKey.delete.rawValue)
        XCTAssertTrue(gpt.waitForExistence(timeout: 5))
        gpt.tap()
        XCTAssertTrue(app.waitFor(5) { modelPill.pillValue == "OpenAI: GPT-5" }, modelPill.pillValue)

        // GPT-5 has thinking levels: the pill shows, Default until one is picked.
        XCTAssertTrue(thinkingPill.waitForExistence(timeout: 5))
        XCTAssertEqual(thinkingPill.pillValue, "Default")
        thinkingPill.tap()
        let high = menuItem(app, "High")
        XCTAssertTrue(high.waitForExistence(timeout: 5))
        XCTAssertTrue(menuItem(app, "Minimal").exists)
        snap("44-thinking-menu-new-session")
        high.tap()
        XCTAssertTrue(app.waitFor(5) { thinkingPill.pillValue == "High" }, thinkingPill.pillValue)
        snap("45-new-session-picked")

        let field = element(app, "composerField")
        field.tap()
        field.typeText("Add a health check endpoint")
        element(app, "sendButton").tap()
        XCTAssertTrue(element(app, "sessionInfoButton").waitForExistence(timeout: 5), "the screen became the session")
        // Once a crok there opened it, its pills say what it runs.
        XCTAssertTrue(app.waitFor(10) { modelPill.exists && modelPill.pillValue == "OpenAI: GPT-5" }, modelPill.pillValue)
        XCTAssertEqual(thinkingPill.pillValue, "High")
        app.goBack()
        app.goBack()

        // An open session: the pills change it on the computer.
        app.openSession("Relay: device sign-in", in: "crok-build")
        XCTAssertTrue(app.waitFor(5) { modelPill.exists && modelPill.pillValue == "Grok Code Fast 1" }, modelPill.pillValue)
        XCTAssertEqual(thinkingPill.pillValue, "High")
        snap("46-session-pills")
        modelPill.tap()
        let current = element(app, "modelRow-grok-code-fast-1")
        XCTAssertTrue(current.waitForExistence(timeout: 5))
        XCTAssertTrue(current.isSelected, "the current model is checked")
        XCTAssertFalse(element(app, "modelRow-default").exists, "Default only for a new session")
        snap("47-choose-model-session")
        app.swipeUp()
        snap("47b-choose-model-session-large")
        search.tap()
        search.typeText("sonnet")
        let sonnet = element(app, "modelRow-claude-sonnet-4-5")
        XCTAssertTrue(sonnet.waitForExistence(timeout: 5))
        sonnet.tap()
        // On its way (a spinner, "Sending"), then applied.
        XCTAssertTrue(app.waitFor(5) { modelPill.pillValue.hasPrefix("Claude Sonnet 4.5") }, modelPill.pillValue)
        snap("48-session-model-changing")
        XCTAssertTrue(app.waitFor(10) { modelPill.pillValue == "Claude Sonnet 4.5" }, modelPill.pillValue)
        thinkingPill.tap()
        let max = menuItem(app, "Max")
        XCTAssertTrue(max.waitForExistence(timeout: 5))
        snap("49-thinking-menu-session")
        max.tap()
        XCTAssertTrue(app.waitFor(10) { thinkingPill.pillValue == "Max" }, thinkingPill.pillValue)
        XCTAssertTrue(app.waitFor(10) { modelPill.isHittable }, "nothing left on its way")

        // Session info: the same choices, from its Model and Thinking level rows.
        element(app, "sessionInfoButton").tap()
        let infoModel = element(app, "infoModelRow")
        XCTAssertTrue(infoModel.waitForExistence(timeout: 5))
        XCTAssertTrue(infoModel.label.contains("Claude Sonnet 4.5"), infoModel.label)
        snap("50-info-model-rows")
        infoModel.tap()
        let grok4 = element(app, "modelRow-grok-4")
        XCTAssertTrue(grok4.waitForExistence(timeout: 5))
        grok4.tap()
        XCTAssertTrue(app.waitFor(10) { infoModel.label.contains("Grok 4") && !infoModel.label.contains("Fast") }, infoModel.label)
        let infoThinking = element(app, "infoThinkingRow")
        XCTAssertTrue(app.waitFor(10) { infoThinking.exists && infoThinking.isEnabled })
        infoThinking.tap()
        let low = menuItem(app, "Low")
        XCTAssertTrue(low.waitForExistence(timeout: 5))
        low.tap()
        XCTAssertTrue(app.waitFor(10) { infoThinking.label.contains("Low") }, infoThinking.label)
        snap("51-info-changed")
        element(app, "infoDone").tap()
        XCTAssertTrue(app.waitFor(5) { modelPill.pillValue == "Grok 4" && thinkingPill.pillValue == "Low" })
    }

    /// The status words of the tool calls on screen ("running", "done", "failed", "stopped").
    private func toolStates(_ app: XCUIApplication) -> [String] {
        app.descendants(matching: .any).matching(identifier: "toolCard").allElementsBoundByIndex.map {
            $0.value as? String ?? ""
        }
    }

    /// Reasoning and tool calls by their status only (mobile/DESIGN.md "Thinking and tool calls"), in light and dark and
    /// on a wallpaper: done, failed, running and stopped tool calls; "Thinking…" while a turn reasons, then "Thought".
    func testThinkingAndToolRows() {
        for (appearance, theme) in [("light", "none"), ("dark", "none"), ("light", "tulip"), ("dark", "game")] {
            let suffix = "\(theme)-\(appearance)"
            let app = launch(appearance: appearance, theme: theme)
            waitForList(app)
            // Running: a tool call in progress, done and failed ones above it.
            app.openSession("Fix the flaky upload test", in: "crok-build")
            let tool = element(app, "toolCard")
            XCTAssertTrue(tool.waitForExistence(timeout: 10))
            let deadline = Date().addingTimeInterval(5)
            while !toolStates(app).contains("running"), Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
            XCTAssertTrue(toolStates(app).contains("running"), "\(toolStates(app))")
            Thread.sleep(forTimeInterval: 1)
            snap("60-tools-running-\(suffix)")
            app.swipeDown()
            Thread.sleep(forTimeInterval: 0.6)
            let shown = toolStates(app)
            XCTAssertTrue(shown.contains("done"), "\(shown)")
            snap("61-tools-done-failed-\(suffix)")
            app.goBack()
            app.goBack()

            // A turn reasoning from the phone: "Thinking…", then "Thought" once the tool call follows.
            app.openSession("Relay: device sign-in", in: "crok-build")
            let field = element(app, "composerField")
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            field.tap()
            field.typeText("Check the expiry")
            element(app, "sendButton").tap()
            let thinking = element(app, "thoughtRowActive")
            XCTAssertTrue(thinking.waitForExistence(timeout: 10), "Thinking… while the turn reasons")
            Thread.sleep(forTimeInterval: 0.4)
            snap("62-thinking-\(suffix)")
            XCTAssertTrue(element(app, "thoughtRow").waitForExistence(timeout: 10), "then Thought")
            XCTAssertFalse(thinking.exists)
            snap("63-thought-\(suffix)")
            app.terminate()
        }
    }

    /// The pills in dark mode, with a session theme, on an older crok (dimmed), and a refused change.
    func testModelPillsLook() {
        for (appearance, theme) in [("dark", "none"), ("light", "tulip"), ("dark", "game")] {
            let app = launch(appearance: appearance, theme: theme)
            waitForList(app)
            app.openSession("Relay: device sign-in", in: "crok-build")
            let modelPill = element(app, "modelPill")
            XCTAssertTrue(app.waitFor(5) { modelPill.exists && modelPill.pillValue == "Grok Code Fast 1" })
            Thread.sleep(forTimeInterval: 1.5)
            snap("52-session-pills-\(theme)-\(appearance)")
            // The row sits above the field, left-aligned with the Menu pill. (Not checked against the transcript: under
            // XCUITest's polling a short transcript sometimes lands below the composer, with or without the pills.)
            XCTAssertLessThan(modelPill.frame.maxY, element(app, "composerField").frame.minY)
            XCTAssertLessThan(abs(modelPill.frame.minX - element(app, "menuButton").frame.minX), 1, "aligned with the Menu pill")
            if theme == "none" {
                element(app, "thinkingPill").tap()
                XCTAssertTrue(menuItem(app, "Medium").waitForExistence(timeout: 5))
                snap("53-thinking-menu-dark")
                menuItem(app, "Medium").tap()
                modelPill.tap()
                XCTAssertTrue(element(app, "modelRow-grok-code-fast-1").waitForExistence(timeout: 5))
                snap("54-choose-model-dark")
                element(app, "modelPickerCancel").tap()
            }
            app.goBack()
            element(app, "newSessionInProject").tap()
            XCTAssertTrue(element(app, "newSessionPlaceholder").waitForExistence(timeout: 5))
            XCTAssertTrue(element(app, "modelPill").waitForExistence(timeout: 5))
            Thread.sleep(forTimeInterval: 1)
            snap("55-new-session-pills-\(theme)-\(appearance)")
            app.terminate()
        }

        // A long model name: truncated in the middle, the thinking pill still whole and on screen.
        let long = launch()
        waitForList(long)
        long.openSession("Relay: device sign-in", in: "crok-build")
        let longPill = element(long, "modelPill")
        XCTAssertTrue(longPill.waitForExistence(timeout: 5))
        longPill.tap()
        let search = long.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("nemotron")
        let nemotron = element(long, "modelRow-openrouter/nvidia/llama-3.3-nemotron-super-49b-v1.5")
        XCTAssertTrue(nemotron.waitForExistence(timeout: 5))
        nemotron.tap()
        XCTAssertTrue(long.waitFor(10) { longPill.pillValue.hasPrefix("NVIDIA") && !longPill.pillValue.hasSuffix("Sending") })
        let longThinking = element(long, "thinkingPill")
        XCTAssertTrue(longThinking.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 1)
        snap("59-long-model-name")
        XCTAssertLessThan(longPill.frame.maxX, longThinking.frame.minX)
        XCTAssertLessThanOrEqual(longThinking.frame.maxX, long.windows.firstMatch.frame.maxX - 8)
        XCTAssertGreaterThan(longThinking.frame.width, 60, "the thinking pill keeps its label")
        long.terminate()

        // Studio online with an older crok: the session's model, dimmed; a tap says why.
        let older = launch(["-CrokDemoStudioOnline", "YES"])
        waitForList(older)
        older.openSession("Benchmark the tokenizer", in: "tokenizer", on: "Studio")
        let dimmed = element(older, "modelPill")
        XCTAssertTrue(dimmed.waitForExistence(timeout: 5))
        XCTAssertFalse(element(older, "thinkingPill").exists)
        snap("56-session-pills-older-crok")
        dimmed.tap()
        XCTAssertTrue(older.alerts.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(older.alerts.firstMatch.label.contains("doesn't offer model choices"), older.alerts.firstMatch.label)
        snap("57-older-crok-alert")
        older.alerts.firstMatch.buttons.firstMatch.tap()
        older.terminate()

        // The computer refuses: the pill goes back and an alert says why.
        // Quoted: launch argument values are read as property-list strings.
        let refusing = launch(["-CrokDemoConfigFails", "\"Your plan does not include this model.\""])
        waitForList(refusing)
        refusing.openSession("Relay: device sign-in", in: "crok-build")
        let pill = element(refusing, "modelPill")
        XCTAssertTrue(pill.waitForExistence(timeout: 5))
        pill.tap()
        let grok4 = element(refusing, "modelRow-grok-4")
        XCTAssertTrue(grok4.waitForExistence(timeout: 5))
        grok4.tap()
        let alert = refusing.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 10))
        XCTAssertTrue(alert.label.contains("Couldn't change the model"), alert.label)
        snap("58-model-change-refused")
        alert.buttons.firstMatch.tap()
        XCTAssertEqual(pill.pillValue, "Grok Code Fast 1", "back to the old value")
    }

    func testCommandsDark() {
        let app = launch(appearance: "dark")
        waitForList(app)
        app.openSession("Relay: device sign-in", in: "crok-build")
        XCTAssertTrue(element(app, "composerField").waitForExistence(timeout: 5))
        element(app, "menuButton").tap()
        XCTAssertTrue(element(app, "commandList").waitForExistence(timeout: 5))
        snap("28b-command-menu-dark")
        element(app, "commandRow-model").tap()
        element(app, "sendButton").tap()
        XCTAssertTrue(element(app, "botChoice-grok-4").waitForExistence(timeout: 5))
        snap("29b-model-card-dark")
        app.goBack()
        element(app, "newSessionInProject").tap()
        XCTAssertTrue(element(app, "newSessionPlaceholder").waitForExistence(timeout: 5))
        snap("24b-new-session-dark")
    }

    func testArchivedAndSearch() {
        let app = launch()
        waitForList(app)
        let archived = element(app, "archivedRow")
        XCTAssertTrue(archived.waitForExistence(timeout: 10))
        archived.tap()
        XCTAssertTrue(element(app, "sessionRow-Try a different diff renderer").waitForExistence(timeout: 5))
        snap("03g-archived")
        app.goBack()

        let search = app.searchFields.firstMatch
        if !search.exists { app.swipeDown() }
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("release")
        // Results are sessions of the selected computer, across its projects.
        XCTAssertTrue(element(app, "sessionRow-Release notes for 1.5").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "sessionRow-Tidy the release script").exists)
        XCTAssertFalse(element(app, "projectRow-crok-build").exists)
        XCTAssertFalse(element(app, "sessionRow-Fix the flaky upload test").exists)
        snap("03h-search")
    }
}

private extension XCUIElement {
    /// A pill's current choice (its accessibility value).
    var pillValue: String { (value as? String) ?? "" }
}
