import AppKit
import SwiftUI
import XCTest
@testable import GrokDesktop

/// Transcript images: what the reducer keeps of each, the full-size store, and the viewer's gallery.
@MainActor
final class ImageViewingTests: XCTestCase {
    private var directory: URL!
    private var savedStoreDirectory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("crok-image-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        savedStoreDirectory = ImageStore.directory
        ImageStore.directory = directory.appendingPathComponent("images", isDirectory: true)
    }

    override func tearDownWithError() throws {
        ImageStore.directory = savedStoreDirectory
        try? FileManager.default.removeItem(at: directory)
    }

    private func imageBlock(_ data: Data, uri: String? = nil) -> [String: Any] {
        var block: [String: Any] = ["type": "image", "data": data.base64EncodedString(), "mimeType": "image/png"]
        if let uri { block["uri"] = uri }
        return block
    }

    private func eventually(timeout: TimeInterval = 3, _ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(predicate())
    }

    // MARK: Reducer

    func testPromptImagesKeepTheWholeImageInTheStore() async throws {
        let png = SidePanelAndAttachmentTests.png(width: 900, height: 600)
        var messages: [Message] = []
        TranscriptReducer.apply(["sessionUpdate": "user_message_chunk", "content": imageBlock(png, uri: "file:///tmp/shots/window.png")], to: &messages)
        let image = try XCTUnwrap(messages.first?.attachments?.first)
        XCTAssertEqual(image.name, "window.png")
        XCTAssertEqual(image.path, "/tmp/shots/window.png")
        XCTAssertEqual(image.mimeType, "image/png")
        XCTAssertEqual(image.pixelSize, CGSize(width: 900, height: 600))
        XCTAssertNotNil(image.thumbnail)
        XCTAssertLessThan(image.thumbnail?.count ?? .max, png.count, "the row keeps only a small preview")
        let blob = try XCTUnwrap(image.blob)
        XCTAssertTrue(blob.hasSuffix(".png"))
        try await eventually { FileManager.default.fileExists(atPath: ImageStore.url(blob).path) }
        XCTAssertEqual(try Data(contentsOf: ImageStore.url(blob)), png)
        XCTAssertEqual(image.fullImageURL, ImageStore.url(blob), "the uri's file does not exist, so the stored copy is read")
    }

