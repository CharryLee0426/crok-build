import XCTest

/// Photos and files in prompts (relay/DESIGN.md §5) in demo mode: the media bubbles of "Match the settings mockups"
/// (two mockups and a PDF, then a photo alone), the viewer, and attaching sample photos through the paperclip and
/// sending them. Screenshots as in `DemoTourUITests` (`TEST_RUNNER_CROK_SCREENSHOT_DIR`).
@MainActor
final class AttachmentsUITests: XCTestCase {
    private func launch(appearance: String) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-CrokDemo", "YES", "-CrokAppearance", appearance, "-crok.selectedComputer", "mbp", "-crok.sessionTheme", "none",
        ]
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

    /// Scrolls the transcript until `element` sits between the header and the composer.
    private func scrollIntoView(_ app: XCUIApplication, _ element: XCUIElement) {
        let window = app.windows.firstMatch.frame
        for _ in 0..<6 {
            let frame = element.frame
            if frame.minY > window.minY + 130, frame.maxY < window.maxY - 220 { break }
            if frame.midY < window.midY { app.swipeDown(velocity: .slow) } else { app.swipeUp(velocity: .slow) }
        }
    }

    /// Scrolls `element` into view and taps its middle.
    private func tapInView(_ app: XCUIApplication, _ element: XCUIElement) {
        scrollIntoView(app, element)
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    private func openMockups(_ app: XCUIApplication) {
        app.openSession("Match the settings mockups", in: "website")
        XCTAssertTrue(app.element("messageImage-settings-light.png").waitForExistence(timeout: 10))
    }

    func testMediaBubblesAndTheViewer() {
        for appearance in ["light", "dark"] {
            let app = launch(appearance: appearance)
            openMockups(app)
            XCTAssertTrue(app.element("messageImage-settings-dark.png").exists)
            XCTAssertTrue(app.element("messageFile-settings-spec.pdf").exists, "the PDF as a file row")
            XCTAssertTrue(app.element("messageImage-photo-20261026-184212.jpg").exists, "the photo sent alone")
            Thread.sleep(forTimeInterval: 0.6)
            snap("attachments-bubbles-\(appearance)")

            scrollIntoView(app, app.element("messageFile-settings-spec.pdf"))
            Thread.sleep(forTimeInterval: 0.6)
            snap("attachments-grid-\(appearance)")
            tapInView(app, app.element("messageImage-settings-light.png"))
            XCTAssertTrue(app.element("mediaViewer").waitForExistence(timeout: 5))
            let counter = app.element("mediaViewerCounter")
            XCTAssertTrue(counter.waitForExistence(timeout: 3))
            XCTAssertEqual(counter.label, "1 of 2")
            Thread.sleep(forTimeInterval: 0.6)
            snap("attachments-viewer-\(appearance)")
            app.swipeLeft()
            XCTAssertTrue(app.waitFor(3) { counter.label == "2 of 2" }, counter.label)
            XCTAssertTrue(app.element("mediaViewerShare").exists)
            XCTAssertTrue(app.element("mediaViewerSave").exists)
            app.element("mediaViewerClose").tap()
            XCTAssertTrue(app.waitFor(3) { !app.element("mediaViewer").exists }, "closed")

            // A photo alone opens on its own, without a counter; swiping down closes it.
            tapInView(app, app.element("messageImage-photo-20261026-184212.jpg"))
            XCTAssertTrue(app.element("mediaViewer").waitForExistence(timeout: 5))
            XCTAssertFalse(app.element("mediaViewerCounter").exists)
            app.element("mediaViewer").swipeDown(velocity: .fast)
            XCTAssertTrue(app.waitFor(4) { !app.element("mediaViewer").exists }, "swiped away")
            app.terminate()
        }
    }

    func testAttachingAndSendingPhotos() {
        for appearance in ["light", "dark"] {
            let app = launch(appearance: appearance)
            openMockups(app)
            let attach = app.element("attachButton")
            XCTAssertTrue(attach.waitForExistence(timeout: 5))
            attach.tap()
            XCTAssertTrue(app.element("attachPhotos").waitForExistence(timeout: 3))
            XCTAssertTrue(app.element("attachFiles").exists)
            Thread.sleep(forTimeInterval: 0.4)
            snap("attachments-menu-\(appearance)")
            app.element("attachSamples").tap()
            XCTAssertTrue(app.element("attachmentStrip").waitForExistence(timeout: 5))
            let send = app.element("sendButton")
            snap("attachments-strip-uploading-\(appearance)")
            XCTAssertTrue(app.waitFor(8) { !app.element("attachmentUploading").exists }, "uploads finish")
            XCTAssertTrue(send.isEnabled, "photos alone can be sent")
            let field = app.element("composerField")
            field.tap()
            field.typeText("Like these, but rounder")
            snap("attachments-strip-\(appearance)")
            send.tap()
            XCTAssertTrue(app.waitFor(3) { !app.element("attachmentStrip").exists }, "the strip is cleared")
            // The demo's own photo, then the two just sent (shown at once, then from the transcript).
            let photos = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'messageImage-photo-'"))
            XCTAssertTrue(app.waitFor(8) { photos.count >= 3 }, "the sent photos in a bubble")
            Thread.sleep(forTimeInterval: 2.5)
            snap("attachments-sent-\(appearance)")
            app.terminate()
        }
    }

    func testRemovingAnAttachment() {
        let app = launch(appearance: "light")
        openMockups(app)
        app.element("attachButton").tap()
        XCTAssertTrue(app.element("attachSamples").waitForExistence(timeout: 3))
        app.element("attachSamples").tap()
        let removes = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'removeAttachment-'"))
        XCTAssertTrue(app.waitFor(5) { removes.count == 2 })
        removes.element(boundBy: 0).tap()
        XCTAssertTrue(app.waitFor(3) { removes.count == 1 })
        removes.element(boundBy: 0).tap()
        XCTAssertTrue(app.waitFor(3) { !app.element("attachmentStrip").exists })
        XCTAssertFalse(app.element("sendButton").isEnabled, "nothing left to send")
    }

    /// Against a real relay (skipped unless `CROK_LIVE_ATTACHMENTS=1`; `-CrokServer` as in `LiveRelayUITests`): signs in
    /// (the user code goes to `$CROK_SCREENSHOT_DIR/live-user-code.txt` for a script to approve), opens "Look at this
    /// photo" on a fake computer of the same person, attaches two sample photos, sends them with text, and waits for
    /// the computer's item to show them and its reply.
    func testSendingPhotosThroughARealRelay() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["CROK_LIVE_ATTACHMENTS"] == "1", "set CROK_LIVE_ATTACHMENTS=1")
        continueAfterFailure = false
        let relay = environment["CROK_LIVE_RELAY_URL"].flatMap { $0.isEmpty ? nil : $0 } ?? "http://127.0.0.1:3210"
        let app = XCUIApplication()
        app.launchArguments = [
            "-CrokResetState", "YES", "-CrokAppearance", "light", "-CrokSampleAttachments", "YES", "-CrokNoBrowser", "YES",
            "-CrokServer", relay,
        ]
        app.launch()
        let continueButton = app.element("continueButton")
        XCTAssertTrue(continueButton.waitForExistence(timeout: 10))
        continueButton.tap()
        let code = app.element("userCode")
        XCTAssertTrue(code.waitForExistence(timeout: 15))
        let userCode = code.label.replacingOccurrences(of: " ", with: "")
        if let dir = environment["CROK_SCREENSHOT_DIR"] {
            try userCode.write(
                to: URL(fileURLWithPath: dir).appendingPathComponent("live-user-code.txt"), atomically: true, encoding: .utf8)
        }
        XCTAssertTrue(app.computerTitle.waitForExistence(timeout: 180), "approve \(userCode)")
        app.openSessionBySearch("Look at this photo")
        let attach = app.element("attachButton")
        XCTAssertTrue(attach.waitForExistence(timeout: 10))
        attach.tap()
        XCTAssertTrue(app.element("attachSamples").waitForExistence(timeout: 3))
        app.element("attachSamples").tap()
        XCTAssertTrue(app.element("attachmentStrip").waitForExistence(timeout: 5))
        XCTAssertTrue(app.waitFor(30) { !app.element("attachmentUploading").exists }, "uploaded to the relay")
        XCTAssertFalse(app.element("attachmentFailed").exists, "no upload failed")
        let field = app.element("composerField")
        field.tap()
        field.typeText("What is on these whiteboards?")
        snap("live-attachments-1-strip")
        app.element("sendButton").tap()
        let reply = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "Got 2 attachments")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 30), "the computer downloaded both")
        let images = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'messageImage-photo-'"))
        XCTAssertTrue(app.waitFor(10) { images.count >= 2 }, "the item shows both photos")
        Thread.sleep(forTimeInterval: 1.5)
        snap("live-attachments-2-sent")
        images.element(boundBy: 0).tap()
        XCTAssertTrue(app.element("mediaViewer").waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 2)
        snap("live-attachments-3-viewer")
    }
}
