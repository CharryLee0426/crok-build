import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Full-resolution images seen in transcripts (sent, replayed, returned by tools), kept beside
/// the state file under the SHA-256 of their bytes.
///
/// A transcript line holds only a small thumbnail and the stored file's name: a few megabytes
/// of base64 per image would make every launch decode, and every save rewrite, all of them.
enum ImageStore {
    /// `images/` beside the state file; the store points it at its own state file.
    nonisolated(unsafe) static var directory: URL = {
        // A test that reduces a transcript without making a store must not write into the user's app data.
        if NSClassFromString("XCTestCase") != nil {
            return FileManager.default.temporaryDirectory.appendingPathComponent("CrokDesktopTestImages-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        }
        return DesktopPaths.stateFile.deletingLastPathComponent().appendingPathComponent("images", isDirectory: true)
    }()
    /// Unreferenced files younger than this survive a sweep: their message may not be saved yet.
    static let sweepGrace: TimeInterval = 3_600

    static func url(_ blob: String) -> URL { directory.appendingPathComponent(blob) }

    /// Stores the bytes and returns the file name, at once: the file is written off the main thread.
    @discardableResult
    static func store(_ data: Data, mimeType: String?) -> String {
        let name = blobName(data, mimeType: mimeType)
        let file = url(name)
        let directory = directory
        Task.detached(priority: .utility) {
            guard !FileManager.default.fileExists(atPath: file.path) else { return }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
        return name
    }

    /// Writes the bytes before returning, for callers that need the file right away.
    static func storeNow(_ data: Data, mimeType: String?) -> URL? {
        let file = url(blobName(data, mimeType: mimeType))
        if FileManager.default.fileExists(atPath: file.path) { return file }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (try? data.write(to: file, options: .atomic)) == nil ? nil : file
    }

    static func blobName(_ data: Data, mimeType: String?) -> String {
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let ext = mimeType.flatMap { UTType(mimeType: $0)?.preferredFilenameExtension } ?? "img"
        return "\(hash).\(ext)"
    }

    /// Removes stored images no transcript refers to any more (their tasks were deleted).
    static func sweep(keeping referenced: Set<String>, now: Date = Date()) {
        let directory = directory
        let grace = sweepGrace
        Task.detached(priority: .utility) {
            let fm = FileManager.default
            guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return }
            for name in names where !referenced.contains(name) {
                let file = directory.appendingPathComponent(name)
                let modified = (try? fm.attributesOfItem(atPath: file.path)[.modificationDate] as? Date) ?? now
                if now.timeIntervalSince(modified) > grace { try? fm.removeItem(at: file) }
            }
        }
    }

    /// The images a transcript shows, as the store names them.
    static func referenced(by conversations: [Conversation]) -> Set<String> {
        var names = Set<String>()
        for conversation in conversations {
            for message in conversation.messages { for attachment in message.attachments ?? [] { if let blob = attachment.blob { names.insert(blob) } } }
        }
        return names
    }
}

extension MessageAttachment {
    /// A transcript image made from encoded bytes: a thumbnail for the row and the bytes stored whole.
    static func image(data: Data, mimeType: String?, name: String, path: String? = nil, origin: Origin? = nil) -> MessageAttachment? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        var width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue
        var height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        // Orientations 5–8 turn the image a quarter, so it shows with its sides swapped.
        if let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue, orientation >= 5 { swap(&width, &height) }
        let hasAlpha = properties[kCGImagePropertyHasAlpha] as? Bool ?? false
        let thumbnail = PromptAttachmentsModel.downscaled(source, maxSide: PromptAttachmentsModel.thumbnailSide)
            .flatMap { PromptAttachmentsModel.encode($0, as: hasAlpha ? .png : .jpeg, quality: 0.72) }
        let mime = mimeType ?? (CGImageSourceGetType(source) as String?).flatMap { UTType($0)?.preferredMIMEType }
        return MessageAttachment(kind: .image, name: name, path: path, thumbnail: thumbnail, blob: ImageStore.store(data, mimeType: mime),
                                 mimeType: mime, pixelWidth: width, pixelHeight: height, origin: origin)
    }

    /// Where the image can be read whole: its own file while it exists, else the stored copy.
    var fullImageURL: URL? {
        if let path, path.hasPrefix("/"), FileManager.default.fileExists(atPath: path) { return URL(fileURLWithPath: path) }
        if let blob {
            let url = ImageStore.url(blob)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    /// The image's own file (not the store's copy), to reveal in Finder.
    var revealablePath: String? {
        guard let path, path.hasPrefix("/"), !PromptAttachmentsModel.isScratch(URL(fileURLWithPath: path)),
              FileManager.default.fileExists(atPath: path) else { return nil }
        return path
    }

    var pixelSize: CGSize? {
        guard let pixelWidth, let pixelHeight, pixelWidth > 0, pixelHeight > 0 else { return nil }
        return CGSize(width: pixelWidth, height: pixelHeight)
    }
}
