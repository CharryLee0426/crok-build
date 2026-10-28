import ImageIO
import UIKit
import UniformTypeIdentifiers
import XCTest

@testable import Crok

/// Photos and files in prompts (relay/DESIGN.md §2 "Photos and files", §5 "Photos and files in prompts").
final class AttachmentsTests: XCTestCase {
    // MARK: Relay data

    func testTranscriptItemsAndPromptsCarryTheirAttachments() throws {
        let json = """
            {"events": [{"_id": "e1", "seq": 3, "key": "k", "kind": "user", "text": "", "origin": "remote", "at": 5,
              "attachments": [
                {"storageId": "kg1", "thumbId": "kg2", "name": "photo.jpg", "mimeType": "image/jpeg", "size": 1200,
                 "kind": "image", "width": 2048, "height": 1536, "url": "https://x.convex.cloud/api/storage/a",
                 "thumbUrl": "https://x.convex.cloud/api/storage/b"},
                {"name": "notes.md", "mimeType": "text/markdown", "size": 12, "kind": "file", "url": null, "thumbUrl": null},
                {"storageId": "kg3", "name": "x.bin", "kind": "video", "size": "big"}
              ]}], "more": false}
            """
        let chunk = try JSONDecoder().decode(TranscriptChunk.self, from: Data(json.utf8))
        let attachments = try XCTUnwrap(chunk.events.first?.attachments)
        XCTAssertEqual(attachments.count, 3)
        XCTAssertEqual(attachments[0].kind, .image)
        XCTAssertEqual(attachments[0].width, 2048)
        XCTAssertEqual(attachments[0].thumbUrl, "https://x.convex.cloud/api/storage/b")
        XCTAssertNil(attachments[1].storageId, "a file only on the computer")
        XCTAssertNil(attachments[1].url)
        XCTAssertEqual(attachments[2].kind, .file, "an unknown kind is a file")
        XCTAssertEqual(attachments[2].size, 0, "a bad field does not lose the item")

        let older = """
            {"events": [{"_id": "e1", "seq": 1, "key": "k", "kind": "user", "text": "hi", "at": 5}], "more": false}
            """
        XCTAssertNil(try JSONDecoder().decode(TranscriptChunk.self, from: Data(older.utf8)).events[0].attachments)

        let prompts = """
            [{"_id": "c1", "type": "prompt", "clientId": "x", "text": "", "status": "pending", "error": null,
              "fromLabel": "Web", "fromDeviceId": null, "mine": true, "createdAt": 1, "updatedAt": 2,
              "attachments": [{"storageId": "kg9", "name": "spec.pdf", "mimeType": "application/pdf", "size": 9,
                               "kind": "file", "url": "https://x/9", "thumbUrl": null}]}]
            """
        let commands = try JSONDecoder().decode([PromptCommand].self, from: Data(prompts.utf8))
        XCTAssertEqual(commands[0].attachments?.first?.name, "spec.pdf")
    }

    func testUploadsGoAsTheRelayTakesThem() {
        let full = AttachmentInput(storageId: "kg1", thumbId: "kg2", name: "a.jpg", width: 2048, height: 1536)
        XCTAssertEqual(
            full.json,
            .object([
                "storageId": .string("kg1"), "thumbId": .string("kg2"), "name": .string("a.jpg"), "width": .number(2048),
                "height": .number(1536),
            ]))
        XCTAssertEqual(
            AttachmentInput(storageId: "kg3", name: "spec.pdf").json,
            .object(["storageId": .string("kg3"), "name": .string("spec.pdf")]), "optional fields are left out")
    }