    func testToolImagesBecomeAttachmentsInsteadOfPlaceholderText() {
        let png = SidePanelAndAttachmentTests.png(width: 64, height: 32)
        var messages: [Message] = []
        TranscriptReducer.apply(["sessionUpdate": "tool_call", "toolCallId": "read", "title": "Read `shot.png`", "status": "in_progress"], to: &messages)
        TranscriptReducer.apply(["sessionUpdate": "tool_call_update", "toolCallId": "read", "status": "completed",
                                 "content": [["type": "content", "content": ["type": "text", "text": "Read image file"]],
                                             ["type": "content", "content": imageBlock(png, uri: "file:///tmp/shot.png")]]], to: &messages)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].detail, "Read image file", "no \"[Image]\" placeholder")
        XCTAssertEqual(messages[0].attachments?.map(\.kind), [.image])
        XCTAssertEqual(messages[0].attachments?.first?.origin, .tool)
        XCTAssertEqual(messages[0].attachments?.first?.name, "shot.png")

        // PDF pages: several unnamed images, numbered.
        TranscriptReducer.apply(["sessionUpdate": "tool_call", "toolCallId": "pdf", "title": "Read `a.pdf`", "status": "completed",
                                 "content": [["type": "content", "content": imageBlock(png)], ["type": "content", "content": imageBlock(png)]]], to: &messages)
        XCTAssertEqual(messages[1].attachments?.map(\.name), ["Image 1", "Image 2"])
        XCTAssertEqual(messages[1].detail, "")
    }

    func testRepeatedToolUpdatesKeepTheImagesShown() {
        let png = SidePanelAndAttachmentTests.png(width: 40, height: 40)
        let update: [String: Any] = ["sessionUpdate": "tool_call_update", "toolCallId": "shot", "status": "completed",
                                     "content": [["type": "content", "content": imageBlock(png)]]]
        var messages: [Message] = []
        TranscriptReducer.apply(["sessionUpdate": "tool_call", "toolCallId": "shot", "title": "Screenshot", "status": "in_progress"], to: &messages)
        TranscriptReducer.apply(update, to: &messages)
        let first = messages[0].attachments?.map(\.id)
        TranscriptReducer.apply(update, to: &messages)
        XCTAssertEqual(messages[0].attachments?.map(\.id), first, "the same image again is not a new attachment")
        TranscriptReducer.apply(["sessionUpdate": "tool_call_update", "toolCallId": "shot", "status": "completed"], to: &messages)
        XCTAssertEqual(messages[0].attachments?.count, 1, "an update without content keeps the images")

        let other = SidePanelAndAttachmentTests.png(width: 50, height: 20)
        TranscriptReducer.apply(["sessionUpdate": "tool_call_update", "toolCallId": "shot", "content": [["type": "content", "content": imageBlock(other)]]], to: &messages)
        XCTAssertNotEqual(messages[0].attachments?.map(\.id), first)
        XCTAssertEqual(messages[0].attachments?.first?.pixelSize, CGSize(width: 50, height: 20))
    }

    func testGeneratedImagesAreReadFromTheSavedFile() throws {
        let file = directory.appendingPathComponent("7.png")
        try SidePanelAndAttachmentTests.png(width: 300, height: 200).write(to: file)
        var messages: [Message] = []
        TranscriptReducer.apply(["sessionUpdate": "tool_call", "toolCallId": "gen", "title": "Generate image", "status": "in_progress"], to: &messages)
        TranscriptReducer.apply(["sessionUpdate": "tool_call_update", "toolCallId": "gen", "status": "completed",
                                 "content": [["type": "content", "content": ["type": "text", "text": "Image generated and saved to \(file.path)."]]],
                                 "rawOutput": ["type": "ImageGen", "path": file.path, "filename": "7.png", "session_folder": "images"]], to: &messages)
        let image = try XCTUnwrap(messages[0].attachments?.first)
        XCTAssertEqual(image.origin, .generated)
        XCTAssertEqual(image.path, file.path)
        XCTAssertEqual(image.pixelSize, CGSize(width: 300, height: 200))
        XCTAssertNotNil(image.thumbnail)
        XCTAssertEqual(image.fullImageURL, file)
        XCTAssertEqual(image.revealablePath, file.path)

        // Other tools' raw output is not an image.
        TranscriptReducer.apply(["sessionUpdate": "tool_call", "toolCallId": "bash", "title": "Run", "status": "completed",
                                 "rawOutput": ["type": "Bash", "path": file.path]], to: &messages)
        XCTAssertNil(messages[1].attachments)
    }

    func testReplyImagesAttachToTheReply() {
        let png = SidePanelAndAttachmentTests.png(width: 20, height: 20)
        var messages: [Message] = []
        TranscriptReducer.apply(["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "Here it is:"]], to: &messages)
        TranscriptReducer.apply(["sessionUpdate": "agent_message_chunk", "content": imageBlock(png)], to: &messages)
        TranscriptReducer.apply(["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": " done."]], to: &messages)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].text, "Here it is: done.")
        XCTAssertEqual(messages[0].attachments?.first?.origin, .reply)
    }

    func testReplayWithStoredImagesDiffersFromOneWithout() {
        let a = Message(kind: .user, text: "", attachments: [MessageAttachment(kind: .image, name: "Image", blob: "a.png")])
        let b = Message(kind: .user, text: "", attachments: [MessageAttachment(kind: .image, name: "Image", blob: "b.png")])
        XCTAssertTrue(TranscriptReducer.sameContent([a], [a]))
        XCTAssertFalse(TranscriptReducer.sameContent([a], [b]))
    }

    func testAttachmentsSavedByEarlierVersionsStillDecode() throws {
        let id = UUID()
        let old = #"{"id":"\#(id.uuidString)","kind":"image","name":"Image","thumbnail":"AQI="}"#
        let attachment = try JSONDecoder().decode(MessageAttachment.self, from: Data(old.utf8))
        XCTAssertEqual(attachment.id, id)
        XCTAssertEqual(attachment.thumbnail, Data([1, 2]))
        XCTAssertNil(attachment.blob)
        XCTAssertNil(attachment.origin)
        XCTAssertNil(attachment.fullImageURL)

        let new = MessageAttachment(kind: .image, name: "x.png", blob: "abc.png", mimeType: "image/png", pixelWidth: 4, pixelHeight: 3, origin: .generated)
        XCTAssertEqual(try JSONDecoder().decode(MessageAttachment.self, from: JSONEncoder().encode(new)), new)
    }

    // MARK: Store

    func testStoreNamesImagesByContentAndSweepsUnreferencedOnes() async throws {
        let one = SidePanelAndAttachmentTests.png(width: 10, height: 10)
        let two = SidePanelAndAttachmentTests.png(width: 11, height: 10)
        let a = ImageStore.store(one, mimeType: "image/png")
        XCTAssertEqual(ImageStore.store(one, mimeType: "image/png"), a)
        XCTAssertEqual(ImageStore.blobName(one, mimeType: "image/jpeg").split(separator: ".").last, "jpeg")
        let b = ImageStore.store(two, mimeType: "image/png")
        XCTAssertNotEqual(a, b)
        try await eventually { FileManager.default.fileExists(atPath: ImageStore.url(a).path) && FileManager.default.fileExists(atPath: ImageStore.url(b).path) }

        let conversation = Conversation(projectID: UUID(), messages: [Message(kind: .user, text: "", attachments: [MessageAttachment(kind: .image, name: "Image", blob: a)])])
        XCTAssertEqual(ImageStore.referenced(by: [conversation]), [a])
        // Within the grace period nothing goes; well after it, only the unreferenced image does.
        ImageStore.sweep(keeping: [a])
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(FileManager.default.fileExists(atPath: ImageStore.url(b).path))
        ImageStore.sweep(keeping: [a], now: Date().addingTimeInterval(ImageStore.sweepGrace * 2))
        try await eventually { !FileManager.default.fileExists(atPath: ImageStore.url(b).path) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: ImageStore.url(a).path))
    }

    func testSentAttachmentsKeepTheirBytes() {
        let png = SidePanelAndAttachmentTests.png(width: 30, height: 20)
        var attachment = PromptAttachment(kind: .image, name: "Pasted.png", url: nil)
        attachment.imageData = png
        attachment.mimeType = "image/png"
        let sent = attachment.messageAttachment
        XCTAssertEqual(sent.blob, ImageStore.blobName(png, mimeType: "image/png"))
        XCTAssertEqual(sent.pixelSize, CGSize(width: 30, height: 20))
    }

    func testDataURLsDecode() throws {
        let png = SidePanelAndAttachmentTests.png(width: 8, height: 8)
        let url = try XCTUnwrap(URL(string: "data:image/png;base64," + png.base64EncodedString()))
        XCTAssertEqual(MarkdownImageCache.decodeDataURL(url), png)
        XCTAssertNil(MarkdownImageCache.decodeDataURL(URL(string: "data:text/plain;base64,aGk=")!))
        XCTAssertNil(MarkdownImageCache.decodeDataURL(URL(string: "https://example.com/a.png")!))
    }

    // MARK: Viewer

    func testGalleryListsEveryImageInTranscriptOrder() {
        let sent = MessageAttachment(kind: .image, name: "sent.png")
        let file = MessageAttachment(kind: .file, name: "notes.md", path: "/tmp/notes.md")
        let read = MessageAttachment(kind: .image, name: "read.png", origin: .tool)
        let generated = MessageAttachment(kind: .image, name: "1.jpg", origin: .generated)
        let messages = [
            Message(kind: .user, text: "Look", attachments: [sent, file]),
            Message(kind: .tool, text: "Read", toolID: "r", attachments: [read]),
            Message(kind: .assistant, text: "Here"),
            Message(kind: .tool, text: "Generate", toolID: "g", attachments: [generated]),
        ]
        XCTAssertEqual(ImageGallery.items(in: messages).map(\.name), ["sent.png", "read.png", "1.jpg"])

        let store = AppStore(stateFile: directory.appendingPathComponent("state.json"), binaryPath: "/usr/bin/false")
        let project = Project(path: directory.path)
        let task = Conversation(projectID: project.id, messages: messages)
        store.state.projects = [project]; store.state.conversations = [task]; store.state.selectedConversationID = task.id
        store.openImage(read)
        XCTAssertEqual(store.imageViewer?.index, 1)
        XCTAssertEqual(store.imageViewer?.items.count, 3)
        store.openImage(MessageAttachment(kind: .image, name: "elsewhere.png"))
        XCTAssertEqual(store.imageViewer?.items.map(\.name), ["elsewhere.png"], "an image outside the transcript opens alone")
        store.openImage(url: URL(string: "data:image/png;base64,AAAA")!)
        XCTAssertEqual(store.imageViewer?.current?.name, "Image")
        store.closeImageViewer()
        XCTAssertNil(store.imageViewer)
    }

    func testViewerStepsWithinTheGalleryAndResetsZoom() {
        var request = ImageViewerRequest(items: (1...3).map { ImageViewerItem(name: "\($0)", url: nil) }, index: 0)
        XCTAssertFalse(request.canGoBack)
        request.step(-1)
        XCTAssertEqual(request.index, 0)
        request.setZoom(3); request.offset = CGSize(width: 40, height: 10)
        request.step(1)
        XCTAssertEqual(request.index, 1)
        XCTAssertEqual(request.zoom, 1)
        XCTAssertEqual(request.offset, .zero)
        request.step(5)
        XCTAssertEqual(request.index, 2)
        XCTAssertFalse(request.canGoForward)
        request.setZoom(100)
        XCTAssertEqual(request.zoom, ImageViewerRequest.zoomRange.upperBound)
        request.setZoom(0.1)
        XCTAssertEqual(request.zoom, 1)
    }

    func testImageLayoutFitsWithinItsBox() {
        let wide = MessageAttachment(kind: .image, name: "w", pixelWidth: 2000, pixelHeight: 500)
        let fitted = TranscriptImageLayout.fitted(wide, in: CGSize(width: 360, height: 180))
        XCTAssertEqual(fitted, CGSize(width: 360, height: 90))
        let small = MessageAttachment(kind: .image, name: "s", pixelWidth: 240, pixelHeight: 160)
        XCTAssertEqual(TranscriptImageLayout.fitted(small, in: CGSize(width: 360, height: 180)), CGSize(width: 160, height: 107),
                       "a small image is not blown up past its Retina size (with a floor)")
        XCTAssertEqual(TranscriptImageLayout.tile(wide, height: 100).width, 220, "tiles clamp extreme aspect ratios")
    }

    // MARK: Image links

    func testImageFilePathsAreFoundInCodeSpansAndProse() {
        XCTAssertEqual(ImageFileLink.url(forPath: "/tmp/qr/auth.png"), URL(fileURLWithPath: "/tmp/qr/auth.png"))
        XCTAssertEqual(ImageFileLink.url(forPath: " ~/Desktop/Screenshot 2026-10-13 at 9.17.00 AM.PNG "),
                       URL(fileURLWithPath: NSHomeDirectory() + "/Desktop/Screenshot 2026-10-13 at 9.17.00 AM.PNG"))
        XCTAssertEqual(ImageFileLink.url(forPath: "file:///tmp/shot.jpeg"), URL(fileURLWithPath: "/tmp/shot.jpeg"))
        for other in ["/tmp/notes.md", "src/shot.png", "./shot.png", "shot.png", "/tmp/qr", "https://example.com/a.png", "cp /tmp/a.png /tmp/b"] {
            XCTAssertNil(ImageFileLink.url(forPath: other), other)
        }

        func found(_ text: String) -> [String] { ImageFileLink.paths(in: text).map { (text as NSString).substring(with: $0.range) } }
        XCTAssertEqual(found("QR code: /tmp/qr/auth.png"), ["/tmp/qr/auth.png"])
        XCTAssertEqual(found("Saved to /tmp/shots/home.png. Then (see ~/Pictures/b.webp), and /x/c.JPG!"),
                       ["/tmp/shots/home.png", "~/Pictures/b.webp", "/x/c.JPG"])
        XCTAssertEqual(found("二维码：/tmp/qr/auth.png。"), ["/tmp/qr/auth.png"])
        XCTAssertEqual(found("a/b.png, ./c.png, /tmp/a.png.bak, /tmp/a.pngx, //example.com/d.png, file:///tmp/e.png, /tmp/notes.md"), [])
    }

    func testRepliesLinkImageFilePaths() {
        let markdown = """
        QR code: `/tmp/qr/auth.png`

        Saved to /tmp/shots/home.png. The code is in `src/main.rs`, notes are in `/tmp/notes.md`, and [the logo](~/logo.jpg).
        """
        let text = MarkdownAttributedRenderer.reply(.response, dark: false).render(MarkdownParser.parse(markdown))
        let string = text.string as NSString
        func link(_ fragment: String) -> URL? { text.attribute(.link, at: string.range(of: fragment).location, effectiveRange: nil) as? URL }
        XCTAssertEqual(link("/tmp/qr/auth.png"), URL(fileURLWithPath: "/tmp/qr/auth.png"))
        XCTAssertEqual(link("/tmp/shots/home.png"), URL(fileURLWithPath: "/tmp/shots/home.png"))
        XCTAssertNil(text.attribute(.link, at: NSMaxRange(string.range(of: "home.png.")) - 1, effectiveRange: nil), "the full stop is not part of the path")
        XCTAssertNil(link("src/main.rs"))
        XCTAssertNil(link("/tmp/notes.md"))
        XCTAssertEqual(link("the logo"), URL(fileURLWithPath: NSHomeDirectory() + "/logo.jpg"))
    }

    func testThePointerOnAnImageLinkFindsItsFile() throws {
        let box = TranscriptTextBox(style: .reply(.response), maxHeight: .infinity, width: 600)
        box.update(text: "QR code: `/tmp/qr/auth.png`\n\nTell me when you've authorized.")
        box.setFrameSize(NSSize(width: 600, height: box.height(forWidth: 600)))
        let textView = try XCTUnwrap(box.textView as? MarkdownSourceTextView)
        XCTAssertTrue(textView.previewsImageLinks)
        let layoutManager = try XCTUnwrap(textView.layoutManager), container = try XCTUnwrap(textView.textContainer)
        func center(_ fragment: String) -> NSPoint {
            let glyphs = layoutManager.glyphRange(forCharacterRange: (textView.string as NSString).range(of: fragment), actualCharacterRange: nil)
            let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
            return NSPoint(x: rect.midX + textView.textContainerOrigin.x, y: rect.midY + textView.textContainerOrigin.y)
        }
        let hit = try XCTUnwrap(textView.imageLink(at: center("auth.png")))
        XCTAssertEqual(hit.url, URL(fileURLWithPath: "/tmp/qr/auth.png"))
        XCTAssertTrue(hit.rect.contains(center("/tmp/qr")), "the popover points at the whole path")
        XCTAssertNil(textView.imageLink(at: center("QR code")))
        XCTAssertNil(textView.imageLink(at: center("authorized")))
        XCTAssertNil(textView.imageLink(at: NSPoint(x: center("auth.png").x + 300, y: center("auth.png").y)), "past the end of the line")

        let output = TranscriptTextBox(style: .monospaced, maxHeight: 260, width: 600)
        output.update(text: "/tmp/qr/auth.png")
        XCTAssertEqual((output.textView as? MarkdownSourceTextView)?.previewsImageLinks, false, "only Markdown has links")
    }

    func testAClickOnAnImageLinkOpensTheFile() throws {
        let file = directory.appendingPathComponent("auth.png")
        try SidePanelAndAttachmentTests.png(width: 64, height: 64).write(to: file)
        var opened: [URL] = []
        let open = ImageFileLink.open
        ImageFileLink.open = { opened.append($0) }
        defer { ImageFileLink.open = open }
        let box = TranscriptTextBox(style: .reply(.response), maxHeight: .infinity, width: 600)
        box.update(text: "QR code: `\(file.path)`")
        let textView = try XCTUnwrap(box.textView)
        let storage = try XCTUnwrap(textView.textStorage)
        let index = (storage.string as NSString).range(of: "auth.png").location
        textView.clicked(onLink: try XCTUnwrap(storage.attribute(.link, at: index, effectiveRange: nil)), at: index)
        XCTAssertEqual(opened, [file])
    }

    func testLinkPreviewReadsTheFileAsItIsNow() throws {
        let file = directory.appendingPathComponent("auth.png")
        try SidePanelAndAttachmentTests.png(width: 256, height: 256).write(to: file)
        let code = try XCTUnwrap(ImageLinkPreview.read(file, maxPixels: ImageLinkPreview.maxPixels))
        XCTAssertEqual(code.pixelSize, CGSize(width: 256, height: 256))
        XCTAssertEqual(ImageLinkPreview.displaySize(for: code.pixelSize), CGSize(width: 240, height: 240), "a QR code shows large enough to scan")
        // A new sign-in writes its code to the same path; the preview shows the new one.
        try SidePanelAndAttachmentTests.png(width: 300, height: 300).write(to: file)
        XCTAssertEqual(ImageLinkPreview.read(file, maxPixels: ImageLinkPreview.maxPixels)?.pixelSize, CGSize(width: 300, height: 300))

        let screen = directory.appendingPathComponent("screen.png")
        try SidePanelAndAttachmentTests.png(width: 2400, height: 1200).write(to: screen)
        let large = try XCTUnwrap(ImageLinkPreview.read(screen, maxPixels: 640))
        XCTAssertEqual(large.pixelSize, CGSize(width: 2400, height: 1200), "the caption gives the file's own size")
        XCTAssertEqual(large.image.size, NSSize(width: 640, height: 320), "only as many pixels as the popover needs are read")
        XCTAssertEqual(ImageLinkPreview.displaySize(for: large.pixelSize), CGSize(width: 280, height: 140))
        XCTAssertEqual(ImageLinkPreview.displaySize(for: CGSize(width: 48, height: 48)), CGSize(width: 48, height: 48), "a small image is not blown up")

        XCTAssertNil(ImageLinkPreview.read(directory.appendingPathComponent("gone.png"), maxPixels: 640))
        let notImage = directory.appendingPathComponent("notes.png")
        try Data("not an image".utf8).write(to: notImage)
        XCTAssertNil(ImageLinkPreview.read(notImage, maxPixels: 640))
    }
}

