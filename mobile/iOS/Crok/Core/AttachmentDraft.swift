import Foundation
import Observation

/// Something picked to attach: a photo (photo library, camera, a demo sample) is always prepared as an image; a file
/// from Files is prepared as an image when it is one, else sent as it is.
enum AttachmentSource: Sendable {
    case photo(Data, name: String)
    case file(Data, name: String, mimeType: String)
}

/// The photos and files waiting in a composer (relay/DESIGN.md §5 "Photos and files in prompts"): each is prepared and
/// uploaded as soon as it is attached, shows its progress, and retries on tap when the upload failed. Kept per
/// session draft while the app runs (`CrokEngine.attachments(for:)`), not across a restart.
@MainActor
@Observable
final class AttachmentDraft {
    struct Item: Identifiable, Equatable {
        enum State: Equatable {
            case preparing
            /// The share of the bytes sent.
            case uploading(Double)
            case uploaded
            case failed(String)
        }

        let id: UUID
        var kind: AttachmentKind
        var name: String
        var mimeType: String
        var size: Int
        var width: Int?
        var height: Int?
        /// A small JPEG for the strip (images only).
        var thumbnail: Data?
        var storageId: String?
        var thumbId: String?
        var state: State

        var isUploading: Bool {
            switch state {
            case .preparing, .uploading: true
            case .uploaded, .failed: false
            }
        }
    }

    enum Notice: Equatable {
        case tooMany
        case tooBig

        var text: String {
            switch self {
            case .tooMany: String(localized: "Up to 10 photos and files per message")
            case .tooBig: String(localized: "Files are limited to 20 MB")
            }
        }
    }

    private(set) var items: [Item] = []
    /// A short notice above the strip (too many, too big); the view clears it after a moment.
    var notice: Notice?

