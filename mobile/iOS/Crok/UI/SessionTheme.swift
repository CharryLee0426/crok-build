import CoreImage
import ImageIO
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The session background and the person's bubbles (mobile/DESIGN.md "Session themes"): Telegram's chat themes, drawn
/// by Crok, each with a light and a dark variant; no theme (Crok's plain canvas); or a photo.
struct SessionTheme: Identifiable, Sendable {
    enum Kind: Sendable { case plain, pattern, photo }

    struct Variant: Sendable, Equatable {
        /// The gradient's four colours, at `SessionWallpaper.points`.
        var colors: [UInt32]
        var out: UInt32
        var outText: UInt32
        var outMeta: UInt32
    }

    let id: String
    let name: LocalizedStringResource
    let emoji: String
    let kind: Kind
    var light: Variant?
    var dark: Variant?
    /// The doodles of the pattern (SF Symbols).
    var symbols: [String] = []

    func variant(dark isDark: Bool) -> Variant? { isDark ? dark : light }

    static let noneID = "none"
    static let photoID = "photo"
    /// `@AppStorage` keys.
    static let storageKey = "crok.sessionTheme"
    static let blurKey = "crok.sessionThemeBlur"

    static func named(_ id: String) -> SessionTheme {
        all.first(where: { $0.id == id }) ?? none
    }

    static let none = SessionTheme(id: noneID, name: "No Theme", emoji: "", kind: .plain)
    static let photo = SessionTheme(id: photoID, name: "Photo", emoji: "", kind: .photo)

    private static func v(_ colors: [UInt32], _ out: UInt32, _ outText: UInt32, _ outMeta: UInt32) -> Variant {
        Variant(colors: colors, out: out, outText: outText, outMeta: outMeta)
    }

