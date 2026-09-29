import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// One image the viewer can show.
struct ImageViewerItem: Identifiable, Equatable {
    var id: UUID
    var name: String
    /// The whole image: a file, or a `data:` or web URL from a reply.
    var url: URL?
    var thumbnail: Data?
    var pixelSize: CGSize?
    /// The image's own file, which Show in Finder reveals.
    var revealablePath: String?

    init(id: UUID = UUID(), name: String, url: URL?, thumbnail: Data? = nil, pixelSize: CGSize? = nil, revealablePath: String? = nil) {
        self.id = id; self.name = name; self.url = url; self.thumbnail = thumbnail; self.pixelSize = pixelSize; self.revealablePath = revealablePath
    }

    init(_ attachment: MessageAttachment) {
        self.init(id: attachment.id, name: attachment.name, url: attachment.fullImageURL, thumbnail: attachment.thumbnail,
                  pixelSize: attachment.pixelSize, revealablePath: attachment.revealablePath)
    }
}

/// What the viewer shows: a conversation's images in transcript order, one of them current.
struct ImageViewerRequest: Identifiable, Equatable {
    var id = UUID()
    var items: [ImageViewerItem]
    var index: Int
    /// Magnification over the fitted image: 1 fits the window.
    var zoom: CGFloat = 1
    var offset: CGSize = .zero

    static let zoomRange: ClosedRange<CGFloat> = 1...16

    var current: ImageViewerItem? { items.indices.contains(index) ? items[index] : nil }
    var canGoBack: Bool { index > 0 }
    var canGoForward: Bool { index < items.count - 1 }

    mutating func step(_ delta: Int) {
        let next = min(max(0, index + delta), items.count - 1)
        guard next != index, next >= 0 else { return }
        select(next)
    }

    mutating func select(_ next: Int) {
        guard items.indices.contains(next) else { return }
        index = next; zoom = 1; offset = .zero
    }