    func testNamesAndDetails() {
        let date = Date(timeIntervalSince1970: 1_793_102_400)  // 2026-10-27 12:00:00 UTC
        let utc = TimeZone(identifier: "UTC")!
        XCTAssertEqual(AttachmentText.photoName(at: date, timeZone: utc), "photo-20261027-120000.jpg")
        XCTAssertEqual(AttachmentText.photoName(at: date, index: 2, timeZone: utc), "photo-20261027-120000-2.jpg")
        XCTAssertEqual(AttachmentText.renamed("IMG_0001.HEIC", ext: "jpg"), "IMG_0001.jpg")
        XCTAssertEqual(AttachmentText.renamed("scan", ext: "png"), "scan.png")
        let size = ByteCountFormatter.string(fromByteCount: 1_200_000, countStyle: .file)
        XCTAssertEqual(AttachmentText.detail(name: "report.pdf", size: 1_200_000), "\(size) · PDF")
        XCTAssertEqual(AttachmentText.detail(name: "Makefile", size: 1_200_000), size)
        XCTAssertEqual(AttachmentText.mimeType(forName: "report.pdf"), "application/pdf")
        XCTAssertEqual(AttachmentText.mimeType(forName: "blob.zzzunknown"), "application/octet-stream")
    }

    // MARK: Preparing images

