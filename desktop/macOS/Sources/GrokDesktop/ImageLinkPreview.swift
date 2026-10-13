import AppKit
import ImageIO
import SwiftUI

/// Image files a reply names: a path in a code span (`` `/tmp/qr/auth.png` ``) or in its prose, and
/// links to one. Each is a link to the file; resting the pointer on it previews the image, and a click
/// opens the file in Preview (see `ImageLinkPreview`).
enum ImageFileLink {
    /// Raster formats that ImageIO reads and Preview opens.
    static let extensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp", "avif"]

    static func isImage(_ url: URL) -> Bool { url.isFileURL && extensions.contains(url.pathExtension.lowercased()) }

    /// The image file an absolute, home-relative, or `file:` path names. Whether it exists is found
    /// out on hover or click, never while a reply renders.
    static func url(forPath text: String) -> URL? {
        let path = text.trimmingCharacters(in: .whitespaces)
        guard path.hasPrefix("/") || path.hasPrefix("~/") || path.hasPrefix("file://"), !path.contains("\n"),
              let url = MarkdownInlineBuilder.url(path), isImage(url) else { return nil }
        return url
    }

    /// A path in prose, as in "saved to /tmp/qr/auth.png.": it starts a word (not with `//`, as the rest
    /// of a URL does), runs to the next space, and ends in an image extension, without a sentence's
    /// closing full stop. A path with spaces is found only in a code span.
    private static let barePath = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9_.~/\\-])~?/(?!/)[^\s`"'<>|]*?\.(?:png|jpe?g|gif|webp|heic|heif|tiff?|bmp|avif)(?!\.?[A-Za-z0-9_/\\-])"#,
        options: [.caseInsensitive])

    /// The image file paths written in prose, by UTF-16 range.
    static func paths(in text: String) -> [(range: NSRange, url: URL)] {
        guard text.utf8.contains(UInt8(ascii: "/")) else { return [] }
        let string = text as NSString
        return barePath.matches(in: text, range: NSRange(location: 0, length: string.length)).compactMap { match in
            url(forPath: string.substring(with: match.range)).map { (match.range, $0) }
        }
    }

    /// What a click on a link to an image file, or on its preview, does with the file.
    @MainActor static var open: (URL) -> Void = openInPreview

    /// Opens the file in Preview, or in the default app on a Mac without it.
    @MainActor static func openInPreview(_ file: URL) {
        if let preview = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") {
            NSWorkspace.shared.open([file], withApplicationAt: preview, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(file)
        }
    }
}

/// The image behind a link to an image file, in a popover by the link while the pointer rests on the
/// link or on the popover. Clicking the image opens the file in Preview. One shows at a time.
@MainActor
final class ImageLinkPreview {
    static let shared = ImageLinkPreview()

    /// How long the pointer rests on a link before the image shows.
    static let dwell: Duration = .milliseconds(300)
    /// How long the image stays after the pointer leaves the link: time to reach the popover.
    static let grace: Duration = .milliseconds(250)
    /// Enough pixels for the popover on a Retina screen. The file is read again for every preview, so
    /// one written again since (a new sign-in QR code at the same path) shows as it is now.
    static let maxPixels = 640
    /// The image fits within this, at no more than one image pixel per point.
    static let box = CGSize(width: 280, height: 240)

    struct PreviewImage {
        var image: NSImage
        /// The file's own size.
        var pixelSize: CGSize
    }

    private var url: URL?
    private var rect = NSRect.zero
    private weak var anchor: NSView?
    private var popover: NSPopover?
    private var showing: Task<Void, Never>?
    private var hiding: Task<Void, Never>?
    private var pointerInPopover = false

    private init() {
        // A pointer resting on a link is not followed out of the app.
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ImageLinkPreview.shared.hide() }
        }
    }

    var isShown: Bool { popover?.isShown == true }

    /// The pointer moved within `view`: onto the image link `link`, laid out in `link.rect` of the
    /// view, or off every image link.
    func pointerMoved(onto link: (url: URL, rect: NSRect)?, in view: NSView) {
        guard let link else { return pointerLeft(view) }
        hiding?.cancel(); hiding = nil
        if anchor === view, url == link.url, rect == link.rect { return }
        hide()
        url = link.url; rect = link.rect; anchor = view
        showing = Task { [weak self] in
            try? await Task.sleep(for: Self.dwell)
            guard !Task.isCancelled else { return }
            let file = link.url, maxPixels = Self.maxPixels
            let image = await Task.detached(priority: .userInitiated) { Self.read(file, maxPixels: maxPixels) }.value
            guard !Task.isCancelled else { return }
            self?.present(image)
        }
    }

    /// The pointer left `view`, or its image links.
    func pointerLeft(_ view: NSView) {
        guard anchor === view else { return }
        if popover == nil { hide() } else { scheduleHide() }
    }

    /// Closes the preview at once: all of it, or only one anchored in `view`.
    func hide(anchoredTo view: NSView? = nil) {
        if let view, anchor !== view { return }
        showing?.cancel(); showing = nil
        hiding?.cancel(); hiding = nil
        popover?.close(); popover = nil
        url = nil; anchor = nil; pointerInPopover = false
    }

    private func scheduleHide() {
        guard hiding == nil, !pointerInPopover else { return }
        hiding = Task { [weak self] in
            try? await Task.sleep(for: Self.grace)
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    private func popoverHovered(_ inside: Bool) {
        pointerInPopover = inside
        if inside { hiding?.cancel(); hiding = nil } else { scheduleHide() }
    }

    private func present(_ image: PreviewImage?) {
        guard let url, let anchor, anchor.window != nil else { return hide() }
        let content = ImageLinkPreviewView(url: url, image: image,
                                           open: { [weak self] in self?.hide(); ImageFileLink.open(url) },
                                           hover: { [weak self] inside in self?.popoverHovered(inside) })
        let controller = NSHostingController(rootView: content)
        controller.sizingOptions = .preferredContentSize
        let popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.contentViewController = controller
        self.popover = popover
        // Above the link (the text view is flipped), or below it when there is no room.
        popover.show(relativeTo: rect, of: anchor, preferredEdge: .minY)
    }

    /// The image no larger than `maxPixels` on its longest side, and the file's own size; nil when
    /// the file is missing or is not an image.
    nonisolated static func read(_ url: URL, maxPixels: Int) -> PreviewImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0,
              let thumbnail = PromptAttachmentsModel.downscaled(source, maxSide: CGFloat(maxPixels)) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        var size = CGSize(width: (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? Double(thumbnail.width),
                          height: (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? Double(thumbnail.height))
        // Orientations 5–8 stand the image on its side; the thumbnail is already turned upright.
        if ((properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1) >= 5 { size = CGSize(width: size.height, height: size.width) }
        return PreviewImage(image: NSImage(cgImage: thumbnail, size: NSSize(width: thumbnail.width, height: thumbnail.height)), pixelSize: size)
    }

    /// The image's size in the popover.
    static func displaySize(for pixels: CGSize) -> CGSize {
        guard pixels.width > 0, pixels.height > 0 else { return CGSize(width: box.height, height: box.height) }
        let scale = min(1, box.width / pixels.width, box.height / pixels.height)
        return CGSize(width: max(1, (pixels.width * scale).rounded()), height: max(1, (pixels.height * scale).rounded()))
    }
}

/// The popover's content: the image with its name and size, or why there is none.
struct ImageLinkPreviewView: View {
    let url: URL
    let image: ImageLinkPreview.PreviewImage?
    var open: () -> Void = {}
    var hover: (Bool) -> Void = { _ in }
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Group {
            if let image {
                let size = ImageLinkPreview.displaySize(for: image.pixelSize)
                VStack(alignment: .leading, spacing: 6) {
                    Button(action: open) {
                        Image(nsImage: image.image).resizable()
                            // Enlarged pixels stay sharp, so a QR code still scans.
                            .interpolation(image.image.size.width < size.width * displayScale ? .none : .high)
                            .frame(width: size.width, height: size.height)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .help(L10n.t("open_in_preview", "Open in Preview"))
                    .accessibilityLabel(L10n.t("open_in_preview", "Open in Preview"))
                    Text(verbatim: "\(url.lastPathComponent) · \(Int(image.pixelSize.width)) × \(Int(image.pixelSize.height))")
                        .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                        .lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: max(size.width, 200), alignment: .leading)
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Label(L10n.t("image_preview_missing", "No image at this path"), systemImage: "photo.badge.exclamationmark")
                        .font(.system(size: 12, weight: .medium))
                    Text(verbatim: url.path).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                        .lineLimit(2).truncationMode(.middle)
                }
                .frame(maxWidth: ImageLinkPreview.box.width, alignment: .leading)
            }
        }
        .padding(8)
        .onHover(perform: hover)
    }
}
