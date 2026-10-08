import AppKit
import ImageIO
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// An image, file, or folder waiting in the composer to be sent with the prompt.
struct PromptAttachment: Identifiable, Equatable {
    enum Kind: Equatable { case image, file, folder }

    let id: UUID
    let kind: Kind
    let name: String
    /// The file or folder, or where a pasted image was saved so it can be previewed.
    let url: URL?
    var byteCount: Int?
    /// The encoded image sent to the model, once it is prepared.
    var imageData: Data?
    var mimeType: String?
    var thumbnail: NSImage?
    /// A small encoded copy of the thumbnail, kept with the sent message.
    var thumbnailData: Data?
    var failure: String?

    init(id: UUID = UUID(), kind: Kind, name: String, url: URL?, byteCount: Int? = nil) {
        self.id = id
        self.kind = kind
        self.name = name
        self.url = url
        self.byteCount = byteCount
    }

    var isPreparing: Bool { kind == .image && imageData == nil && failure == nil }

    static func == (lhs: PromptAttachment, rhs: PromptAttachment) -> Bool {
        lhs.id == rhs.id && lhs.imageData?.count == rhs.imageData?.count && lhs.failure == rhs.failure && lhs.thumbnail === rhs.thumbnail
    }

    /// The ACP content block for this attachment. Files and folders are resource links, which
    /// the harness lists for the model; it also inlines small text files.
    var promptBlock: [String: Any]? {
        switch kind {
        case .image:
            guard let imageData, let mimeType else { return nil }
            return ["type": "image", "data": imageData.base64EncodedString(), "mimeType": mimeType]
        case .file, .folder:
            guard let url else { return nil }
            var block: [String: Any] = ["type": "resource_link", "uri": url.absoluteString, "name": name]
            if let byteCount, kind == .file { block["size"] = byteCount }
            if let type = UTType(filenameExtension: url.pathExtension), kind == .file, let mime = type.preferredMIMEType { block["mimeType"] = mime }
            // Without `_meta` the harness also puts `@path` in the prompt, which reads a small
            // text file inline; a folder has nothing to read that way.
            if kind == .folder { block["_meta"] = ["x.ai/kind": "directory"] }
            return block
        }
    }

    var messageAttachment: MessageAttachment {
        let sentKind: MessageAttachment.Kind = kind == .image ? .image : kind == .folder ? .folder : .file
        var attachment = MessageAttachment(id: id, kind: sentKind, name: name, path: url?.path, thumbnail: thumbnailData)
        // The sent bytes are kept whole: a pasted image's scratch file does not outlive the session.
        if kind == .image, let imageData {
            attachment.blob = ImageStore.store(imageData, mimeType: mimeType)
            attachment.mimeType = mimeType
            if let source = CGImageSourceCreateWithData(imageData as CFData, nil),
               let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
                attachment.pixelWidth = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue
                attachment.pixelHeight = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
            }
        }
        return attachment
    }
}

/// The composer's attachments, kept per draft (each task, and each project's new-task draft),
/// like the draft text itself.
@MainActor
final class PromptAttachmentsModel: ObservableObject {
    weak var store: AppStore?
    @Published private(set) var drafts: [AppStore.DraftLocation: [PromptAttachment]] = [:]
    /// The file Quick Look is showing, if any.
    @Published var previewURL: URL?

    /// Past this many attachments a prompt is refused; images also count toward the harness's request budget.
    static let limit = 20
    /// Images are sent at most this large on their longest side; the harness downsamples further as a model needs.
    nonisolated static let maximumImageSide: CGFloat = 2_048
    nonisolated static let maximumImageBytes = 3_500_000
    nonisolated static let thumbnailSide: CGFloat = 320

    init(store: AppStore) { self.store = store }

    var current: [PromptAttachment] {
        guard let store else { return [] }
        return drafts[store.draftLocation] ?? []
    }

    var isPreparing: Bool { current.contains(where: \.isPreparing) }

    // MARK: Adding

