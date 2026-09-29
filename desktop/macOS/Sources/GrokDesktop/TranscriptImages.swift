import AppKit
import ImageIO
import SwiftUI

/// Opens the image viewer at a transcript image. The transcript provides it; a view shown
/// elsewhere (without one) opens the image's file instead.
struct OpenImageAction {
    let open: @MainActor (MessageAttachment) -> Void
    @MainActor func callAsFunction(_ attachment: MessageAttachment) { open(attachment) }
}

private struct OpenImageKey: EnvironmentKey {
    static let defaultValue: OpenImageAction? = nil
}

extension EnvironmentValues {
    var openImage: OpenImageAction? {
        get { self[OpenImageKey.self] }
        set { self[OpenImageKey.self] = newValue }
    }
}

extension OpenImageAction {
    /// Without a viewer: the image's file in the default app.
    @MainActor static func fallback(_ attachment: MessageAttachment) {
        if let url = attachment.fullImageURL { NSWorkspace.shared.open(url) }
    }
}

/// Images decoded for display at a given pixel size, read off the main thread and kept a while.
@MainActor
final class TranscriptImageCache {
    static let shared = TranscriptImageCache()
    private let images = NSCache<NSString, NSImage>()

    init() { images.totalCostLimit = 192 * 1_024 * 1_024 }

    func cached(_ url: URL, maxPixels: Int) -> NSImage? { images.object(forKey: Self.key(url, maxPixels)) }

    /// The image no larger than `maxPixels` on its longest side; 0 reads it whole.
    func load(_ url: URL, maxPixels: Int) async -> NSImage? {
        if let image = cached(url, maxPixels: maxPixels) { return image }
        let image = await Task.detached(priority: .userInitiated) { Self.decode(url, maxPixels: maxPixels) }.value
        if let image {
            let pixels = image.representations.first.map { $0.pixelsWide * $0.pixelsHigh } ?? 0
            images.setObject(image, forKey: Self.key(url, maxPixels), cost: pixels * 4)
        }
        return image
    }

    private static func key(_ url: URL, _ maxPixels: Int) -> NSString { "\(maxPixels)|\(url.absoluteString)" as NSString }

    nonisolated static func decode(_ url: URL, maxPixels: Int) -> NSImage? {
        if url.isFileURL {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else { return nil }
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
            let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
            let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
            let longest = max(width, height)
            let side = maxPixels > 0 ? min(maxPixels, max(longest, 1)) : max(longest, 1)
            guard let image = PromptAttachmentsModel.downscaled(source, maxSide: CGFloat(side)) else { return nil }
            return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        }
        guard let data = MarkdownImageCache.decodeDataURL(url) else { return nil }
        let image = NSImage(data: data)
        return image?.isValid == true ? image : nil
    }
}

/// One transcript image, filled into its frame: the thumbnail at once, then a sharper copy
/// when the frame needs more pixels than the thumbnail has. A click opens the viewer.
struct TranscriptImageTile: View {
    let attachment: MessageAttachment
    let size: CGSize
    var cornerRadius: CGFloat = 12
    /// "+3" over the last tile of a row that has more images than it shows.
    var more = 0
    @Environment(\.openImage) private var openImage
    @Environment(\.displayScale) private var displayScale
    @State private var sharp: NSImage?
    @State private var hovered = false