    mutating func setZoom(_ value: CGFloat) {
        zoom = min(max(value, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
        if zoom == 1 { offset = .zero }
    }
}

enum ImageGallery {
    /// Every image in the transcript: sent, returned by tools, generated, or carried by replies.
    static func items(in messages: [Message]) -> [ImageViewerItem] {
        messages.flatMap { ($0.attachments ?? []).filter { $0.kind == .image }.map(ImageViewerItem.init) }
    }
}

extension AppStore {
    /// Opens the viewer at a transcript image, with the task's other images a step away.
    func openImage(_ attachment: MessageAttachment) {
        let items = ImageGallery.items(in: conversation?.messages ?? [])
        if let index = items.firstIndex(where: { $0.id == attachment.id }) {
            imageViewer = ImageViewerRequest(items: items, index: index)
        } else {
            imageViewer = ImageViewerRequest(items: [ImageViewerItem(attachment)], index: 0)
        }
    }

    /// Opens the viewer at an image a reply shows inline.
    func openImage(url: URL, name: String? = nil) {
        let fallback = url.scheme == "data" ? "Image" : url.lastPathComponent
        let path = url.isFileURL && FileManager.default.fileExists(atPath: url.path) ? url.path : nil
        imageViewer = ImageViewerRequest(items: [ImageViewerItem(name: name ?? (fallback.isEmpty ? "Image" : fallback), url: url, revealablePath: path)], index: 0)
    }

    func closeImageViewer() { imageViewer = nil }
}

// MARK: - Actions

/// Copy, Save, and Open, for the image on screen.
@MainActor
enum ImageViewerActions {
    static func copy(_ image: NSImage, pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
    }

    static func save(_ item: ImageViewerItem, image: NSImage) {
        let panel = NSSavePanel()
        let ext = item.url.flatMap { $0.isFileURL ? $0.pathExtension : nil }.flatMap { $0.isEmpty ? nil : $0 } ?? "png"
        let base = (item.name as NSString).deletingPathExtension
        panel.nameFieldStringValue = "\(base.isEmpty ? "Image" : base).\(ext)"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        if let source = item.url, source.isFileURL {
            try? FileManager.default.removeItem(at: destination)
            try? FileManager.default.copyItem(at: source, to: destination)
        } else if let png = pngData(image) {
            try? png.write(to: destination, options: .atomic)
        }
    }

    /// Opens the image in Preview, writing it to a file first when it has none.
    static func openInPreview(_ item: ImageViewerItem, image: NSImage) {
        guard let file = (item.url?.isFileURL == true ? item.url : nil) ?? pngData(image).flatMap({ ImageStore.storeNow($0, mimeType: "image/png") }) else { return }
        if let preview = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") {
            NSWorkspace.shared.open([file], withApplicationAt: preview, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(file)
        }
    }

    static func pngData(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}

// MARK: - Views

/// The viewer, over the whole window: the image fitted to it on a dimmed backdrop, its
/// actions along the top, and the task's other images along the bottom.
struct ImageViewerOverlay: View {
    @Binding var request: ImageViewerRequest
    var onClose: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    @State private var loaded: [UUID: NSImage] = [:]

    var body: some View {
        ZStack {
            backdrop
            VStack(spacing: 0) {
                topBar
                ZStack {
                    if let item = request.current {
                        ImageViewerStage(item: item, image: loaded[item.id], zoom: $request.zoom, offset: $request.offset)
                            .id(item.id)
                    }
                    navigation
                }
                // A zoomed image stays between the bar and the filmstrip, so neither is hidden.
                .clipped()
                .scaleEffect(appeared || reduceMotion ? 1 : 0.97)
                if request.items.count > 1 { filmstrip }
            }
        }
        .opacity(appeared || reduceMotion ? 1 : 0)
        .environment(\.colorScheme, .dark)
        .onAppear { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { appeared = true } }
        .task(id: request.current?.id) { await load() }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityLabel("Image viewer")
    }

    private var backdrop: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            Color.black.opacity(0.66)
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture(perform: onClose)
        .accessibilityHidden(true)
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)
            actions
        }
        .overlay {
            // Centered over the whole bar; the window's own buttons sit dimmed at its left.
            VStack(spacing: 2) {
                Text(request.current?.name ?? "Image").font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).monospacedDigit()
            }
            .foregroundStyle(.white)
            .frame(maxWidth: 360)
            .allowsHitTesting(false)
        }
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 4)
        .frame(height: 60)
    }

    private var subtitle: String {
        var parts: [String] = []
        if let size = request.current?.pixelSize ?? loaded[request.current?.id ?? UUID()].flatMap(Self.pixelSize) {
            parts.append("\(Int(size.width)) × \(Int(size.height))")
        }
        if request.items.count > 1 { parts.append("\(request.index + 1) of \(request.items.count)") }
        if request.zoom != 1 { parts.append("\(Int((request.zoom * 100).rounded()))%") }
        return parts.joined(separator: "  ·  ")
    }

    private var actions: some View {
        let item = request.current
        let image = item.flatMap { loaded[$0.id] }
        return HStack(spacing: 8) {
            HStack(spacing: 2) {
                ViewerButton(icon: "doc.on.doc", help: "Copy Image (⌘C)") { if let image { ImageViewerActions.copy(image) } }
                    .disabled(image == nil)
                ViewerButton(icon: "square.and.arrow.down", help: "Save Image…") { if let item, let image { ImageViewerActions.save(item, image: image) } }
                    .disabled(image == nil)
                if let path = item?.revealablePath {
                    ViewerButton(icon: "folder", help: "Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                }
                ViewerButton(icon: "arrow.up.forward.app", help: "Open in Preview") { if let item, let image { ImageViewerActions.openInPreview(item, image: image) } }
                    .disabled(image == nil)
            }
            .padding(3)
            .glassSurface(in: Capsule())
            ViewerButton(icon: "xmark", help: "Close (Esc)", action: onClose)
                .padding(3)
                .glassSurface(in: Circle())
        }
    }

    @ViewBuilder private var navigation: some View {
        if request.items.count > 1 {
            HStack {
                ViewerChevron(icon: "chevron.left", help: "Previous Image (←)", enabled: request.canGoBack) { request.step(-1) }
                Spacer()
                ViewerChevron(icon: "chevron.right", help: "Next Image (→)", enabled: request.canGoForward) { request.step(1) }
            }
            .padding(.horizontal, 20)
        }
    }

    private var filmstrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(request.items.enumerated()), id: \.element.id) { index, item in
                        FilmstripThumbnail(item: item, selected: index == request.index) { request.select(index) }
                            .id(item.id)
                    }
                }
                .padding(6)
            }
            .frame(maxWidth: min(CGFloat(request.items.count) * 50 + 12, 640))
            .fixedSize(horizontal: false, vertical: true)
            .glassSurface(cornerRadius: 14)
            .padding(.bottom, 18).padding(.top, 8)
            .onChange(of: request.index, initial: true) { _, _ in
                guard let id = request.current?.id else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    private func load() async {
        guard let item = request.current, loaded[item.id] == nil, let url = item.url else { return }
        let image: NSImage?
        if url.isFileURL || url.scheme == "data" {
            image = await TranscriptImageCache.shared.load(url, maxPixels: 0)
        } else {
            image = MarkdownImageCache.shared.image(for: url)
        }
        // Only the image on screen is held here; stepping back finds the others in the cache.
        if let image { loaded = [item.id: image] }
    }

    static func pixelSize(_ image: NSImage) -> CGSize? {
        guard let rep = image.representations.first, rep.pixelsWide > 0, rep.pixelsHigh > 0 else { return image.size.width > 0 ? image.size : nil }
        return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
    }
}

