import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The paperclip after the Menu pill (Telegram's attach button): Photos (the system picker, several at once), Camera
/// (where there is one) and Files (any type, several at once). Demo mode (and `-CrokSampleAttachments YES`, for UI
/// tests against a real relay) adds sample photos: UI tests cannot drive the system pickers.
struct AttachButton: View {
    let draft: AttachmentDraft
    var enabled = true
    @Environment(CrokEngine.self) private var engine
    @State private var showsPhotos = false
    @State private var showsFiles = false
    @State private var showsCamera = false
    @State private var picked: [PhotosPickerItem] = []

    private var hasCamera: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    var body: some View {
        Menu {
            Button {
                if draft.remaining > 0 { showsPhotos = true } else { draft.notice = .tooMany }
            } label: {
                Label("Photos", systemImage: "photo.on.rectangle")
            }
            .accessibilityIdentifier("attachPhotos")
            if hasCamera {
                Button {
                    if draft.remaining > 0 { showsCamera = true } else { draft.notice = .tooMany }
                } label: {
                    Label("Camera", systemImage: "camera")
                }
                .accessibilityIdentifier("attachCamera")
            }
            Button {
                if draft.remaining > 0 { showsFiles = true } else { draft.notice = .tooMany }
            } label: {
                Label("Files", systemImage: "folder")
            }
            .accessibilityIdentifier("attachFiles")
            if engine.isDemo || UserDefaults.standard.bool(forKey: "CrokSampleAttachments") {
                Button {
                    draft.add(DemoMedia.photos(count: 2, at: Date()).map { .photo($0.data, name: $0.name) })
                } label: {
                    Label { Text(verbatim: "Sample Photos") } icon: { Image(systemName: "sparkles") }
                }
                .accessibilityIdentifier("attachSamples")
            }
        } label: {
            Image(systemName: "paperclip")
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(enabled ? Color.secondary : Color.secondary.opacity(0.4))
                .frame(width: 38, height: 38)
                .contentShape(Rectangle())
                .modifier(AttachGlass())
        }
        // Photos, Camera, Files from the top, as listed (a menu opening upwards would reverse them).
        .menuOrder(.fixed)
        .disabled(!enabled)
        .accessibilityLabel(Text("Attach"))
        .accessibilityIdentifier("attachButton")
        .photosPicker(
            isPresented: $showsPhotos, selection: $picked, maxSelectionCount: max(1, draft.remaining), matching: .images,
            preferredItemEncoding: .current)
        .onChange(of: picked) { _, items in
            guard !items.isEmpty else { return }
            picked = []
            Task { await addPhotos(items) }
        }
        .fileImporter(isPresented: $showsFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { addFiles(urls) }
        }
        .fullScreenCover(isPresented: $showsCamera) {
            CameraPicker { image in
                guard let data = image.jpegData(compressionQuality: 0.95) else { return }
                draft.add([.photo(data, name: AttachmentText.photoName(at: Date()))])
            }
            .ignoresSafeArea()
        }
    }

    private func addPhotos(_ items: [PhotosPickerItem]) async {
        let now = Date()
        var sources: [AttachmentSource] = []
        for (index, item) in items.enumerated() {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            sources.append(.photo(data, name: AttachmentText.photoName(at: now, index: index + 1)))
        }
        draft.add(sources)
    }

    /// Reads each picked file (inside its security scope). Anything but an image over 20 MB is left out unread.
    private func addFiles(_ urls: [URL]) {
        var sources: [AttachmentSource] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey])
            let type = values?.contentType ?? UTType(filenameExtension: url.pathExtension)
            let isImage = type?.conforms(to: .image) == true
            let size = values?.fileSize ?? 0
            if size > (isImage ? 5 * AttachmentLimits.maxFileBytes : AttachmentLimits.maxFileBytes) {
                draft.notice = .tooBig
                continue
            }
            guard let data = try? Data(contentsOf: url) else { continue }
            let name = url.lastPathComponent
            sources.append(.file(data, name: name, mimeType: AttachmentText.mimeType(forName: name, type: type)))
        }
        draft.add(sources)
    }

    private struct AttachGlass: ViewModifier {
        func body(content: Content) -> some View {
            if hasLiquidGlass {
                content.glassSurface(in: Circle(), interactive: true)
            } else {
                content
            }
        }
    }
}