/// PNGs of transcript images and the viewer, written when CROK_DESKTOP_SNAPSHOT_DIR is set.
@MainActor
final class ImageViewingSnapshotTests: XCTestCase {
    private var output: URL!
    private var directory: URL!
    private var savedStoreDirectory: URL!

    override func setUpWithError() throws {
        guard let path = ProcessInfo.processInfo.environment["CROK_DESKTOP_SNAPSHOT_DIR"] else { throw XCTSkip("Set CROK_DESKTOP_SNAPSHOT_DIR to render snapshots") }
        output = URL(fileURLWithPath: path)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("crok-image-snapshots-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        savedStoreDirectory = ImageStore.directory
        ImageStore.directory = directory.appendingPathComponent("images", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let savedStoreDirectory { ImageStore.directory = savedStoreDirectory }
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    /// A photo-like image: a sky gradient over hills, so scaling and cropping are easy to judge.
    static func scene(width: Int, height: Int, hue: CGFloat = 0.58) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let sky = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: [
            NSColor(hue: hue, saturation: 0.55, brightness: 0.95, alpha: 1).cgColor,
            NSColor(hue: hue + 0.08, saturation: 0.35, brightness: 1, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(sky, start: CGPoint(x: 0, y: height), end: .zero, options: [])
        for (index, level) in [0.42, 0.3, 0.18].enumerated() {
            context.setFillColor(NSColor(hue: 0.3 + CGFloat(index) * 0.03, saturation: 0.45, brightness: 0.45 + CGFloat(index) * 0.12, alpha: 1).cgColor)
            context.beginPath()
            context.move(to: .zero)
            for x in stride(from: 0, through: width, by: 8) {
                let y = CGFloat(height) * level + sin(CGFloat(x) / CGFloat(width) * .pi * CGFloat(2 + index)) * CGFloat(height) * 0.06
                context.addLine(to: CGPoint(x: CGFloat(x), y: y))
            }
            context.addLine(to: CGPoint(x: width, y: 0))
            context.closePath(); context.fillPath()
        }
        context.setFillColor(NSColor(calibratedRed: 1, green: 0.93, blue: 0.7, alpha: 1).cgColor)
        context.fillEllipse(in: CGRect(x: width * 7 / 10, y: height * 6 / 10, width: height / 7, height: height / 7))
        return PromptAttachmentsModel.encode(context.makeImage()!, as: .png)!
    }

    private func image(_ name: String, width: Int, height: Int, hue: CGFloat = 0.58, origin: MessageAttachment.Origin? = .tool) throws -> MessageAttachment {
        let data = Self.scene(width: width, height: height, hue: hue)
        let file = directory.appendingPathComponent(name)
        try data.write(to: file)
        var attachment = try XCTUnwrap(MessageAttachment.image(data: data, mimeType: "image/png", name: name, path: file.path, origin: origin))
        attachment.blob = nil
        return attachment
    }

    func testTranscriptImages() throws {
        let messages = [
            Message(kind: .user, text: "Why does the header overlap the sidebar here?", attachments: [try image("overlap.png", width: 1440, height: 900, origin: nil)]),
            Message(kind: .tool, text: "Read `docs/screenshot.png`", toolID: "read", status: "completed", detail: "Read image file [image/png]",
                    attachments: [try image("screenshot.png", width: 1600, height: 1000)]),
            Message(kind: .tool, text: "Read `design.pdf`", toolID: "pdf", status: "completed",
                    attachments: try (1...9).map { try image("page-\($0).png", width: 850, height: 1100, hue: 0.05 * CGFloat($0)) }),
            Message(kind: .tool, text: "Generate image", toolID: "gen", status: "completed", detail: "Image generated and saved to images/1.png.",
                    attachments: [try image("1.png", width: 1024, height: 1024, hue: 0.8, origin: .generated)]),
            Message(kind: .assistant, text: "The header's leading inset ignores the sidebar width; the generated mock shows the fix."),
        ]
        for (name, appearance) in [("transcript-images-light", NSAppearance.Name.aqua), ("transcript-images-dark", .darkAqua)] {
            let view = VStack(alignment: .leading, spacing: 23) { ForEach(messages) { MessageView(message: $0) } }
                .padding(36).frame(width: 800, alignment: .topLeading)
            try SnapshotRenderer.write(view, size: CGSize(width: 800, height: 1320), appearance: appearance,
                                       to: output.appendingPathComponent(name + ".png"))
        }
    }

    func testViewerOverlay() throws {
        let items = try [
            image("overlap.png", width: 1440, height: 900, origin: nil),
            image("screenshot.png", width: 1600, height: 1000),
            image("1.png", width: 1024, height: 1024, hue: 0.8, origin: .generated),
            image("page-1.png", width: 850, height: 1100, hue: 0.05),
        ].map(ImageViewerItem.init)
        for (name, index, zoom) in [("image-viewer", 1, CGFloat(1)), ("image-viewer-zoomed", 2, 2.5)] {
            var request = ImageViewerRequest(items: items, index: index)
            request.zoom = zoom
            let view = ImageViewerOverlay(request: .constant(request), onClose: {})
            // The real viewer draws over the window; a plain canvas stands in for it here.
            let backdrop = ZStack { Theme.canvas; ImageViewingSnapshotTests.fakeWindow; view }
            try SnapshotRenderer.write(backdrop, size: CGSize(width: 1200, height: 800), appearance: .darkAqua,
                                       to: output.appendingPathComponent(name + ".png"))
        }
    }

    private static var fakeWindow: some View {
        HStack(spacing: 0) {
            Theme.sidebar.frame(width: 260)
            VStack(alignment: .leading, spacing: 18) {
                ForEach(0..<8, id: \.self) { _ in RoundedRectangle(cornerRadius: 6).fill(Theme.muted.opacity(0.25)).frame(height: 14) }
            }.padding(40)
        }
    }
}