/// The image, fitted within the stage and zoomed and panned over it.
private struct ImageViewerStage: View {
    let item: ImageViewerItem
    let image: NSImage?
    @Binding var zoom: CGFloat
    @Binding var offset: CGSize
    @State private var pinchStart: CGFloat?
    @State private var dragStart: CGSize?
    private static let margin: CGFloat = 48

    var body: some View {
        GeometryReader { geometry in
            let available = CGSize(width: max(1, geometry.size.width - Self.margin * 2), height: max(1, geometry.size.height - Self.margin * 2))
            let natural = naturalSize
            let fit = min(1, available.width / natural.width, available.height / natural.height)
            let shown = CGSize(width: natural.width * fit * zoom, height: natural.height * fit * zoom)
            picture
                .frame(width: shown.width, height: shown.height)
                .clipShape(RoundedRectangle(cornerRadius: zoom > 1 ? 4 : 12))
                .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
                .offset(clamped(offset, shown: shown, in: geometry.size))
                .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                .onTapGesture(count: 2) { toggleActualSize(fit: fit) }
                .gesture(magnify)
                .simultaneousGesture(pan(shown: shown, in: geometry.size))
                .accessibilityLabel("Image: \(item.name)")
                .accessibilityHint("Double-click to zoom")
        }
    }

    @ViewBuilder private var picture: some View {
        if let image {
            Image(nsImage: image).resizable().interpolation(zoom > 1.5 ? .none : .high)
        } else if let data = item.thumbnail, let thumbnail = NSImage(data: data) {
            Image(nsImage: thumbnail).resizable().interpolation(.high).overlay { ProgressView().controlSize(.small) }
        } else {
            Rectangle().fill(.white.opacity(0.06)).overlay { ProgressView().controlSize(.small) }
        }
    }

    /// The image's size at one image pixel per point; a guess until it is known.
    private var naturalSize: CGSize {
        if let size = item.pixelSize { return size }
        if let image, let size = ImageViewerOverlay.pixelSize(image) { return size }
        if let data = item.thumbnail, let image = NSImage(data: data), image.size.width > 0 { return CGSize(width: image.size.width * 4, height: image.size.height * 4) }
        return CGSize(width: 1_200, height: 900)
    }

    /// Fitted ↔ one image pixel per point; a small image that already shows whole doubles.
    private func toggleActualSize(fit: CGFloat) {
        withAnimation(.easeOut(duration: 0.2)) {
            if zoom != 1 { zoom = 1; offset = .zero } else { zoom = fit < 1 ? min(1 / fit, ImageViewerRequest.zoomRange.upperBound) : 2 }
        }
    }

    private var magnify: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let start = pinchStart ?? zoom
                pinchStart = start
                zoom = min(max(start * value.magnification, ImageViewerRequest.zoomRange.lowerBound), ImageViewerRequest.zoomRange.upperBound)
            }
            .onEnded { _ in
                pinchStart = nil
                if zoom == 1 { withAnimation(.easeOut(duration: 0.15)) { offset = .zero } }
            }
    }

    private func pan(shown: CGSize, in stage: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                guard zoom > 1 else { return }
                let start = dragStart ?? offset
                dragStart = start
                offset = clamped(CGSize(width: start.width + value.translation.width, height: start.height + value.translation.height), shown: shown, in: stage)
            }
            .onEnded { _ in dragStart = nil }
    }

    /// An offset that keeps a zoomed image covering the stage, and a fitted one centered.
    private func clamped(_ offset: CGSize, shown: CGSize, in stage: CGSize) -> CGSize {
        let x = max(0, (shown.width - stage.width) / 2 + Self.margin)
        let y = max(0, (shown.height - stage.height) / 2 + Self.margin)
        return CGSize(width: min(max(offset.width, -x), x), height: min(max(offset.height, -y), y))
    }
}

private struct ViewerButton: View {
    var icon: String
    var help: String
    var action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 13, weight: .medium))
                .frame(width: 30, height: 30)
                .background(hovered && isEnabled ? Color.white.opacity(0.14) : .clear, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(isEnabled ? 0.92 : 0.35))
        .help(help).accessibilityLabel(help)
        .onHover { hovered = $0 }
    }
}

private struct ViewerChevron: View {
    var icon: String
    var help: String
    var enabled: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 40, height: 40).contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassSurface(in: Circle())
        .opacity(enabled ? 1 : 0)
        .disabled(!enabled)
        .help(help).accessibilityLabel(help)
        .accessibilityHidden(!enabled)
    }
}

