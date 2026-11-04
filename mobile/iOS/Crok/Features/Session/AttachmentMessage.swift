import Photos
import QuickLook
import SwiftUI
import UIKit

/// A message's images in its bubble (Telegram's media bubble): one shown whole, several as a grid of square tiles.
struct MediaGrid: View {
    let images: [MessageAttachment]
    let onTap: (MessageAttachment) -> Void

    static let cornerRadius: CGFloat = 15

    /// How wide the grid is, for the bubble around it.
    static func width(for images: [MessageAttachment]) -> CGFloat {
        guard images.count == 1, let image = images.first else { return MediaLayout.maxWidth }
        return MediaLayout.singleSize(width: image.width, height: image.height).width
    }

    var body: some View {
        Group {
            if images.count == 1, let image = images.first {
                tile(image, size: MediaLayout.singleSize(width: image.width, height: image.height))
            } else {
                let tiles = MediaLayout.grid(count: images.count)
                ZStack(alignment: .topLeading) {
                    ForEach(tiles, id: \.index) { tile in
                        self.tile(images[tile.index], size: tile.frame.size)
                            .offset(x: tile.frame.minX, y: tile.frame.minY)
                    }
                }
                .frame(width: MediaLayout.maxWidth, height: MediaLayout.gridHeight(count: images.count), alignment: .topLeading)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
    }

    /// One image filling its tile, cropped to it.
    private func tile(_ image: MessageAttachment, size: CGSize) -> some View {
        AttachmentImageView(attachment: image, maxPixel: images.count == 1 ? 900 : 480)
            .frame(width: size.width, height: size.height)
            .clipped()
            .contentShape(Rectangle())
            .onTapGesture { onTap(image) }
            .accessibilityElement()
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(Text("Photo"))
            .accessibilityValue(Text(verbatim: image.name))
            .accessibilityIdentifier("messageImage-\(image.name)")
    }
}

/// A file in a bubble: a round icon, the name and "1.2 MB · PDF"; a spinner while it downloads. One that is only on
/// the computer, or no longer on the relay, is dimmed and says so.
struct MessageFileRow: View {
    let attachment: MessageAttachment
    let computerName: String
    let textColor: Color
    let metaColor: Color
    @State private var opener = FileOpener.shared

    private var subtitle: String {
        if attachment.isAvailable { return AttachmentText.detail(name: attachment.name, size: attachment.size) }
        if attachment.isOnComputerOnly { return String(localized: "On \(computerName)") }
        return String(localized: "No longer available")
    }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                if opener.isDownloading(attachment) {
                    Circle().fill(Theme.accent).frame(width: 40, height: 40)
                    ProgressView().tint(.white)
                } else {
                    FileGlyph(kind: attachment.kind, dimmed: !attachment.isAvailable)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: attachment.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(textColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(verbatim: subtitle)
                    .font(.caption)
                    .foregroundStyle(metaColor)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .frame(minWidth: 180, maxWidth: 250, alignment: .leading)
        .opacity(attachment.isAvailable ? 1 : 0.6)
        .contentShape(Rectangle())
        .onTapGesture { if attachment.isAvailable { opener.open(attachment) } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(attachment.isAvailable ? .isButton : [])
        .accessibilityIdentifier("messageFile-\(attachment.name)")
    }
}

// MARK: - The viewer

/// The images of one message, opened at `index`.
struct MediaViewerItem: Identifiable, Equatable {
    let id = UUID()
    var images: [MessageAttachment]
    var index: Int
}

/// The full-screen viewer on black (Telegram's gallery): swipe between the message's images, pinch or double-tap to
/// zoom, swipe down or ✕ to close; Share and Save to Photos.
struct MediaViewer: View {
    let item: MediaViewerItem
    @Environment(\.dismiss) private var dismiss
    @State private var index: Int
    @State private var dragOffset: CGFloat = 0
    @State private var zoomed = false
    @State private var toast: String?
    @State private var working = false

    init(item: MediaViewerItem) {
        self.item = item
        _index = State(initialValue: item.index)
    }

    private var current: MessageAttachment? { item.images.indices.contains(index) ? item.images[index] : nil }
    private var chromeOpacity: Double { 1 - min(1, abs(dragOffset) / 150) }

    var body: some View {
        ZStack {
            Color.black
                .opacity(1 - min(0.7, abs(dragOffset) / 500))
                .ignoresSafeArea()
            TabView(selection: $index) {
                ForEach(Array(item.images.enumerated()), id: \.element.id) { offset, image in
                    ZoomableImage(attachment: image, zoomed: $zoomed)
                        .tag(offset)
                        .ignoresSafeArea()
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()
            .offset(y: dragOffset)
            .simultaneousGesture(
                DragGesture(minimumDistance: 16)
                    .onChanged { value in
                        guard !zoomed, abs(value.translation.height) > abs(value.translation.width) else { return }
                        dragOffset = value.translation.height
                    }
                    .onEnded { _ in
                        if abs(dragOffset) > 110 {
                            dismiss()
                        } else {
                            withAnimation(.snappy) { dragOffset = 0 }
                        }
                    })
            VStack(spacing: 0) {
                topBar
                Spacer()
                bottomBar
            }
            .opacity(chromeOpacity)
            if let toast {
                Text(verbatim: toast)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.white.opacity(0.18), in: Capsule())
                    .transition(.opacity)
                    .accessibilityIdentifier("viewerToast")
            }
        }
        .statusBarHidden()
        .preferredColorScheme(.dark)
        .animation(.snappy, value: toast)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mediaViewer")
    }

    private var topBar: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Color.white.opacity(0.14), in: Circle())
            }
            .accessibilityLabel(Text("Close"))
            .accessibilityIdentifier("mediaViewerClose")
            Spacer()
            if item.images.count > 1 {
                Text("\(index + 1) of \(item.images.count)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                    .accessibilityIdentifier("mediaViewerCounter")
            }
            Spacer()
            Color.clear.frame(width: 40, height: 40)
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .background(
            LinearGradient(colors: [Color.black.opacity(0.7), .clear], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea())
    }

    private var bottomBar: some View {
        HStack(spacing: 28) {
            Button {
                Task { await share() }
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .accessibilityIdentifier("mediaViewerShare")
            Button {
                Task { await save() }
            } label: {
                Label("Save to Photos", systemImage: "square.and.arrow.down")
            }
            .accessibilityIdentifier("mediaViewerSave")
        }
        .labelStyle(.titleAndIcon)
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.white)
        .disabled(working)
        .padding(.bottom, 12)
        .padding(.top, 24)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(colors: [.clear, Color.black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea())
    }

    /// The current image's bytes: on the phone already, or downloaded now.
    private func currentData() async -> Data? {
        guard let image = current, let storageId = image.storageId else { return nil }
        return await AttachmentStore.shared.data(key: storageId, url: image.url)
    }

    private func share() async {
        guard let image = current, let storageId = image.storageId else { return }
        working = true
        defer { working = false }
        guard await currentData() != nil, let file = AttachmentStore.shared.namedCopy(key: storageId, name: image.name) else {
            show(String(localized: "No longer available"))
            return
        }
        Presenter.share([file])
    }

    private func save() async {
        working = true
        defer { working = false }
        guard let data = await currentData() else {
            show(String(localized: "No longer available"))
            return
        }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            show(String(localized: "Couldn't save"))
            return
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
            }
            show(String(localized: "Saved"))
        } catch {
            show(String(localized: "Couldn't save"))
        }
    }

    private func show(_ text: String) {
        toast = text
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            if toast == text { toast = nil }
        }
    }
}

/// One image of the viewer, zoomable: its thumbnail first, then the full image.
private struct ZoomableImage: View {
    let attachment: MessageAttachment
    @Binding var zoomed: Bool
    @State private var image: UIImage?

    var body: some View {
        ZoomingImage(image: image, zoomed: $zoomed)
            .overlay {
                if image == nil { ProgressView().tint(.white) }
            }
            .task(id: attachment.id) {
                let store = AttachmentStore.shared
                if let thumbId = attachment.thumbId,
                    let thumb = await store.image(key: thumbId, url: attachment.thumbURL, maxPixel: 900)
                {
                    image = thumb
                }
                guard let storageId = attachment.storageId else { return }
                if let full = await store.image(key: storageId, url: attachment.url, maxPixel: AttachmentImageView.fullPixel) {
                    image = full
                }
            }
            .accessibilityElement()
            .accessibilityLabel(Text("Photo"))
            .accessibilityValue(Text(verbatim: attachment.name))
            .accessibilityIdentifier("viewerImage-\(attachment.name)")
    }
}

/// A scroll view that zooms its image (pinch, double tap) and keeps it centred and fitted.
private struct ZoomingImage: UIViewRepresentable {
    let image: UIImage?
    @Binding var zoomed: Bool

    func makeUIView(context: Context) -> ZoomingScrollView {
        let view = ZoomingScrollView()
        view.onZoom = { zoomed = $0 }
        return view
    }

    func updateUIView(_ view: ZoomingScrollView, context: Context) {
        view.onZoom = { zoomed = $0 }
        view.show(image)
    }
}

final class ZoomingScrollView: UIScrollView, UIScrollViewDelegate {
    private let imageView = UIImageView()
    private var laidOutSize: CGSize = .zero
    var onZoom: ((Bool) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 4
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        backgroundColor = .clear
        imageView.contentMode = .scaleAspectFit
        addSubview(imageView)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ image: UIImage?) {
        guard imageView.image !== image else { return }
        let sameShape = imageView.image.map { old in image.map { abs(old.size.width / old.size.height - $0.size.width / $0.size.height) < 0.01 } ?? false } ?? false
        imageView.image = image
        // The full image replacing its thumbnail keeps the zoom; anything else starts fitted.
        if !sameShape || zoomScale <= 1.01 {
            zoomScale = 1
            fit()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != laidOutSize {
            laidOutSize = bounds.size
            zoomScale = 1
            fit()
        }
        center()
    }

    private func fit() {
        guard let image = imageView.image, image.size.width > 0, image.size.height > 0, bounds.width > 0 else { return }
        let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        imageView.frame = CGRect(origin: .zero, size: size)
        contentSize = size
        center()
    }

    private func center() {
        let x = max(0, (bounds.width - contentSize.width) / 2)
        let y = max(0, (bounds.height - contentSize.height) / 2)
        contentInset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        center()
        onZoom?(zoomScale > 1.01)
    }

    @objc private func doubleTapped(_ gesture: UITapGestureRecognizer) {
        if zoomScale > 1.01 {
            setZoomScale(1, animated: true)
            return
        }
        let point = gesture.location(in: imageView)
        let scale: CGFloat = 2.5
        let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
        zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
    }
}

// MARK: - Files

/// Opens a file from a bubble: downloads it into the attachment store (a spinner on its row meanwhile), then shows it
/// in Quick Look, which shares it too.
@MainActor
@Observable
final class FileOpener {
    static let shared = FileOpener()

    private(set) var downloading: Set<String> = []
    /// The last file that could not be fetched (the relay no longer has it, or the network failed).
    var failure: String?

    func isDownloading(_ attachment: MessageAttachment) -> Bool {
        attachment.storageId.map(downloading.contains) ?? false
    }

    func open(_ attachment: MessageAttachment) {
        guard let storageId = attachment.storageId, !downloading.contains(storageId) else { return }
        downloading.insert(storageId)
        Task {
            let data = await AttachmentStore.shared.data(key: storageId, url: attachment.url)
            downloading.remove(storageId)
            guard data != nil, let file = AttachmentStore.shared.namedCopy(key: storageId, name: attachment.name) else {
                failure = String(localized: "No longer available")
                return
            }
            Presenter.quickLook(file)
        }
    }
}

/// UIKit sheets SwiftUI has no equivalent for here: Quick Look and the share sheet, from the top view controller.
@MainActor
enum Presenter {
    private static var quickLookSource: QuickLookSource?

    static func top() -> UIViewController? {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
        var controller = window?.rootViewController
        while let presented = controller?.presentedViewController, !presented.isBeingDismissed {
            controller = presented
        }
        return controller
    }

    static func quickLook(_ file: URL) {
        let source = QuickLookSource(file: file)
        quickLookSource = source
        let controller = QLPreviewController()
        controller.dataSource = source
        top()?.present(controller, animated: true)
    }

    static func share(_ items: [Any]) {
        guard let top = top() else { return }
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        if let popover = controller.popoverPresentationController {
            popover.sourceView = top.view
            popover.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.maxY - 60, width: 1, height: 1)
        }
        top.present(controller, animated: true)
    }
}

private final class QuickLookSource: NSObject, QLPreviewControllerDataSource {
    let file: URL

    init(file: URL) {
        self.file = file
    }

    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem {
        file as NSURL
    }
}