    /// Files, folders, and image files, as chosen, dropped, or pasted.
    func add(urls: [URL]) {
        guard let store else { return }
        guard store.project != nil else { store.banner = "Open a project before attaching files."; return }
        for url in urls {
            let url = url.standardizedFileURL
            guard !current.contains(where: { $0.url == url }) else { continue }
            guard reserveSlot() else { return }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentTypeKey, .isPackageKey])
            if values?.isDirectory == true && values?.isPackage != true {
                append(PromptAttachment(kind: .folder, name: url.lastPathComponent, url: url))
            } else if let type = values?.contentType, type.conforms(to: .image), type != .svg, type != .pdf {
                let attachment = PromptAttachment(kind: .image, name: url.lastPathComponent, url: url, byteCount: values?.fileSize)
                append(attachment)
                prepareImage(attachment.id, source: .file(url))
            } else {
                append(PromptAttachment(kind: .file, name: url.lastPathComponent, url: url, byteCount: values?.fileSize))
            }
        }
    }

    /// Image data without a file, such as a pasted screenshot. It is saved to a scratch folder so it can be previewed.
    func add(imageData data: Data, suggestedName: String? = nil) {
        guard let store else { return }
        guard store.project != nil else { store.banner = "Open a project before attaching images."; return }
        guard reserveSlot() else { return }
        let id = UUID()
        let type = CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceGetType($0) as String? }.flatMap(UTType.init) ?? .png
        let fileExtension = type.preferredFilenameExtension ?? "png"
        let name = suggestedName ?? "Image \(current.filter { $0.kind == .image }.count + 1).\(fileExtension)"
        let url = Self.scratchDirectory.appendingPathComponent("\(id.uuidString).\(fileExtension)")
        try? FileManager.default.createDirectory(at: Self.scratchDirectory, withIntermediateDirectories: true)
        let saved = (try? data.write(to: url, options: .atomic)) != nil
        append(PromptAttachment(id: id, kind: .image, name: name, url: saved ? url : nil, byteCount: data.count))
        prepareImage(id, source: .data(data))
    }

    /// Dropped items: files and folders by URL, and images from apps that drag image data.
    @discardableResult
    func add(providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                _ = provider.loadObject(ofClass: URL.self) { [weak self] url, _ in
                    guard let url else { return }
                    Task { @MainActor in self?.add(urls: [url]) }
                }
            } else if let type = [UTType.png, .jpeg, .tiff, .heic, .gif, .webP, .image].first(where: { provider.hasItemConformingToTypeIdentifier($0.identifier) }) {
                handled = true
                let name = provider.suggestedName.map { "\($0).\(type.preferredFilenameExtension ?? "png")" }
                provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { [weak self] data, _ in
                    guard let data else { return }
                    Task { @MainActor in self?.add(imageData: data, suggestedName: name) }
                }
            }
        }
        return handled
    }

    /// ⌘V in the composer: copied files, or an image without text, become attachments.
    /// Returns false for anything that should paste as text.
    func paste(from pasteboard: NSPasteboard) -> Bool {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            add(urls: urls)
            return true
        }
        let types = pasteboard.types ?? []
        // Documents copy text with a picture of it; those paste as text.
        let isRichText = types.contains(.string) && (types.contains(.rtf) || types.contains(.html) || types.contains(.rtfd))
        guard !isRichText, let type = Self.imageTypes.first(where: types.contains), let data = pasteboard.data(forType: type) else { return false }
        add(imageData: data)
        return true
    }

    nonisolated static let imageTypes: [NSPasteboard.PasteboardType] = [.png, .tiff, NSPasteboard.PasteboardType(UTType.jpeg.identifier), NSPasteboard.PasteboardType(UTType.heic.identifier)]

    /// A drag onto the prompt: files and folders, or image data. Plain text is left to the editor.
    func drop(from pasteboard: NSPasteboard) -> Bool {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            add(urls: urls)
            return true
        }
        guard let type = Self.imageTypes.first(where: { pasteboard.types?.contains($0) == true }), let data = pasteboard.data(forType: type) else { return false }
        add(imageData: data)
        return true
    }

    /// Whether a drag carries something to attach rather than text to insert.
    nonisolated static func carriesAttachments(_ pasteboard: NSPasteboard) -> Bool {
        if pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) { return true }
        return pasteboard.availableType(from: imageTypes) != nil
    }

    /// The composer's + menu.
    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        panel.prompt = "Attach"; panel.message = "Choose photos and files to send with your prompt."
        if let root = store?.project?.path { panel.directoryURL = URL(fileURLWithPath: root, isDirectory: true) }
        guard panel.runModal() == .OK else { return }
        add(urls: panel.urls)
        NotificationCenter.default.post(name: .grokFocusComposer, object: nil)
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        panel.prompt = "Attach"; panel.message = "Choose folders to send with your prompt."
        if let root = store?.project?.path { panel.directoryURL = URL(fileURLWithPath: root, isDirectory: true) }
        guard panel.runModal() == .OK else { return }
        add(urls: panel.urls)
        NotificationCenter.default.post(name: .grokFocusComposer, object: nil)
    }

    // MARK: Removing and sending

    func remove(_ id: UUID) {
        guard let location = store?.draftLocation else { return }
        drafts[location]?.removeAll { $0.id == id }
        if drafts[location]?.isEmpty == true { drafts.removeValue(forKey: location) }
    }

    /// Hands the draft's attachments to a prompt that is being sent.
    func take(from location: AppStore.DraftLocation) -> [PromptAttachment] {
        drafts.removeValue(forKey: location) ?? []
    }

    /// Puts attachments back, for a prompt that could not be sent.
    func restore(_ attachments: [PromptAttachment], to location: AppStore.DraftLocation) {
        guard !attachments.isEmpty else { return }
        drafts[location] = attachments + (drafts[location] ?? [])
    }

    func preview(_ attachment: PromptAttachment) {
        guard let url = attachment.url else { return }
        if attachment.kind == .folder { NSWorkspace.shared.activateFileViewerSelecting([url]); return }
        previewURL = url
    }

    private func append(_ attachment: PromptAttachment) {
        guard let location = store?.draftLocation else { return }
        drafts[location, default: []].append(attachment)
    }

    private func reserveSlot() -> Bool {
        guard current.count < Self.limit else {
            store?.banner = "A prompt can carry up to \(Self.limit) attachments."
            return false
        }
        return true
    }

    private func update(_ id: UUID, _ change: (inout PromptAttachment) -> Void) {
        for location in drafts.keys {
            guard let index = drafts[location]?.firstIndex(where: { $0.id == id }) else { continue }
            change(&drafts[location]![index])
            return
        }
    }

    // MARK: Images

    enum ImageSource: Sendable {
        case file(URL)
        case data(Data)
    }

    struct PreparedImage: Sendable {
        let data: Data
        let mimeType: String
        let thumbnail: CGImage?
        let thumbnailData: Data?
    }

    private func prepareImage(_ id: UUID, source: ImageSource) {
        Task { [weak self] in
            let prepared = await Task.detached(priority: .userInitiated) { Self.prepare(source) }.value
            guard let self else { return }
            self.update(id) { attachment in
                guard let prepared else { attachment.failure = "This image could not be read."; return }
                attachment.imageData = prepared.data
                attachment.mimeType = prepared.mimeType
                attachment.thumbnailData = prepared.thumbnailData
                attachment.thumbnail = prepared.thumbnail.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
            }
        }
    }

    /// Encodes an image the way models accept it: PNG, JPEG, GIF, or WebP bytes as they are when
    /// small enough, otherwise downscaled and re-encoded (JPEG, or PNG to keep transparency).
    nonisolated static func prepare(_ source: ImageSource) -> PreparedImage? {
        let imageSource: CGImageSource?
        switch source {
        case .file(let url): imageSource = CGImageSourceCreateWithURL(url as CFURL, nil)
        case .data(let data): imageSource = CGImageSourceCreateWithData(data as CFData, nil)
        }
        guard let imageSource, CGImageSourceGetCount(imageSource) > 0 else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any] ?? [:]
        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0
        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let hasAlpha = properties[kCGImagePropertyHasAlpha] as? Bool ?? false
        let type = (CGImageSourceGetType(imageSource) as String?).flatMap(UTType.init)
        let original: Data? = {
            switch source {
            case .file(let url): return try? Data(contentsOf: url, options: .mappedIfSafe)
            case .data(let data): return data
            }
        }()
        let thumbnail = downscaled(imageSource, maxSide: thumbnailSide)
        let thumbnailData = thumbnail.flatMap { encode($0, as: hasAlpha ? .png : .jpeg, quality: 0.72) }

        let sendable: [UTType: String] = [.png: "image/png", .jpeg: "image/jpeg", .gif: "image/gif", .webP: "image/webp"]
        if let type, let mime = sendable[type], let original, original.count <= maximumImageBytes,
           max(width, height) <= maximumImageSide, orientation == 1 {
            return PreparedImage(data: original, mimeType: mime, thumbnail: thumbnail, thumbnailData: thumbnailData)
        }
        guard let image = downscaled(imageSource, maxSide: min(maximumImageSide, max(width, height, 1))) else { return nil }
        if hasAlpha, let png = encode(image, as: .png), png.count <= maximumImageBytes {
            return PreparedImage(data: png, mimeType: "image/png", thumbnail: thumbnail, thumbnailData: thumbnailData)
        }
        for quality in [0.86, 0.76, 0.64, 0.5] {
            if let jpeg = encode(image, as: .jpeg, quality: quality), jpeg.count <= maximumImageBytes {
                return PreparedImage(data: jpeg, mimeType: "image/jpeg", thumbnail: thumbnail, thumbnailData: thumbnailData)
            }
        }
        guard let smaller = downscaled(imageSource, maxSide: maximumImageSide / 2), let jpeg = encode(smaller, as: .jpeg, quality: 0.6) else { return nil }
        return PreparedImage(data: jpeg, mimeType: "image/jpeg", thumbnail: thumbnail, thumbnailData: thumbnailData)
    }

    /// The image with its orientation applied, no larger than `maxSide` pixels on its longest side.
    nonisolated static func downscaled(_ source: CGImageSource, maxSide: CGFloat) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxSide.rounded()),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    nonisolated static func encode(_ image: CGImage, as type: UTType, quality: Double = 1) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// Where pasted and dragged image data is saved while it waits to be sent.
    nonisolated static let scratchDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("CrokDesktopAttachments", isDirectory: true)

    nonisolated static func isScratch(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(scratchDirectory.standardizedFileURL.path)
    }
}

