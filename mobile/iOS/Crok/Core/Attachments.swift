import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Photos and files in prompts (relay/DESIGN.md §2 "Photos and files", §5 "Photos and files in prompts"): what the relay
// says about them, what the phone sends, and how an image is prepared before its upload.

enum AttachmentKind: String, LenientStringEnum {
    case image, file
    static var unknownValue: AttachmentKind { .file }
}

/// A photo or file on a transcript item or a prompt (`attachments` on events and `commands:forSession`). `url` and
/// `thumbUrl` are null once the upload is gone; a file only on the computer has no `storageId`.
struct Attachment: Codable, Hashable, Sendable {
    var storageId: String?
    var thumbId: String?
    var name: String
    var mimeType: String
    var size: Double
    var kind: AttachmentKind
    var width: Double?
    var height: Double?
    var url: String?
    var thumbUrl: String?

    init(
        storageId: String?, thumbId: String? = nil, name: String, mimeType: String, size: Double, kind: AttachmentKind,
        width: Double? = nil, height: Double? = nil, url: String? = nil, thumbUrl: String? = nil
    ) {
        self.storageId = storageId
        self.thumbId = thumbId
        self.name = name
        self.mimeType = mimeType
        self.size = size
        self.kind = kind
        self.width = width
        self.height = height
        self.url = url
        self.thumbUrl = thumbUrl
    }

    private enum CodingKeys: String, CodingKey {
        case storageId, thumbId, name, mimeType, size, kind, width, height, url, thumbUrl
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        storageId = try? c.decodeIfPresent(String.self, forKey: .storageId)
        thumbId = try? c.decodeIfPresent(String.self, forKey: .thumbId)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? "file"
        mimeType = (try? c.decodeIfPresent(String.self, forKey: .mimeType)) ?? "application/octet-stream"
        size = (try? c.decodeIfPresent(Double.self, forKey: .size)) ?? 0
        kind = (try? c.decodeIfPresent(AttachmentKind.self, forKey: .kind)) ?? .file
        width = try? c.decodeIfPresent(Double.self, forKey: .width)
        height = try? c.decodeIfPresent(Double.self, forKey: .height)
        url = try? c.decodeIfPresent(String.self, forKey: .url)
        thumbUrl = try? c.decodeIfPresent(String.self, forKey: .thumbUrl)
    }
}

/// One upload as `commands:sendPrompt` and `sessions:create` take it.
struct AttachmentInput: Hashable, Sendable {
    var storageId: String
    var thumbId: String?
    var name: String
    var width: Int?
    var height: Int?

    /// Numbers go as JSON numbers (Double), optional fields are left out.
    var json: JSONValue {
        var object: [String: JSONValue] = ["storageId": .string(storageId), "name": .string(name)]
        if let thumbId { object["thumbId"] = .string(thumbId) }
        if let width { object["width"] = .number(Double(width)) }
        if let height { object["height"] = .number(Double(height)) }
        return .object(object)
    }
}

enum AttachmentLimits {
    static let maxCount = 10
    static let maxFileBytes = 20 * 1024 * 1024
    /// A GIF up to this size goes as it is (animation kept).
    static let maxGIFBytes = 10 * 1024 * 1024
    /// Images are uploaded at most this many pixels on their longer side.
    static let maxSide = 2048
    static let thumbnailSide = 480
    static let jpegQuality = 0.85
    static let thumbnailQuality = 0.7
}

enum AttachmentText {
    /// `photo-20261027-120000.jpg`, `-2`, `-3`, … for several in one pick (`index` counts from 1), local time.
    static func photoName(at date: Date, index: Int = 1, ext: String = "jpg", timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let suffix = index > 1 ? "-\(index)" : ""
        return "photo-\(formatter.string(from: date))\(suffix).\(ext)"
    }

    /// The name with its extension changed to `ext` (added when it has none).
    static func renamed(_ name: String, ext: String) -> String {
        let base = (name as NSString).deletingPathExtension
        return "\((base.isEmpty ? "photo" : base)).\(ext)"
    }

    /// "1.2 MB · PDF": the size, then the extension in capitals (just the size without one).
    static func detail(name: String, size: Double) -> String {
        let bytes = ByteCountFormatter.string(fromByteCount: Int64(max(0, size)), countStyle: .file)
        let ext = (name as NSString).pathExtension.uppercased()
        return ext.isEmpty ? bytes : "\(bytes) · \(ext)"
    }

    /// The type to upload a file with: the system's for its extension, else `application/octet-stream`.
    static func mimeType(forName name: String, type: UTType? = nil) -> String {
        if let mime = type?.preferredMIMEType { return mime }
        let ext = (name as NSString).pathExtension
        if !ext.isEmpty, let mime = UTType(filenameExtension: ext)?.preferredMIMEType { return mime }
        return "application/octet-stream"
    }
}

/// An image ready to upload: upright, at most 2048 px, without metadata, plus its thumbnail.
struct PreparedImage: Sendable, Equatable {
    var data: Data
    var mimeType: String
    var name: String
    var width: Int
    var height: Int
    /// At most 480 px, JPEG on white; nil when it could not be made (the image goes without one).
    var thumbnail: Data?
}

enum ImagePreparerError: Error, Equatable {
    case unreadable
}