/// The system camera, for one photo.
struct CameraPicker: UIViewControllerRepresentable {
    let onPicked: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker

        init(_ parent: CameraPicker) {
            self.parent = parent
        }

        func imagePickerController(
            _ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage { parent.onPicked(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

/// What is attached, above the field: image thumbnails and file chips, each with ✕ and its upload's progress (a red
/// "!" that retries on tap when it failed), scrolling sideways; and a short notice when something was left out.
struct AttachmentStrip: View {
    let draft: AttachmentDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let notice = draft.notice {
                Text(notice.text)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Theme.danger)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Theme.card, in: Capsule())
                    .accessibilityIdentifier("attachmentNotice")
                    .task(id: notice) {
                        try? await Task.sleep(for: .seconds(3))
                        if draft.notice == notice { withAnimation(.snappy) { draft.notice = nil } }
                    }
            }
            if !draft.items.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(draft.items) { item in
                            AttachmentChip(item: item, onRemove: { withAnimation(.snappy) { draft.remove(item.id) } },
                                           onRetry: { draft.retry(item.id) })
                        }
                    }
                    .padding(.horizontal, 2)
                    .padding(.top, 6)
                }
                .scrollClipDisabled()
                .accessibilityIdentifier("attachmentStrip")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.snappy, value: draft.items.map(\.id))
        .animation(.snappy, value: draft.notice)
    }
}

private struct AttachmentChip: View {
    let item: AttachmentDraft.Item
    let onRemove: () -> Void
    let onRetry: () -> Void

    private static let side: CGFloat = 64

    var body: some View {
        content
            .overlay { status }
            .overlay(alignment: .topTrailing) {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(Color.black.opacity(0.6), in: Circle())
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.8), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .offset(x: 6, y: -6)
                .accessibilityLabel(Text("Remove"))
                .accessibilityIdentifier("removeAttachment-\(item.name)")
            }
            .contentShape(Rectangle())
            .onTapGesture { if case .failed = item.state { onRetry() } }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text(verbatim: item.name))
            .accessibilityIdentifier("attachmentItem-\(item.name)")
    }

    @ViewBuilder private var content: some View {
        if item.kind == .image {
            Group {
                if let thumbnail = item.thumbnail, let image = UIImage(data: thumbnail) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.2))
                        .overlay { Image(systemName: "photo").foregroundStyle(.secondary) }
                }
            }
            .frame(width: Self.side, height: Self.side)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else {
            HStack(spacing: 8) {
                FileGlyph(kind: .file, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: item.name)
                        .font(.footnote.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(verbatim: AttachmentText.detail(name: item.name, size: Double(item.size)))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: 190, minHeight: Self.side, maxHeight: Self.side, alignment: .leading)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline))
        }
    }

    @ViewBuilder private var status: some View {
        switch item.state {
        case .preparing, .uploading:
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(0.35))
                ProgressRing(share: { if case .uploading(let share) = item.state { share } else { nil } }())
            }
            .accessibilityLabel(Text("Uploading…"))
            .accessibilityIdentifier("attachmentUploading")
        case .failed(let message):
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(0.35))
                Image(systemName: "exclamationmark")
                    .font(.system(size: 15, weight: .heavy))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Theme.danger, in: Circle())
            }
            .accessibilityLabel(Text(verbatim: message))
            .accessibilityIdentifier("attachmentFailed")
        case .uploaded:
            EmptyView()
        }
    }
}

/// An upload's progress: a ring filling up (a spinning one while the share is not known yet).
struct ProgressRing: View {
    let share: Double?

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.35), lineWidth: 3)
            if let share {
                Circle()
                    .trim(from: 0, to: max(0.03, share))
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.2), value: share)
            } else {
                ProgressView().tint(.white).controlSize(.small)
            }
        }
        .frame(width: 26, height: 26)
    }
}

/// A file's round icon: a document, or a photo for an image without a preview.
struct FileGlyph: View {
    let kind: AttachmentKind
    var size: CGFloat = 40
    var dimmed = false

    var body: some View {
        Image(systemName: kind == .image ? "photo" : "doc.fill")
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(dimmed ? Color.secondary.opacity(0.5) : Theme.accent, in: Circle())
            .accessibilityHidden(true)
    }
}