    /// No Theme, Classic, the nine emoji themes, Photo (the strip shows Photo only once one was chosen).
    static let all: [SessionTheme] = [
        none,
        SessionTheme(
            id: "classic", name: "Classic", emoji: "🌿", kind: .pattern,
            light: v([0xDBDDBB, 0x6BA587, 0xD5D88D, 0x88B884], 0xEFFDDE, 0x000000, 0x4FAE4E),
            dark: v([0x2E5B46, 0x14322A, 0x3F6A3A, 0x1D4236], 0x2F5D50, 0xFFFFFF, 0xA5E0C9),
            symbols: [
                "terminal", "chevron.left.forwardslash.chevron.right", "curlybraces", "cpu", "ladybug", "hammer", "number",
                "function", "keyboard", "server.rack", "bolt", "paperplane", "cloud", "sparkles", "laptopcomputer",
                "cup.and.saucer",
            ]),
        SessionTheme(
            id: "home", name: "Home", emoji: "🏠", kind: .pattern,
            light: v([0xF9D9A9, 0xF2B880, 0xFCE8C8, 0xE9A877], 0xFFE3C2, 0x000000, 0xC4772F),
            dark: v([0x6B4220, 0x3A2412, 0x7D5026, 0x4C2E17], 0x7A4A22, 0xFFFFFF, 0xF5C99A),
            symbols: [
                "house", "sofa", "lamp.desk", "cup.and.saucer", "key", "leaf", "bed.double", "fork.knife", "frying.pan",
                "fireplace", "sun.max", "heart",
            ]),
        SessionTheme(
            id: "duck", name: "Duckling", emoji: "🐥", kind: .pattern,
            light: v([0xFFF3A3, 0xD9F29B, 0xFFE07A, 0xBFE59A], 0xFFF4B8, 0x000000, 0xB89A00),
            dark: v([0x5E5A1A, 0x33461F, 0x6E5E14, 0x2C3F1D], 0x6B5E12, 0xFFFFFF, 0xF2E38A),
            symbols: [
                "bird", "leaf", "sun.max", "cloud", "drop", "carrot", "ladybug", "tortoise", "hare", "camera.macro", "star",
            ]),
        SessionTheme(
            id: "snowman", name: "Snowman", emoji: "⛄", kind: .pattern,
            light: v([0xE3F2FF, 0xB8DCFB, 0xF2F8FF, 0xA8CDF2], 0xD8EEFF, 0x000000, 0x3390EC),
            dark: v([0x1E3D63, 0x11233B, 0x2A4B78, 0x173052], 0x24507E, 0xFFFFFF, 0xA8CCF7),
            symbols: [
                "snowflake", "cloud.snow", "mountain.2", "wind", "star", "moon.stars", "thermometer.snowflake", "sparkles",
                "cup.and.saucer", "figure.skiing.downhill",
            ]),
        SessionTheme(
            id: "diamond", name: "Diamond", emoji: "💎", kind: .pattern,
            light: v([0xA8E6E2, 0x9AC7F5, 0xC9F0E4, 0xB6B4F2], 0xD4F4EE, 0x000000, 0x1F9C8F),
            dark: v([0x16595C, 0x153562, 0x1F5E57, 0x353070], 0x1E6B6B, 0xFFFFFF, 0x9FEDE2),
            symbols: [
                "diamond", "sparkle", "crown", "seal", "star", "rhombus", "hexagon", "octagon", "sparkles", "suit.diamond",
            ]),
        SessionTheme(
            id: "teacher", name: "Teacher", emoji: "👨‍🏫", kind: .pattern,
            light: v([0xCFE8C9, 0x9FD3C7, 0xE7F0C3, 0xB4D9A6], 0xE3F4D9, 0x000000, 0x4C9A4A),
            dark: v([0x2B4D35, 0x1A3628, 0x3E5832, 0x22473F], 0x2E5A38, 0xFFFFFF, 0xB4E3A8),
            symbols: [
                "book", "pencil", "graduationcap", "ruler", "function", "atom", "globe", "backpack", "paperclip",
                "lightbulb", "books.vertical",
            ]),
        SessionTheme(
            id: "tulip", name: "Tulip", emoji: "🌷", kind: .pattern,
            light: v([0xFFD1DC, 0xF7A8C4, 0xFFE4EC, 0xF2B6D0], 0xFFDDE7, 0x000000, 0xD9467A),
            dark: v([0x6E2447, 0x43162D, 0x852E55, 0x561D38], 0x7A2A4E, 0xFFFFFF, 0xFFB3CE),
            symbols: [
                "camera.macro", "leaf", "heart", "sun.max", "ladybug", "drop", "sparkles", "allergens", "cloud", "star",
            ]),
        SessionTheme(
            id: "purple", name: "Purple Heart", emoji: "💜", kind: .pattern,
            light: v([0xE2D4FA, 0xC7B2F2, 0xF0E6FF, 0xD5B8EE], 0xEADFFF, 0x000000, 0x8A5CD8),
            dark: v([0x45276F, 0x29184B, 0x5A318C, 0x371F60], 0x563590, 0xFFFFFF, 0xD3BCFF),
            symbols: [
                "heart", "sparkles", "star", "moon", "music.note", "suit.heart", "balloon", "gift", "envelope",
                "face.smiling",
            ]),
        SessionTheme(
            id: "christmas", name: "Christmas Tree", emoji: "🎄", kind: .pattern,
            light: v([0xD7EBD3, 0xF3D8C5, 0xC3E0C9, 0xF1E3B3], 0xE2F2DC, 0x000000, 0x3D8E48),
            dark: v([0x1D472D, 0x572222, 0x173A24, 0x4C3A15], 0x2D5C3A, 0xFFFFFF, 0xB5E6BE),
            symbols: [
                "gift", "snowflake", "star", "bell", "tree", "flame", "sparkles", "moon.stars", "cup.and.saucer",
                "music.note",
            ]),
        SessionTheme(
            id: "game", name: "Video Game", emoji: "🎮", kind: .pattern,
            light: v([0xC9D6FF, 0xE2C9FF, 0xB8F0FF, 0xD6E4FF], 0xDDE4FF, 0x000000, 0x5B6CF0),
            dark: v([0x272E73, 0x451E77, 0x17456F, 0x33216F], 0x3B3F9E, 0xFFFFFF, 0xC3C8FF),
            symbols: [
                "gamecontroller", "arcade.stick", "dpad", "trophy", "bolt", "star", "flag.checkered", "heart",
                "puzzlepiece", "die.face.5", "crown", "keyboard",
            ]),
        photo,
    ]
}

/// The colours the session screen's bubbles and capsules take from the theme.
struct SessionPalette: Equatable {
    var userBubble: Color
    var userBubbleText: Color
    var userBubbleMeta: Color
    /// Day headers and notices.
    var serviceBackground: Color
    var serviceText: Color
    /// The background is a pattern or a photo: loose text (thoughts) gets a card under it.
    var onWallpaper = false