    @ObservationIgnored private let files: any FilesAPI
    /// Keeps an upload's bytes on the phone under its storage id (the attachment store), so bubbles show it at once.
    @ObservationIgnored private let keep: @Sendable (Data, String) -> Void
    /// What each item was made from and its prepared bytes, kept for a retry.
    @ObservationIgnored private var sources: [UUID: AttachmentSource] = [:]
    @ObservationIgnored private var prepared: [UUID: Prepared] = [:]
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]

    struct Prepared: Sendable {
        var data: Data
        var kind: AttachmentKind
        var name: String
        var mimeType: String
        var width: Int?
        var height: Int?
        var thumbnail: Data?
    }

    init(files: any FilesAPI, keep: @escaping @Sendable (Data, String) -> Void = { AttachmentStore.shared.store($0, key: $1) }) {
        self.files = files
        self.keep = keep
    }

    var isEmpty: Bool { items.isEmpty }

    /// Every attachment is uploaded (nothing is preparing, uploading or failed).
    var isReady: Bool { items.allSatisfy { $0.state == .uploaded } }

    /// How many more can be attached.
    var remaining: Int { max(0, AttachmentLimits.maxCount - items.count) }

    /// Attaches what was picked, in order, up to the limit; the rest is left out with a notice.
    func add(_ picked: [AttachmentSource]) {
        for source in picked {
            guard items.count < AttachmentLimits.maxCount else {
                notice = .tooMany
                return
            }
            let (name, kind, mime, size) = Self.describe(source)
            if kind == .file, size > AttachmentLimits.maxFileBytes {
                notice = .tooBig
                continue
            }
            let item = Item(id: UUID(), kind: kind, name: name, mimeType: mime, size: size, state: .preparing)
            items.append(item)
            sources[item.id] = source
            start(item.id)
        }
    }

    func remove(_ id: UUID) {
        tasks[id]?.cancel()
        tasks[id] = nil
        sources[id] = nil
        prepared[id] = nil
        items.removeAll { $0.id == id }
    }

    /// A failed upload, tapped: prepared again if it never was, then uploaded again.
    func retry(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }), case .failed = item.state else { return }
        update(id) { $0.state = prepared[id] == nil ? .preparing : .uploading(0) }
        start(id)
    }

    /// Empties the strip (the prompt was sent).
    func clear() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        sources.removeAll()
        prepared.removeAll()
        items.removeAll()
        notice = nil
    }

    /// What `commands:sendPrompt` and `sessions:create` take, in the strip's order.
    var inputs: [AttachmentInput] {
        items.compactMap { item in
            item.storageId.map {
                AttachmentInput(storageId: $0, thumbId: item.thumbId, name: item.name, width: item.width, height: item.height)
            }
        }
    }

    /// How the optimistic bubble shows them.
    var messageAttachments: [MessageAttachment] {
        items.map { item in
            MessageAttachment(
                id: item.storageId ?? item.id.uuidString, kind: item.kind, name: item.name, mimeType: item.mimeType,
                size: Double(item.size), width: item.width.map(Double.init), height: item.height.map(Double.init),
                storageId: item.storageId, thumbId: item.thumbId, isLocal: true)
        }
    }

    // MARK: Work

    private static func describe(_ source: AttachmentSource) -> (String, AttachmentKind, String, Int) {
        switch source {
        case .photo(let data, let name):
            return (name, .image, "image/jpeg", data.count)
        case .file(let data, let name, let mime):
            let image = mime.hasPrefix("image/") && ImagePreparer.isImage(data)
            return (name, image ? .image : .file, mime, data.count)
        }
    }

    /// Prepares the item off the main actor (unless it already was), then uploads it and its thumbnail.
    private func start(_ id: UUID) {
        guard let source = sources[id] else { return }
        tasks[id]?.cancel()
        let already = prepared[id]
        let files = self.files
        tasks[id] = Task { [weak self] in
            let ready: Prepared
            if let already {
                ready = already
            } else {
                guard let made = await Task.detached(priority: .userInitiated, operation: { Self.prepare(source) }).value
                else {
                    self?.update(id) { $0.state = .failed(String(localized: "This file can't be read.")) }
                    return
                }
                ready = made
            }
            guard let self, !Task.isCancelled else { return }
            if ready.data.count > AttachmentLimits.maxFileBytes {
                self.remove(id)
                self.notice = .tooBig
                return
            }
            self.prepared[id] = ready
            self.update(id) {
                $0.kind = ready.kind
                $0.name = ready.name
                $0.mimeType = ready.mimeType
                $0.size = ready.data.count
                $0.width = ready.width
                $0.height = ready.height
                $0.thumbnail = ready.thumbnail
                $0.state = .uploading(0)
            }
            do {
                let storageId = try await files.upload(ready.data, contentType: ready.mimeType) { [weak self] share in
                    Task { @MainActor in self?.progress(id, share) }
                }
                guard !Task.isCancelled else { return }
                self.keep(ready.data, storageId)
                // A thumbnail that does not get through only costs the preview: the image goes without one.
                var thumbId: String?
                if let thumbnail = ready.thumbnail {
                    thumbId = try? await files.upload(thumbnail, contentType: "image/jpeg") { _ in }
                    if let thumbId { self.keep(thumbnail, thumbId) }
                }
                guard !Task.isCancelled else { return }
                self.update(id) {
                    $0.storageId = storageId
                    $0.thumbId = thumbId
                    $0.state = .uploaded
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.update(id) { $0.state = .failed(String(localized: "Upload failed — tap to retry")) }
            }
            self.tasks[id] = nil
        }
    }

    private func progress(_ id: UUID, _ share: Double) {
        guard let item = items.first(where: { $0.id == id }), case .uploading(let shown) = item.state else { return }
        // Whole percents only: a big upload reports thousands of steps.
        let rounded = (min(1, share) * 100).rounded(.down) / 100
        if rounded > shown { update(id) { $0.state = .uploading(rounded) } }
    }

    private func update(_ id: UUID, _ change: (inout Item) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
    }

    /// The bytes to upload: images by the contract's rules, other files as they are.
    nonisolated static func prepare(_ source: AttachmentSource) -> Prepared? {
        switch source {
        case .photo(let data, let name):
            return preparedImage(data, name: name)
        case .file(let data, let name, let mime):
            if mime.hasPrefix("image/") && ImagePreparer.isImage(data), let image = preparedImage(data, name: name) {
                return image
            }
            return Prepared(data: data, kind: .file, name: name, mimeType: mime, thumbnail: nil)
        }
    }

    private nonisolated static func preparedImage(_ data: Data, name: String) -> Prepared? {
        guard let image = try? ImagePreparer.prepare(data, name: name) else { return nil }
        return Prepared(
            data: image.data, kind: .image, name: image.name, mimeType: image.mimeType, width: image.width,
            height: image.height, thumbnail: image.thumbnail)
    }
}