enum PromptBlocks {
    /// The `session/prompt` content: the text (when there is any), then each attachment.
    static func make(text: String, meta: [String: Any]? = nil, attachments: [PromptAttachment]) -> [[String: Any]] {
        var blocks: [[String: Any]] = []
        if !text.isEmpty || attachments.isEmpty {
            var block: [String: Any] = ["type": "text", "text": text]
            if let meta { block["_meta"] = meta }
            blocks.append(block)
        }
        blocks += attachments.compactMap(\.promptBlock)
        return blocks
    }
}

// MARK: - Composer views

/// The attachments above the prompt: image thumbnails and file chips, each removable.
/// More than fit scroll sideways, and never show outside the card they are in.
struct ComposerAttachmentStrip: View {
    let attachments: [PromptAttachment]
    /// The card's padding. The strip runs through it to the card's edges, fading out on the way.
    var bleed: CGFloat = 0
    var onRemove: (UUID) -> Void
    var onPreview: (PromptAttachment) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let row = "attachments"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(attachments) { attachment in
                        ComposerAttachmentTile(attachment: attachment, onRemove: { onRemove(attachment.id) }, onPreview: { onPreview(attachment) })
                    }
                }
                .padding(.top, 7).padding(.trailing, 7 + bleed).padding(.leading, 1 + bleed)
                .id(Self.row)
            }
            .mask { fade }
            .padding(.horizontal, -bleed)
            .onChange(of: attachments.map(\.id)) { previous, ids in
                // An attachment is added at the end, which may be out of sight.
                guard ids.count > previous.count, ids.last != previous.last else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { proxy.scrollTo(Self.row, anchor: .trailing) }
            }
        }
    }

    /// Opaque over the strip, clear at the card's edges.
    private var fade: some View {
        HStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing).frame(width: bleed)
            Color.black
            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: bleed)
        }
    }
}