    static let standard = SessionPalette(
        userBubble: Theme.userBubble, userBubbleText: Theme.userBubbleText, userBubbleMeta: Theme.userBubbleMeta,
        serviceBackground: Theme.noticeBackground, serviceText: Theme.noticeText)

    static func make(_ theme: SessionTheme, dark: Bool) -> SessionPalette {
        var palette = standard
        if theme.kind != .plain {
            // On a pattern or a photo, Telegram's service capsules: dark glass with white text.
            palette.serviceBackground = Color.black.opacity(dark ? 0.40 : 0.22)
            palette.serviceText = .white
            palette.onWallpaper = true
        }
        if let variant = theme.variant(dark: dark) {
            palette.userBubble = Color(uiColor: UIColor(hex: variant.out))
            palette.userBubbleText = Color(uiColor: UIColor(hex: variant.outText))
            palette.userBubbleMeta = Color(uiColor: UIColor(hex: variant.outMeta))
        }
        return palette
    }
}

private struct SessionPaletteKey: EnvironmentKey {
    static let defaultValue = SessionPalette.standard
}

extension EnvironmentValues {
    var sessionPalette: SessionPalette {
        get { self[SessionPaletteKey.self] }
        set { self[SessionPaletteKey.self] = newValue }
    }
}

// MARK: - Drawing

/// Draws a theme's background: the four-colour gradient and the doodle pattern (mobile/DESIGN.md "Session themes").
enum SessionWallpaper {
    /// Where the four colours sit in the unit square (x right, y down).
    static let points: [(Double, Double)] = [(0.80, 0.10), (0.20, 0.30), (0.75, 0.65), (0.25, 0.90)]
    static let darkBase: UInt32 = 0x0B0D10

    /// The weight of colour `i` at a point: `max(0, 0.9 − distance)⁴`, normalised over the four.
    static func weights(x: Double, y: Double) -> [Double] {
        let raw = points.map { point -> Double in
            let d = ((x - point.0) * (x - point.0) + (y - point.1) * (y - point.1)).squareRoot()
            let w = max(0, 0.9 - d)
            return w * w * w * w
        }
        let sum = raw.reduce(0, +)
        guard sum > 0 else { return [0.25, 0.25, 0.25, 0.25] }
        return raw.map { $0 / sum }
    }