/// The contract's image rules: every image but a GIF of at most 10 MB is re-encoded upright, at most 2048 px on its
/// longer side, without metadata, as JPEG 0.85 (PNG when it is a PNG or has transparency); HEIC and other formats
/// become JPEG.
enum ImagePreparer {
    static func prepare(_ data: Data, name: String) throws -> PreparedImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else {
            throw ImagePreparerError.unreadable
        }
        let type = (CGImageSourceGetType(source) as String?).flatMap { UTType($0) }
        let thumbnail = makeThumbnail(source)
        if type?.conforms(to: .gif) == true, data.count <= AttachmentLimits.maxGIFBytes {
            let (width, height) = pixelSize(source)
            return PreparedImage(
                data: data, mimeType: "image/gif", name: AttachmentText.renamed(name, ext: "gif"), width: width,
                height: height, thumbnail: thumbnail)
        }
        guard let image = upright(source, maxSide: AttachmentLimits.maxSide) else { throw ImagePreparerError.unreadable }
        let png = type?.conforms(to: .png) == true || hasAlpha(image)
        let encodedType: UTType = png ? .png : .jpeg
        guard let encoded = encode(image, as: encodedType, quality: AttachmentLimits.jpegQuality) else {
            throw ImagePreparerError.unreadable
        }
        return PreparedImage(
            data: encoded, mimeType: png ? "image/png" : "image/jpeg",
            name: AttachmentText.renamed(name, ext: png ? "png" : "jpg"), width: image.width, height: image.height,
            thumbnail: thumbnail)
    }

    /// Whether the data is an image ImageIO can read (a file picked through Files is then prepared as an image).
    static func isImage(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        guard let type = (CGImageSourceGetType(source) as String?).flatMap({ UTType($0) }) else { return false }
        return type.conforms(to: .image) && CGImageSourceGetCount(source) > 0 && !type.conforms(to: .pdf)
    }

    /// The image with its EXIF orientation applied, scaled down to `maxSide` (never up).
    static func upright(_ source: CGImageSource, maxSide: Int) -> CGImage? {
        let (width, height) = pixelSize(source)
        let longer = max(width, height)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: longer > 0 ? min(maxSide, longer) : maxSide,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// The thumbnail: at most 480 px, transparency on white, JPEG 0.7.
    static func makeThumbnail(_ source: CGImageSource) -> Data? {
        guard let small = upright(source, maxSide: AttachmentLimits.thumbnailSide) else { return nil }
        guard let flat = onWhite(small) else { return nil }
        return encode(flat, as: .jpeg, quality: AttachmentLimits.thumbnailQuality)
    }

    /// Pixel size as stored (before orientation), swapped for the orientations that rotate by 90°.
    static func pixelSize(_ source: CGImageSource) -> (Int, Int) {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return (5...8).contains(orientation) ? (height, width) : (width, height)
    }

    static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
    }

    static func onWhite(_ image: CGImage) -> CGImage? {
        guard
            let context = CGContext(
                data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(rect)
        context.draw(image, in: rect)
        return context.makeImage()
    }

    /// Encodes only the pixels: no EXIF, GPS or other metadata is copied.
    static func encode(_ image: CGImage, as type: UTType, quality: Double) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else {
            return nil
        }
        let properties: [CFString: Any] = type == .jpeg ? [kCGImageDestinationLossyCompressionQuality: quality] : [:]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}

/// How a message's images are laid out in its bubble: one shown whole, several as square tiles two per row (the last
/// full width when the count is odd).
enum MediaLayout {
    static let maxWidth: CGFloat = 260
    static let maxHeight: CGFloat = 320
    static let gap: CGFloat = 2
    /// A lone image narrower than this is shown this wide (cropped to fill).
    static let minSingleWidth: CGFloat = 140

    struct Tile: Equatable {
        var index: Int
        var frame: CGRect
    }

    /// One image: aspect-fit from its size into 260 × 320, square without one.
    static func singleSize(width: Double?, height: Double?) -> CGSize {
        guard let width, let height, width > 0, height > 0 else { return CGSize(width: 220, height: 220) }
        let scale = min(maxWidth / width, maxHeight / height)
        let fitted = CGSize(width: width * scale, height: height * scale)
        return CGSize(width: max(minSingleWidth, fitted.width.rounded()), height: fitted.height.rounded())
    }

    /// Tiles for `count` images (two or more) in a grid `width` wide.
    static func grid(count: Int, width: CGFloat = maxWidth) -> [Tile] {
        guard count > 1 else { return [] }
        let side = ((width - gap) / 2).rounded(.down)
        var tiles: [Tile] = []
        var y: CGFloat = 0
        var index = 0
        while index < count {
            if index == count - 1 {
                tiles.append(Tile(index: index, frame: CGRect(x: 0, y: y, width: width, height: side)))
                index += 1
            } else {
                tiles.append(Tile(index: index, frame: CGRect(x: 0, y: y, width: side, height: side)))
                tiles.append(Tile(index: index + 1, frame: CGRect(x: width - side, y: y, width: side, height: side)))
                index += 2
            }
            y += side + gap
        }
        return tiles
    }

    static func gridHeight(count: Int, width: CGFloat = maxWidth) -> CGFloat {
        grid(count: count, width: width).map(\.frame.maxY).max() ?? 0
    }
}