private struct ComposerAttachmentTile: View {
    let attachment: PromptAttachment
    var onRemove: () -> Void
    var onPreview: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: onPreview) {
            Group {
                if attachment.kind == .image { imageTile } else { fileChip }
            }
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            if hovered {
                Button(action: onRemove) {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.canvas)
                        .frame(width: 18, height: 18).background(Theme.ink.opacity(0.85), in: Circle())
                }
                .buttonStyle(.plain).offset(x: 6, y: -6)
                .help("Remove \(attachment.name)").accessibilityLabel("Remove \(attachment.name)")
            }
        }
        .onHover { hovered = $0 }
        .help(attachment.failure ?? attachment.url?.path ?? attachment.name)
        .contextMenu {
            if attachment.url != nil { Button("Quick Look", systemImage: "eye", action: onPreview) }
            if let url = attachment.url, !PromptAttachmentsModel.isScratch(url) {
                Button("Reveal in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
            Divider()
            Button("Remove", systemImage: "xmark", role: .destructive, action: onRemove)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(kindLabel): \(attachment.name)")
        .accessibilityAction(named: "Remove", onRemove)
    }

    private var kindLabel: String {
        switch attachment.kind {
        case .image: return "Image"
        case .file: return "File"
        case .folder: return "Folder"
        }
    }

    private var imageTile: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12).fill(Theme.hover)
            if let thumbnail = attachment.thumbnail {
                Image(nsImage: thumbnail).resizable().scaledToFill()
            } else if attachment.failure != nil {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(Color.orange)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(width: 58, height: 58)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line.opacity(0.6), lineWidth: 0.5))
    }

    private var fileChip: some View {
        HStack(spacing: 9) {
            AttachmentIcon(kind: attachment.kind, url: attachment.url).frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Text(detail).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
            }
        }
        .padding(.leading, 9).padding(.trailing, 12)
        .frame(height: 58).frame(maxWidth: 240, alignment: .leading)
        .background(Theme.hover.opacity(0.8), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line.opacity(0.6), lineWidth: 0.5))
    }

    private var detail: String {
        switch attachment.kind {
        case .folder: return "Folder"
        case .image: return "Image"
        case .file:
            let kind = attachment.url.flatMap { UTType(filenameExtension: $0.pathExtension)?.localizedDescription } ?? "File"
            guard let bytes = attachment.byteCount else { return kind }
            return "\(kind) · \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))"
        }
    }
}