    /// The gradient as a small image (scaled up smoothly when drawn).
    static func gradient(_ colors: [UInt32], width: Int = 72, height: Int = 96) -> CGImage? {
        guard colors.count == 4 else { return nil }
        let rgb = colors.map { c in
            (Double((c >> 16) & 0xFF), Double((c >> 8) & 0xFF), Double(c & 0xFF))
        }
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for row in 0..<height {
            for column in 0..<width {
                let w = weights(x: Double(column) / Double(width - 1), y: Double(row) / Double(height - 1))
                var r = 0.0, g = 0.0, b = 0.0
                for i in 0..<4 {
                    r += rgb[i].0 * w[i]
                    g += rgb[i].1 * w[i]
                    b += rgb[i].2 * w[i]
                }
                let index = (row * width + column) * 4
                pixels[index] = UInt8(max(0, min(255, r.rounded())))
                pixels[index + 1] = UInt8(max(0, min(255, g.rounded())))
                pixels[index + 2] = UInt8(max(0, min(255, b.rounded())))
            }
        }
        let data = Data(pixels) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil,
            shouldInterpolate: true, intent: .defaultIntent)
    }

    struct Glyph {
        var symbol: String
        var center: CGPoint
        var size: CGFloat
        var angle: CGFloat
    }

    /// Where the doodles go: a jittered grid of 62 pt cells, sizes 22–30 pt, turned −25…25°, from a generator seeded
    /// with the theme id (the same on every launch). `scale` shrinks everything (theme cards).
    static func layout(_ theme: SessionTheme, size: CGSize, scale: CGFloat = 1) -> [Glyph] {
        guard !theme.symbols.isEmpty else { return [] }
        var random = SeededRandom(seed: UInt64(ProjectAvatar.colorIndex(for: theme.id, paletteSize: Int(Int32.max))))
        let cell = 62 * scale
        let columns = Int((size.width / cell).rounded(.up)) + 1
        let rows = Int((size.height / cell).rounded(.up)) + 1
        var glyphs: [Glyph] = []
        for row in 0..<rows {
            for column in 0..<columns {
                let symbol = theme.symbols[Int(random.next() % UInt64(theme.symbols.count))]
                // Every other row shifts half a cell, so the doodles do not line up in columns.
                let shift = row % 2 == 0 ? 0 : cell / 2
                let jitterX = (random.unit() * 24 - 12) * scale
                let jitterY = (random.unit() * 24 - 12) * scale
                glyphs.append(
                    Glyph(
                        symbol: symbol,
                        center: CGPoint(
                            x: CGFloat(column) * cell + cell / 2 + shift + jitterX - cell / 2,
                            y: CGFloat(row) * cell + cell / 2 + jitterY),
                        size: (22 + random.unit() * 8) * scale,
                        angle: (random.unit() * 50 - 25) * .pi / 180))
            }
        }
        return glyphs
    }

    /// NSCache is thread-safe.
    nonisolated(unsafe) private static let cache = NSCache<NSString, UIImage>()

    /// The whole background at `size`, cached. Safe off the main thread.
    static func render(_ theme: SessionTheme, dark: Bool, size: CGSize, scale: CGFloat, patternScale: CGFloat = 1) -> UIImage? {
        guard let variant = theme.variant(dark: dark), size.width >= 1, size.height >= 1 else { return nil }
        let key = "\(theme.id)-\(dark)-\(Int(size.width))x\(Int(size.height))@\(scale)-\(patternScale)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let gradientImage = gradient(variant.colors) else { return nil }
        let gradient = UIImage(cgImage: gradientImage)
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        let rect = CGRect(origin: .zero, size: size)
        let glyphs = layout(theme, size: size, scale: patternScale)

        func drawGlyphs(_ color: UIColor) {
            guard let context = UIGraphicsGetCurrentContext() else { return }
            for glyph in glyphs {
                let configuration = UIImage.SymbolConfiguration(pointSize: glyph.size, weight: .regular)
                guard let image = UIImage(systemName: glyph.symbol, withConfiguration: configuration)?
                    .withTintColor(color, renderingMode: .alwaysOriginal)
                else { continue }
                context.saveGState()
                context.translateBy(x: glyph.center.x, y: glyph.center.y)
                context.rotate(by: glyph.angle)
                image.draw(in: CGRect(
                    x: -image.size.width / 2, y: -image.size.height / 2, width: image.size.width, height: image.size.height))
                context.restoreGState()
            }
        }

        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            context.cgContext.interpolationQuality = .high
            if dark {
                // Telegram's night patterns: near black, a hint of the gradient, the doodles lit by the gradient.
                UIColor(hex: darkBase).setFill()
                context.fill(rect)
                gradient.draw(in: rect, blendMode: .normal, alpha: 0.18)
                let transparent = UIGraphicsImageRendererFormat()
                transparent.scale = scale
                transparent.opaque = false
                let mask = UIGraphicsImageRenderer(size: size, format: transparent).image { _ in drawGlyphs(.white) }
                let glow = UIGraphicsImageRenderer(size: size, format: transparent).image { glowContext in
                    glowContext.cgContext.interpolationQuality = .high
                    gradient.draw(in: rect)
                    mask.draw(in: rect, blendMode: .destinationIn, alpha: 1)
                }
                glow.draw(in: rect, blendMode: .normal, alpha: 0.55)
            } else {
                gradient.draw(in: rect)
                drawGlyphs(UIColor.black.withAlphaComponent(0.12))
            }
        }
        cache.setObject(image, forKey: key)
        return image
    }
}

/// SplitMix64: a small generator that gives the same doodles for the same seed.
struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// 0 ≤ value < 1.
    mutating func unit() -> CGFloat {
        CGFloat(next() >> 11) / CGFloat(1 << 53)
    }
}

// MARK: - Photo

/// The photo chosen as the session background, kept in Application Support (downscaled to 2048 px).
@MainActor
@Observable
final class SessionPhoto {
    static let shared = SessionPhoto()

    private(set) var image: UIImage?
    private(set) var blurred: UIImage?
    @ObservationIgnored private var loaded = false

    var hasPhoto: Bool {
        loadIfNeeded()
        return image != nil
    }