private struct FilmstripThumbnail: View {
    let item: ImageViewerItem
    let selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Rectangle().fill(.white.opacity(0.08))
                if let data = item.thumbnail, let image = NSImage(data: data) {
                    Image(nsImage: image).resizable().interpolation(.high).scaledToFill().frame(width: 44, height: 44).clipped()
                } else {
                    Image(systemName: "photo").font(.system(size: 13)).foregroundStyle(.white.opacity(0.5))
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Theme.accent : .white.opacity(0.12), lineWidth: selected ? 2 : 0.5))
            .opacity(selected ? 1 : 0.62)
        }
        .buttonStyle(.plain)
        .help(item.name).accessibilityLabel("Image: \(item.name)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The viewer's content in its panel, following the store.
private struct ImageViewerRoot: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        if store.imageViewer != nil {
            ImageViewerOverlay(request: Binding(get: { store.imageViewer ?? ImageViewerRequest(items: [], index: 0) },
                                                set: { if store.imageViewer != nil { store.imageViewer = $0 } }),
                               onClose: { store.closeImageViewer() })
        }
    }
}

// MARK: - Presentation

/// Shows the viewer in a borderless panel over the main window, so it covers the toolbar and
/// sidebar too, and follows the window as it moves, resizes, or enters full screen.
@MainActor
final class ImageViewerPresenter {
    static let shared = ImageViewerPresenter()
    private var panel: NSPanel?
    private weak var parent: NSWindow?
    private var observers: [NSObjectProtocol] = []
    private var keyMonitor: Any?
    private weak var store: AppStore?

    func sync(_ store: AppStore, window: NSWindow?) {
        if store.imageViewer == nil { dismiss(); return }
        guard panel == nil, let window = window ?? NSApp.keyWindow ?? NSApp.mainWindow else { return }
        present(store, over: window)
    }

    private func present(_ store: AppStore, over window: NSWindow) {
        self.store = store
        parent = window
        let panel = ViewerPanel(contentRect: window.frame, styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        let host = NSHostingView(rootView: ImageViewerRoot().desktopEnvironment(store))
        host.wantsLayer = true
        host.layer?.cornerRadius = Self.cornerRadius(of: window)
        host.layer?.masksToBounds = true
        panel.contentView = host
        window.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
        let center = NotificationCenter.default
        for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification, NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.follow() }
            })
        }
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.store?.closeImageViewer(); self?.dismiss() }
        })
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self.map { event.window === $0.panel && $0.handle(event) } ?? false }
            return consumed ? nil : event
        }
    }

    private func follow() {
        guard let panel, let parent else { return }
        panel.setFrame(parent.frame, display: true)
        (panel.contentView)?.layer?.cornerRadius = Self.cornerRadius(of: parent)
    }

    func dismiss() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        guard let panel else { return }
        self.panel = nil
        parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        parent?.makeKeyAndOrderFront(nil)
    }

    /// Esc/⌘W close, arrows step, ⌘= ⌘- ⌘0 zoom, ⌘C copies.
    private func handle(_ event: NSEvent) -> Bool {
        guard let store, var request = store.imageViewer else { return false }
        let command = event.modifierFlags.contains(.command)
        switch (event.keyCode, command, event.charactersIgnoringModifiers ?? "") {
        case (53, _, _), (_, true, "w"):
            store.closeImageViewer()
        case (123, false, _):
            request.step(-1); store.imageViewer = request
        case (124, false, _):
            request.step(1); store.imageViewer = request
        case (_, true, "="), (_, true, "+"):
            request.setZoom(request.zoom * 1.25); store.imageViewer = request
        case (_, true, "-"):
            request.setZoom(request.zoom / 1.25); store.imageViewer = request
        case (_, true, "0"):
            request.setZoom(1); store.imageViewer = request
        case (_, true, "c"):
            guard let url = request.current?.url else { return true }
            Task { if let image = await TranscriptImageCache.shared.load(url, maxPixels: 0) { ImageViewerActions.copy(image) } }
        default:
            return false
        }
        return true
    }

    /// The main window's corner radius, so the dimmed backdrop does not show past its corners.
    private static func cornerRadius(of window: NSWindow) -> CGFloat {
        if window.styleMask.contains(.fullScreen) { return 0 }
        let selector = NSSelectorFromString("_cornerRadius")
        if window.responds(to: selector), let radius = window.value(forKey: "_cornerRadius") as? CGFloat, radius > 0 { return radius }
        if #available(macOS 26.0, *) { return 16 }
        return 10
    }

    private final class ViewerPanel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }
}

/// The window this view is in, for presenting over it.
struct HostWindowReader: NSViewRepresentable {
    var onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) { view.onWindow = onWindow }

    final class ReaderView: NSView {
        var onWindow: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindow?(window)
        }
    }
}
