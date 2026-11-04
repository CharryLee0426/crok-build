import ImageIO
import SwiftUI
import UIKit

/// Photos and files from the relay, cached on disk by storage id (`thumbId` for thumbnails): storage URLs are stable,
/// so a file is fetched once. This phone's own uploads are put here when they finish, so its bubbles show them at once.
final class AttachmentStore: @unchecked Sendable {
    static let shared = AttachmentStore()

    private let folder: URL
    /// Decoded images by key and display size. NSCache is thread-safe.
    private let images = NSCache<NSString, UIImage>()
    private let lock = NSLock()
    private var loads: [String: Task<Data?, Never>] = [:]
    private let session: URLSession

    init(folder: URL? = nil, session: URLSession = .shared) {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.folder = folder ?? caches.appendingPathComponent("attachments", isDirectory: true)
        self.session = session
        images.countLimit = 120
        try? FileManager.default.createDirectory(at: self.folder, withIntermediateDirectories: true)
    }

    private func path(_ key: String) -> URL {
        let safe = key.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" }
        return folder.appendingPathComponent(String(safe))
    }

    /// Keeps `data` under `key` (an upload this phone made, or demo content).
    func store(_ data: Data, key: String) {
        try? data.write(to: path(key), options: .atomic)
    }

    func hasData(_ key: String) -> Bool {
        FileManager.default.fileExists(atPath: path(key).path)
    }

    func cachedData(_ key: String) -> Data? {
        try? Data(contentsOf: path(key))
    }

    /// The bytes for `key`: from disk, else downloaded from `url` once (concurrent callers share the download).
    func data(key: String, url: URL?) async -> Data? {
        if let cached = cachedData(key) { return cached }
        guard let url else { return nil }
        let task = lock.withLock { () -> Task<Data?, Never> in
            if let running = loads[key] { return running }
            let session = self.session
            let task = Task<Data?, Never> {
                guard let (data, response) = try? await session.data(from: url),
                    let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
                else { return nil }
                return data
            }
            loads[key] = task
            return task
        }
        let data = await task.value
        lock.withLock { loads[key] = nil }
        if let data { store(data, key: key) }
        return data
    }

    /// An image decoded at most `maxPixel` on its longer side (a tile does not need a 2048 px bitmap).
    func image(key: String, url: URL?, maxPixel: CGFloat) async -> UIImage? {
        let cacheKey = "\(key)@\(Int(maxPixel))" as NSString
        if let image = images.object(forKey: cacheKey) { return image }
        guard let data = await data(key: key, url: url), let image = Self.decode(data, maxPixel: maxPixel) else {
            return nil
        }
        images.setObject(image, forKey: cacheKey)
        return image
    }

    /// A decoded image already in memory, for the first frame of a view (no flash of the placeholder).
    func cachedImage(key: String, maxPixel: CGFloat) -> UIImage? {
        images.object(forKey: "\(key)@\(Int(maxPixel))" as NSString)
    }

    static func decode(_ data: Data, maxPixel: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, Int(maxPixel)),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }

    /// A copy named like the file in a temporary folder, for Quick Look and sharing.
    func namedCopy(key: String, name: String) -> URL? {
        guard let data = cachedData(key) else { return nil }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("attachments", isDirectory: true)
            .appendingPathComponent(path(key).lastPathComponent, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(name.isEmpty ? "file" : name)
        do {
            if !FileManager.default.fileExists(atPath: file.path) { try data.write(to: file, options: .atomic) }
            return file
        } catch {
            return nil
        }
    }
}

/// An attachment's image: the thumbnail first (or only, for tiles), then the full image when `full`; a tinted
/// placeholder of the right shape while loading.
struct AttachmentImageView: View {
    let attachment: MessageAttachment
    /// Load the full image (the viewer) instead of the thumbnail.
    var full = false
    var maxPixel: CGFloat = 900
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image = image ?? cached {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle()
                    .fill(Color.secondary.opacity(0.18))
                    .overlay {
                        Image(systemName: "photo")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .task(id: attachment.id + (full ? "+full" : "")) {
            let store = AttachmentStore.shared
            if let thumbId = attachment.thumbId,
                let thumb = await store.image(key: thumbId, url: attachment.thumbURL, maxPixel: maxPixel)
            {
                image = thumb
                if !full { return }
            }
            guard let storageId = attachment.storageId else { return }
            if let loaded = await store.image(key: storageId, url: attachment.url, maxPixel: full ? Self.fullPixel : maxPixel) {
                image = loaded
            }
        }
    }

    static let fullPixel: CGFloat = 2400

    /// What is already decoded in memory, best first.
    private var cached: UIImage? {
        let store = AttachmentStore.shared
        if full, let storageId = attachment.storageId, let image = store.cachedImage(key: storageId, maxPixel: Self.fullPixel) {
            return image
        }
        if let thumbId = attachment.thumbId, let image = store.cachedImage(key: thumbId, maxPixel: maxPixel) { return image }
        if let storageId = attachment.storageId { return store.cachedImage(key: storageId, maxPixel: maxPixel) }
        return nil
    }
}