    static var file: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("crok", isDirectory: true).appendingPathComponent("session-photo.jpg")
    }

    func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        if let data = try? Data(contentsOf: Self.file), let image = UIImage(data: data) {
            self.image = image
            blurred = nil
        }
    }

    /// The photo, blurred when asked (made once, in the background).
    func display(blur: Bool) -> UIImage? {
        loadIfNeeded()
        guard blur, let image else { return image }
        if let blurred { return blurred }
        Task.detached(priority: .userInitiated) {
            let made = Self.blur(image)
            await MainActor.run { [weak self] in
                if self?.image === image { self?.blurred = made }
            }
        }
        return image
    }

    /// Stores picked image data: downscaled, as JPEG. Returns false when it is not an image.
    func save(_ data: Data) async -> Bool {
        let file = Self.file
        let result: UIImage? = await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                let thumbnail = CGImageSourceCreateThumbnailAtIndex(
                    source, 0,
                    [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 2048,
                    ] as CFDictionary)
            else { return nil }
            let image = UIImage(cgImage: thumbnail)
            guard let jpeg = image.jpegData(compressionQuality: 0.88) else { return nil }
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard (try? jpeg.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])) != nil
            else { return nil }
            return image
        }.value
        guard let result else { return false }
        loaded = true
        image = result
        blurred = nil
        return true
    }

    nonisolated private static func blur(_ image: UIImage) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }
        let input = CIImage(cgImage: cgImage)
        // A smaller copy blurs faster and looks the same once blurred.
        let scale = min(1, 1024 / max(input.extent.width, input.extent.height))
        let small = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return nil }
        filter.setValue(small.clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(24 * scale * 2, forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage?.cropped(to: small.extent),
            let made = CIContext().createCGImage(output, from: small.extent)
        else { return nil }
        return UIImage(cgImage: made)
    }
}

// MARK: - Views

/// The background of a session (and of the new-session screen and the Appearance preview): the theme of the setting,
/// or `themeID` when given.
struct SessionBackgroundView: View {
    var themeID: String?
    /// Doodle scale: 1 on a session, smaller on theme cards.
    var patternScale: CGFloat = 1
    @AppStorage(SessionTheme.storageKey) private var storedTheme = SessionTheme.noneID
    @AppStorage(SessionTheme.blurKey) private var blur = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let theme = SessionTheme.named(themeID ?? storedTheme)
        let dark = colorScheme == .dark
        GeometryReader { proxy in
            switch theme.kind {
            case .plain:
                Theme.canvas
            case .photo:
                PhotoBackground(blur: blur, dark: dark, size: proxy.size)
            case .pattern:
                PatternBackground(theme: theme, dark: dark, size: proxy.size, scale: min(displayScale, 3),
                                  patternScale: patternScale)
            }
        }
    }
}

private struct PhotoBackground: View {
    let blur: Bool
    let dark: Bool
    let size: CGSize
    private var photo = SessionPhoto.shared

    init(blur: Bool, dark: Bool, size: CGSize) {
        self.blur = blur
        self.dark = dark
        self.size = size
    }

    var body: some View {
        if let image = photo.display(blur: blur) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: size.width, height: size.height)
                .clipped()
                .overlay(Color.black.opacity(dark ? 0.4 : 0))
        } else {
            Theme.canvas
        }
    }
}

private struct PatternBackground: View {
    let theme: SessionTheme
    let dark: Bool
    let size: CGSize
    let scale: CGFloat
    let patternScale: CGFloat
    @State private var rendered: UIImage?
    @State private var renderedKey: String?

    private var key: String { "\(theme.id)-\(dark)-\(Int(size.width))x\(Int(size.height))-\(patternScale)" }

    var body: some View {
        ZStack {
            // The plain gradient at once; the doodles fade in once drawn.
            if let gradient = theme.variant(dark: dark).flatMap({ SessionWallpaper.gradient($0.colors) }) {
                Image(decorative: gradient, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .overlay(dark ? Color(uiColor: UIColor(hex: SessionWallpaper.darkBase)).opacity(0.82) : .clear)
            }
            if let rendered, renderedKey == key {
                Image(uiImage: rendered)
                    .resizable()
                    .transition(.opacity)
            }
        }
        .frame(width: size.width, height: size.height)
        .task(id: key) {
            let theme = theme, dark = dark, size = size, scale = scale, patternScale = patternScale, key = key
            let image = await Task.detached(priority: .userInitiated) {
                SessionWallpaper.render(theme, dark: dark, size: size, scale: scale, patternScale: patternScale)
            }.value
            withAnimation(.easeOut(duration: 0.2)) {
                rendered = image
                renderedKey = key
            }
        }
    }
}