    private func encode(_ image: CGImage, _ type: UTType, properties: [CFString: Any] = [:]) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func picture(width: Int, height: Int, opaque: Bool) -> CGImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = opaque
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        }.cgImage!
    }

    private func properties(_ data: Data) -> [CFString: Any] {
        let source = CGImageSourceCreateWithData(data as CFData, nil)!
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
    }

    func testABigPNGWithTransparencyStaysPNGAtMost2048Pixels() throws {
        let data = encode(picture(width: 3000, height: 1000, opaque: false), .png)
        let prepared = try ImagePreparer.prepare(data, name: "diagram.png")
        XCTAssertEqual(prepared.mimeType, "image/png")
        XCTAssertEqual(prepared.name, "diagram.png")
        XCTAssertEqual(prepared.width, 2048)
        XCTAssertEqual(prepared.height, 683)
        let thumbnail = try XCTUnwrap(prepared.thumbnail)
        let thumb = properties(thumbnail)
        XCTAssertEqual((thumb[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue, 480)
        XCTAssertEqual(CGImageSourceGetType(CGImageSourceCreateWithData(thumbnail as CFData, nil)!) as String?, UTType.jpeg.identifier)
    }

    func testAPhotoIsTurnedUprightAndLosesItsLocation() throws {
        // Stored landscape with orientation 6 (rotate 90° clockwise to show), with GPS.
        let gps: [CFString: Any] = [kCGImagePropertyGPSLatitude: 37.33, kCGImagePropertyGPSLongitude: 122.03]
        let data = encode(
            picture(width: 4000, height: 3000, opaque: true), .jpeg,
            properties: [kCGImagePropertyOrientation: 6, kCGImagePropertyGPSDictionary: gps])
        XCTAssertNotNil(properties(data)[kCGImagePropertyGPSDictionary], "the source has a location")
        let prepared = try ImagePreparer.prepare(data, name: "photo-1.jpg")
        XCTAssertEqual(prepared.mimeType, "image/jpeg")
        XCTAssertEqual(prepared.width, 1536, "upright: portrait")
        XCTAssertEqual(prepared.height, 2048)
        let out = properties(prepared.data)
        XCTAssertNil(out[kCGImagePropertyGPSDictionary], "no location")
        XCTAssertEqual((out[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1, 1, "no orientation left to apply")
    }

    func testOtherFormatsBecomeJPEGAndSmallOnesAreNotScaledUp() throws {
        let image = picture(width: 800, height: 600, opaque: true)
        let tiff = encode(image, .tiff)
        let prepared = try ImagePreparer.prepare(tiff, name: "scan.tiff")
        XCTAssertEqual(prepared.mimeType, "image/jpeg")
        XCTAssertEqual(prepared.name, "scan.jpg")
        XCTAssertEqual(prepared.width, 800)
        XCTAssertEqual(prepared.height, 600)
        if CGImageDestinationCreateWithData(NSMutableData(), UTType.heic.identifier as CFString, 1, nil) != nil {
            let heic = try ImagePreparer.prepare(encode(image, .heic), name: "IMG_0001.HEIC")
            XCTAssertEqual(heic.mimeType, "image/jpeg")
            XCTAssertEqual(heic.name, "IMG_0001.jpg")
        }
    }

    func testAGIFGoesAsItIs() throws {
        let gif = encode(picture(width: 64, height: 32, opaque: true), .gif)
        let prepared = try ImagePreparer.prepare(gif, name: "dance.gif")
        XCTAssertEqual(prepared.data, gif)
        XCTAssertEqual(prepared.mimeType, "image/gif")
        XCTAssertEqual(prepared.width, 64)
        XCTAssertNotNil(prepared.thumbnail)
    }

    func testUnreadableBytesAreRefused() {
        XCTAssertThrowsError(try ImagePreparer.prepare(Data("not an image".utf8), name: "x.jpg"))
        XCTAssertFalse(ImagePreparer.isImage(Data("%PDF-1.4".utf8)))
    }

    // MARK: Layout

    func testOneImageFitsAndSeveralMakeAGrid() {
        XCTAssertEqual(MediaLayout.singleSize(width: 1200, height: 900), CGSize(width: 260, height: 195))
        XCTAssertEqual(MediaLayout.singleSize(width: 600, height: 1300), CGSize(width: 148, height: 320))
        XCTAssertEqual(MediaLayout.singleSize(width: 100, height: 4000), CGSize(width: 140, height: 320), "never too thin")
        XCTAssertEqual(MediaLayout.singleSize(width: nil, height: nil), CGSize(width: 220, height: 220))
        let three = MediaLayout.grid(count: 3)
        XCTAssertEqual(three.map(\.frame), [
            CGRect(x: 0, y: 0, width: 129, height: 129), CGRect(x: 131, y: 0, width: 129, height: 129),
            CGRect(x: 0, y: 131, width: 260, height: 129),
        ])
        XCTAssertEqual(MediaLayout.grid(count: 4).last?.frame, CGRect(x: 131, y: 131, width: 129, height: 129))
        XCTAssertEqual(MediaLayout.gridHeight(count: 2), 129)
        XCTAssertTrue(MediaLayout.grid(count: 1).isEmpty)
    }

    // MARK: Transcript

    func testBubblesShowWhatIsThereAndSayWhatIsNot() {
        let photo = Attachment(
            storageId: "kg1", thumbId: "kg2", name: "a.jpg", mimeType: "image/jpeg", size: 9, kind: .image,
            url: "https://x/1", thumbUrl: "https://x/2")
        let gone = Attachment(storageId: "kg3", name: "b.jpg", mimeType: "image/jpeg", size: 9, kind: .image, url: nil)
        let local = Attachment(storageId: nil, name: "notes.md", mimeType: "text/markdown", size: 9, kind: .file)
        let event = TranscriptEvent(
            id: "e1", seq: 1, key: "k", kind: .user, text: "", origin: "remote", commandId: "c1",
            attachments: [photo, gone, local], at: 1)
        let items = TranscriptBuilder.build(events: [event], commands: [], local: [], hasOlder: false)
        guard case .user(let message) = items.last?.kind else { return XCTFail("a user bubble") }
        XCTAssertEqual(message.attachments.map(\.name), ["a.jpg", "b.jpg", "notes.md"])
        XCTAssertTrue(message.attachments[0].showsAsImage)
        XCTAssertEqual(message.attachments[0].thumbURL?.absoluteString, "https://x/2")
        XCTAssertFalse(message.attachments[1].showsAsImage, "gone from the relay: a dimmed row")
        XCTAssertFalse(message.attachments[1].isOnComputerOnly)
        XCTAssertTrue(message.attachments[2].isOnComputerOnly)
        XCTAssertNotEqual(message.attachments[0].id, MessageAttachment(photo, index: 1).id, "unique per position")
    }

    func testOwnPromptsShowTheirAttachmentsBeforeTheTranscriptHasThem() {
        let shown = MessageAttachment(
            id: "kg1", kind: .image, name: "a.jpg", mimeType: "image/jpeg", size: 9, storageId: "kg1", isLocal: true)
        XCTAssertTrue(shown.showsAsImage, "this phone has the bytes")
        let local = LocalPrompt(clientId: "x", text: "", createdAt: 1, attachments: [shown], inputs: [])
        let pendingCommand = PromptCommand(
            id: "c2", clientId: "y", text: "", status: .pending, error: nil, fromLabel: "Web", mine: true,
            attachments: [Attachment(storageId: "kg5", name: "spec.pdf", mimeType: "application/pdf", size: 9, kind: .file, url: "https://x/5")],
            createdAt: 2, updatedAt: 2)
        let items = TranscriptBuilder.build(events: [], commands: [pendingCommand], local: [local], hasOlder: false)
        let messages = items.compactMap { item -> UserMessage? in
            if case .user(let message) = item.kind { return message }
            return nil
        }
        XCTAssertEqual(messages.map { $0.attachments.map(\.name) }, [["a.jpg"], ["spec.pdf"]])
    }
}

/// The composer's strip: prepare, upload with progress, retry, limits.
@MainActor
final class AttachmentDraftTests: XCTestCase {
    private final class FakeFiles: FilesAPI, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var failNext = 0
        private(set) var types: [String] = []

        func upload(_ data: Data, contentType: String, progress: @escaping @Sendable (Double) -> Void) async throws -> String {
            try await Task.sleep(for: .milliseconds(10))
            progress(0.5)
            return try lock.withLock {
                types.append(contentType)
                if failNext > 0 {
                    failNext -= 1
                    throw RelayError(.network, "down")
                }
                count += 1
                return "kg\(count)"
            }
        }
    }

    private final class Kept: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        func add(_ key: String) { lock.withLock { stored.append(key) } }
        var keys: [String] { lock.withLock { stored } }
    }

    private func until(_ what: String, timeout: Double = 5, _ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("timed out waiting for \(what)")
    }

    private func photo() -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 300, height: 200), format: format).jpegData(withCompressionQuality: 0.9) {
            UIColor.orange.setFill()
            $0.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
        }
    }

    func testAPhotoAndAFileUploadThenGoWithThePrompt() async {
        let files = FakeFiles()
        let kept = Kept()
        let draft = AttachmentDraft(files: files, keep: { _, key in kept.add(key) })
        draft.add([.photo(photo(), name: "photo-20261026-120000.jpg"), .file(Data("hello".utf8), name: "notes.md", mimeType: "text/markdown")])
        XCTAssertEqual(draft.items.count, 2)
        XCTAssertFalse(draft.isReady, "uploading")
        await until("both uploaded") { draft.isReady }
        XCTAssertEqual(draft.items.map(\.kind), [.image, .file])
        XCTAssertEqual(draft.items[0].width, 300)
        XCTAssertNotNil(draft.items[0].thumbnail)
        let inputs = draft.inputs
        XCTAssertEqual(inputs.count, 2)
        XCTAssertNotNil(inputs[0].thumbId, "the photo has a thumbnail upload")
        XCTAssertNil(inputs[1].thumbId)
        XCTAssertEqual(inputs[1].name, "notes.md")
        XCTAssertTrue(files.types.contains("text/markdown"))
        await until("kept on the phone") { kept.keys.count == 3 }
        XCTAssertTrue(draft.messageAttachments.allSatisfy(\.isLocal))
        draft.clear()
        XCTAssertTrue(draft.isEmpty)
    }

    func testAFailedUploadRetriesOnTap() async {
        let files = FakeFiles()
        files.failNext = 1
        let draft = AttachmentDraft(files: files, keep: { _, _ in })
        draft.add([.file(Data("x".utf8), name: "a.txt", mimeType: "text/plain")])
        await until("failed") {
            if case .failed = draft.items.first?.state { return true }
            return false
        }
        XCTAssertFalse(draft.isReady)
        draft.retry(draft.items[0].id)
        await until("uploaded") { draft.isReady }
        XCTAssertEqual(draft.inputs.first?.storageId, "kg1")
    }

    func testLimits() async {
        let draft = AttachmentDraft(files: FakeFiles(), keep: { _, _ in })
        draft.add([.file(Data(count: AttachmentLimits.maxFileBytes + 1), name: "big.bin", mimeType: "application/octet-stream")])
        XCTAssertTrue(draft.isEmpty)
        XCTAssertEqual(draft.notice, .tooBig)
        draft.add((0..<12).map { .file(Data("\($0)".utf8), name: "\($0).txt", mimeType: "text/plain") })
        XCTAssertEqual(draft.items.count, 10)
        XCTAssertEqual(draft.notice, .tooMany)
        XCTAssertEqual(draft.remaining, 0)
        draft.remove(draft.items[0].id)
        XCTAssertEqual(draft.items.count, 9)
        await until("uploaded") { draft.isReady }
    }
}