/// The system's icon for an attached file or folder.
struct AttachmentIcon: View {
    let kind: PromptAttachment.Kind
    let url: URL?

    var body: some View {
        if let url, FileManager.default.fileExists(atPath: url.path) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().interpolation(.high)
        } else {
            Image(systemName: kind == .folder ? "folder.fill" : "doc.fill").resizable().scaledToFit().padding(4).foregroundStyle(Theme.muted)
        }
    }
}

/// "Drop to attach", over whatever a drag is hovering.
struct AttachmentDropOverlay: View {
    var cornerRadius: CGFloat = 24

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(Theme.accent.opacity(0.08))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(Theme.accent.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
            .overlay {
                Label("Drop to attach", systemImage: "paperclip").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accent)
                    .padding(.horizontal, 12).padding(.vertical, 7).glassSurface(in: Capsule())
            }
            .allowsHitTesting(false)
    }
}

// MARK: - Transcript views

/// What a sent prompt carried, above its text: image previews and file chips.
struct SentAttachmentsView: View {
    let attachments: [MessageAttachment]
    @State private var previewURL: URL?

    var body: some View {
        let images = attachments.filter { $0.kind == .image }
        let files = attachments.filter { $0.kind != .image }
        VStack(alignment: .trailing, spacing: 8) {
            if !images.isEmpty {
                // A click opens the image viewer (see `TranscriptImageTile`).
                FlowRowsLayout(spacing: 8, alignment: .trailing) {
                    ForEach(images) { image in
                        TranscriptImageTile(attachment: image, size: TranscriptImageLayout.tile(image, height: images.count == 1 ? 150 : 96), cornerRadius: 14)
                    }
                }
            }
            if !files.isEmpty {
                FlowingChips(attachments: files) { open($0) }
            }
        }
        .quickLookPreview($previewURL)
    }

    private func open(_ attachment: MessageAttachment) {
        guard let path = attachment.path, FileManager.default.fileExists(atPath: path) else { return }
        if attachment.kind == .folder { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
        else { previewURL = URL(fileURLWithPath: path) }
    }
}

/// File and folder chips, wrapped onto as many lines as they need.
private struct FlowingChips: View {
    let attachments: [MessageAttachment]
    var onOpen: (MessageAttachment) -> Void

    var body: some View {
        FlowRowsLayout(spacing: 6, alignment: .trailing) {
            ForEach(attachments) { attachment in
                Button { onOpen(attachment) } label: {
                    HStack(spacing: 6) {
                        AttachmentIcon(kind: attachment.kind == .folder ? .folder : .file, url: attachment.path.map { URL(fileURLWithPath: $0) })
                            .frame(width: 16, height: 16)
                        Text(attachment.name).font(.system(size: 12.5)).lineLimit(1).truncationMode(.middle)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Theme.sidebar, in: Capsule())
                }
                .buttonStyle(.plain).help(attachment.path ?? attachment.name)
                .accessibilityLabel("\(attachment.kind == .folder ? "Folder" : "File"): \(attachment.name)")
            }
        }
    }
}

/// Lays out views in rows aligned to one edge, wrapping as needed.
struct FlowRowsLayout: Layout {
    var spacing: CGFloat
    var alignment: HorizontalEdge = .trailing

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = alignment == .trailing ? bounds.maxX - row.width : bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = rows[rows.count - 1].indices.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
            if needed > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows.filter { !$0.indices.isEmpty }
    }
}