    var body: some View {
        Button { openImage.map { $0(attachment) } ?? OpenImageAction.fallback(attachment) } label: {
            ZStack {
                Rectangle().fill(Theme.hover)
                if let image = sharp ?? thumbnail {
                    Image(nsImage: image).resizable().interpolation(.high).scaledToFill()
                        .frame(width: size.width, height: size.height).clipped()
                } else {
                    Image(systemName: "photo").font(.system(size: 20)).foregroundStyle(Theme.muted)
                }
                if more > 0 {
                    Color.black.opacity(0.45)
                    Text("+\(more)").font(.system(size: 20, weight: .semibold)).foregroundStyle(.white)
                } else if hovered {
                    Color.black.opacity(0.12)
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 26, height: 26).background(.black.opacity(0.45), in: Circle())
                        .padding(8).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .transition(.opacity)
                }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(Theme.line.opacity(0.5), lineWidth: 0.5))
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
        }
        .buttonStyle(.plain)
        .onHover { hovering in withAnimation(.easeOut(duration: 0.12)) { hovered = hovering } }
        .help(more > 0 ? "\(more) more images" : attachment.name)
        .accessibilityLabel(more > 0 ? "\(more) more images" : "Image: \(attachment.name)")
        .accessibilityHint("Opens the image viewer")
        .task(id: attachment.id) { await sharpen() }
    }

    private var thumbnail: NSImage? { attachment.thumbnail.flatMap(NSImage.init(data:)) }

    private func sharpen() async {
        let needed = Int((max(size.width, size.height) * displayScale).rounded(.up))
        let have = thumbnail.map { Int(max($0.size.width, $0.size.height)) } ?? 0
        guard needed > have, let url = attachment.fullImageURL else { return }
        // Tiles are small: a sharper copy near the frame's own size is enough, and cached per size step.
        let step = max(256, (needed + 255) / 256 * 256)
        if let image = TranscriptImageCache.shared.cached(url, maxPixels: step) { sharp = image; return }
        sharp = await TranscriptImageCache.shared.load(url, maxPixels: step)
    }
}

/// Where a transcript image goes: its aspect ratio, known from its pixels or its thumbnail.
enum TranscriptImageLayout {
    static func aspect(_ attachment: MessageAttachment) -> CGFloat {
        if let size = attachment.pixelSize { return size.width / size.height }
        if let data = attachment.thumbnail, let image = NSImage(data: data), image.size.height > 0 { return image.size.width / image.size.height }
        return 4 / 3
    }

    /// A tile of the given height, its width following the image within 0.5–2.2 × the height.
    static func tile(_ attachment: MessageAttachment, height: CGFloat) -> CGSize {
        CGSize(width: (height * max(0.5, min(2.2, aspect(attachment)))).rounded(), height: height)
    }

    /// The image fitted within `box`, no larger than its own pixels at 2× (a Retina screen's points).
    static func fitted(_ attachment: MessageAttachment, in box: CGSize) -> CGSize {
        let aspect = max(0.05, aspect(attachment))
        var width = min(box.width, box.height * aspect)
        if let pixels = attachment.pixelSize { width = min(width, max(pixels.width / 2, 160)) }
        return CGSize(width: width.rounded(), height: (width / aspect).rounded())
    }

    /// Tiles shown before the rest fold into "+N".
    static let visibleTiles = 6
}

/// The images a tool returned or a reply carried, below it: one image large, several as a
/// row of tiles, a generated image larger still.
struct TranscriptImageGrid: View {
    let attachments: [MessageAttachment]

    var body: some View {
        let images = attachments.filter { $0.kind == .image }
        if images.count == 1, let image = images.first {
            let box = image.origin == .generated ? CGSize(width: 420, height: 420) : CGSize(width: 360, height: 180)
            TranscriptImageTile(attachment: image, size: TranscriptImageLayout.fitted(image, in: box), cornerRadius: image.origin == .generated ? 14 : 12)
        } else if !images.isEmpty {
            let shown = Array(images.prefix(TranscriptImageLayout.visibleTiles + (images.count == TranscriptImageLayout.visibleTiles + 1 ? 1 : 0)))
            let hidden = images.count - shown.count
            FlowRowsLayout(spacing: 8, alignment: .leading) {
                ForEach(shown) { image in
                    TranscriptImageTile(attachment: image, size: TranscriptImageLayout.tile(image, height: 120))
                }
                if hidden > 0, let next = images.dropFirst(shown.count).first {
                    TranscriptImageTile(attachment: next, size: TranscriptImageLayout.tile(next, height: 120), more: hidden)
                }
            }
        }
    }
}