/// Sending photos and files through the demo relay, end to end in the app's own models.
@MainActor
final class AttachmentFlowTests: XCTestCase {
    private func makeEngine() -> (CrokEngine, DemoWorld) {
        let world = DemoWorld()
        let credentials = StoredCredentials(
            serverURL: "https://demo", deviceId: "demo-phone", refreshToken: "r", user: AccountUser(), deviceName: "Phone",
            signedInAt: 0)
        let drafts = DraftStore(defaults: UserDefaults(suiteName: "crok.attachments.\(UUID().uuidString)")!)
        let engine = CrokEngine(backend: DemoRelay(world: world), credentials: credentials, isDemo: true, drafts: drafts, cache: nil)
        engine.start()
        return (engine, world)
    }

    private func until(_ what: String, timeout: Double = 8, _ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("timed out waiting for \(what)")
    }

    func testAPhotoAloneIsAPromptAndReachesTheTranscript() async {
        let (engine, world) = makeEngine()
        let model = SessionViewModel(sessionDocId: "s-relay", engine: engine)
        model.appear()
        await until("the session") { model.detail.value != nil }
        XCTAssertFalse(model.canSendDraft, "nothing to send")
        let sample = DemoMedia.photos(count: 1, at: Date())[0]
        model.attachments.add([.photo(sample.data, name: sample.name)])
        XCTAssertFalse(model.canSendDraft, "still uploading")
        await until("uploaded") { model.attachments.isReady }
        XCTAssertTrue(model.canSendDraft, "a photo alone can be sent")
        model.draft = "/model"
        model.send()
        XCTAssertTrue(model.botCards.isEmpty, "with attachments the text goes as a prompt")
        XCTAssertTrue(model.attachments.isEmpty, "the strip is cleared")
        await until("in the transcript") {
            world.sessions.first(where: { $0.detail.id == "s-relay" })?.events.last(where: { $0.kind == .user })?.attachments != nil
        }
        let event = world.sessions.first(where: { $0.detail.id == "s-relay" })?.events.last(where: { $0.kind == .user })
        XCTAssertEqual(event?.text, "/model")
        XCTAssertEqual(event?.attachments?.first?.kind, .image)
        XCTAssertEqual(event?.attachments?.first?.mimeType, "image/jpeg")
        XCTAssertNotNil(event?.attachments?.first?.thumbId)
        model.tearDown()
        await engine.shutdown()
    }

    func testANewSessionStartsWithAFile() async {
        let (engine, world) = makeEngine()
        await until("the list") { !engine.groups.isEmpty }
        let model = NewSessionModel(
            target: NewSessionTarget(deviceId: "mbp", deviceName: "MacBook Pro", path: "/Users/charlie/src/website"),
            engine: engine)
        XCTAssertFalse(model.canSend)
        model.attachments.add([.file(Data("spec".utf8), name: "spec.md", mimeType: "text/markdown")])
        await until("uploaded") { model.attachments.isReady }
        XCTAssertTrue(model.canSend)
        var created: DocID?
        model.onCreated = { created = $0 }
        await model.send()
        XCTAssertNotNil(created)
        XCTAssertTrue(model.attachments.isEmpty)
        let session = world.sessions.first(where: { $0.detail.id == created })
        XCTAssertEqual(session?.commands.first?.attachments?.first?.name, "spec.md")
        XCTAssertEqual(engine.localPrompts[created ?? ""]?.first?.attachments.first?.name, "spec.md", "shown at once")
        await engine.shutdown()
    }
}
