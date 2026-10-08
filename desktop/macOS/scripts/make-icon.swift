import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// The app icon is raster artwork, one image per appearance, set into the macOS icon tile at each ICNS
// size; the in-app symbol is generated from the vector mark in GrokMark.svg.
// Render into explicit pixel buffers: NSImage.lockFocus() otherwise inherits display scale.
struct IconError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

struct SVGShape {
    var data: String
    var path: CGPath
    var evenOdd: Bool
}

final class SVGReader: NSObject, XMLParserDelegate {
    private(set) var viewBox: CGRect?
    private(set) var shapes: [SVGShape] = []
    private(set) var failure: Error?

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        do {
            guard attributes["transform"] == nil else {
                throw IconError(message: "Flatten SVG transforms before generating the icon.")
            }
            switch elementName {
            case "svg":
                guard let raw = attributes["viewBox"] else { throw IconError(message: "GrokMark.svg needs a viewBox.") }
                let values = raw.split { $0.isWhitespace || $0 == "," }.compactMap { Double($0) }
                guard values.count == 4, values.allSatisfy(\.isFinite), values[2] > 0, values[3] > 0 else {
                    throw IconError(message: "The SVG viewBox must contain four valid numbers.")
                }
                viewBox = CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
            case "path":
                guard let data = attributes["d"], !data.isEmpty else { throw IconError(message: "An SVG path has no geometry.") }
                guard attributes["fill"] != "none" else { throw IconError(message: "Use filled outlines rather than strokes for the logo.") }
                shapes.append(SVGShape(data: data, path: try parsePath(data), evenOdd: attributes["fill-rule"] == "evenodd"))
            case "g", "title", "desc", "metadata": break
            default: throw IconError(message: "Unsupported SVG element: \(elementName). Convert the logo to filled paths.")
            }
        } catch {
            failure = error
            parser.abortParsing()
        }
    }
}

func parsePath(_ data: String) throws -> CGPath {
    let expression = try NSRegularExpression(pattern: #"[A-Za-z]|[-+]?(?:\d*\.\d+|\d+\.?\d*)(?:[eE][-+]?\d+)?"#)
    let raw = data as NSString
    let matches = expression.matches(in: data, range: NSRange(location: 0, length: raw.length))
    var previousEnd = 0
    var tokens: [String] = []
    for match in matches {
        let gap = raw.substring(with: NSRange(location: previousEnd, length: match.range.location - previousEnd))
        guard gap.allSatisfy({ $0.isWhitespace || $0 == "," }) else { throw IconError(message: "Invalid SVG path syntax.") }
        tokens.append(raw.substring(with: match.range))
        previousEnd = match.range.location + match.range.length
    }
    guard raw.substring(from: previousEnd).allSatisfy({ $0.isWhitespace || $0 == "," }) else {
        throw IconError(message: "Invalid SVG path suffix.")
    }
    let path = CGMutablePath()
    var index = 0
    var command = ""
    var point = CGPoint.zero
    var start = CGPoint.zero
    var lastCubicControl: CGPoint?
    var lastQuadraticControl: CGPoint?

    func number() throws -> CGFloat {
        guard index < tokens.count, let value = Double(tokens[index]), value.isFinite else {
            throw IconError(message: "Missing coordinate in SVG path command \(command).")
        }
        index += 1
        return CGFloat(value)
    }
    func coordinate(relative: Bool) throws -> CGPoint {
        let x = try number(), y = try number()
        return CGPoint(x: x + (relative ? point.x : 0), y: y + (relative ? point.y : 0))
    }
    func reflected(_ control: CGPoint?) -> CGPoint {
        guard let control else { return point }
        return CGPoint(x: point.x * 2 - control.x, y: point.y * 2 - control.y)
    }

    while index < tokens.count {
        if tokens[index].first?.isLetter == true { command = tokens[index]; index += 1 }
        let relative = command == command.lowercased()
        let previousCubic = lastCubicControl
        let previousQuadratic = lastQuadraticControl
        lastCubicControl = nil; lastQuadraticControl = nil
        switch command.uppercased() {
        case "M":
            point = try coordinate(relative: relative); start = point; path.move(to: point)
            command = relative ? "l" : "L"
        case "L":
            point = try coordinate(relative: relative); path.addLine(to: point)
        case "H":
            point.x = try number() + (relative ? point.x : 0); path.addLine(to: point)
        case "V":
            point.y = try number() + (relative ? point.y : 0); path.addLine(to: point)
        case "C":
            let first = try coordinate(relative: relative), second = try coordinate(relative: relative)
            let end = try coordinate(relative: relative)
            path.addCurve(to: end, control1: first, control2: second)
            point = end; lastCubicControl = second
        case "S":
            let first = reflected(previousCubic)
            let second = try coordinate(relative: relative), end = try coordinate(relative: relative)
            path.addCurve(to: end, control1: first, control2: second)
            point = end; lastCubicControl = second
        case "Q":
            let control = try coordinate(relative: relative), end = try coordinate(relative: relative)
            path.addQuadCurve(to: end, control: control)
            point = end; lastQuadraticControl = control
        case "T":
            let control = reflected(previousQuadratic), end = try coordinate(relative: relative)
            path.addQuadCurve(to: end, control: control)
            point = end; lastQuadraticControl = control
        case "Z":
            path.closeSubpath(); point = start; command = ""
        default:
            throw IconError(message: "Unsupported SVG path command '\(command)'. Use M/L/H/V/C/S/Q/T/Z outlines.")
        }
    }
    guard !path.isEmpty else { throw IconError(message: "The SVG logo path is empty.") }
    return path
}

let scriptURL = URL(fileURLWithPath: #filePath).standardizedFileURL
let resourcesURL = scriptURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources")
let rawArguments = Array(CommandLine.arguments.dropFirst())
let isTestVariant = rawArguments.last == "--test"
let arguments = isTestVariant ? Array(rawArguments.dropLast()) : rawArguments
guard arguments.count <= 5 else {
    throw IconError(message: "Usage: swift make-icon.swift [AppIcon.icns] [AppIconDark.icns] [GrokMark.svg] [GrokSymbol.swift] [AppIcon-preview.png] [--test]")
}
func argument(_ index: Int, or fallback: URL) -> URL {
    index < arguments.count ? URL(fileURLWithPath: arguments[index]) : fallback
}
let lightDestination = argument(0, or: resourcesURL.appendingPathComponent("AppIcon.icns"))
let darkDestination = argument(1, or: lightDestination.deletingLastPathComponent()
    .appendingPathComponent(lightDestination.deletingPathExtension().lastPathComponent + "Dark.icns"))
let source = argument(2, or: resourcesURL.appendingPathComponent("GrokMark.svg"))
let symbolDestination = argument(3, or: resourcesURL.deletingLastPathComponent().appendingPathComponent("Sources/GrokDesktop/GrokSymbol.swift"))
let previewDestination = argument(4, or: resourcesURL.deletingLastPathComponent().appendingPathComponent("dist/AppIcon-preview.png"))

let reader = SVGReader()
guard let parser = XMLParser(contentsOf: source) else { throw IconError(message: "Could not open \(source.path).") }
parser.delegate = reader
parser.shouldResolveExternalEntities = false
guard parser.parse(), let viewBox = reader.viewBox, !reader.shapes.isEmpty else {
    throw reader.failure ?? parser.parserError ?? IconError(message: "No usable paths in \(source.path).")
}

// Apple's macOS icon grid, which the other coding agents' icons (ChatGPT, Claude, Cursor) follow: an
// 824 pt tile with continuous corners of radius 185.4 pt, centred on the 1024 pt canvas to leave room
// for the drop shadow. The artwork fills the tile edge to edge. The test variant adds an orange
// "TESTING" pill below the mark so a workspace build stays recognizable beside the production app.
let tileInset: CGFloat = 100.0 / 1024.0
let tileCornerRadius: CGFloat = 185.4 / 1024.0
let testPill = CGRect(x: 0.215, y: 0.72, width: 0.57, height: 0.115)
let pillTop = (1.0, 0.525, 0.184)
let pillBottom = (0.945, 0.353, 0.024)

func tilePath(in frame: CGRect, side: CGFloat) -> CGPath {
    RoundedRectangle(cornerRadius: side * tileCornerRadius, style: .continuous).path(in: frame).cgPath
}

func color(_ rgb: (Double, Double, Double), alpha: CGFloat = 1) -> CGColor {
    CGColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: alpha)
}

func makeContext(pixels: Int, height: Int? = nil) throws -> CGContext {
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(data: nil, width: pixels, height: height ?? pixels, bitsPerComponent: 8,
                                  bytesPerRow: pixels * 4, space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw IconError(message: "Could not allocate \(pixels) × \(height ?? pixels) icon pixels.")
    }
    return context
}

func loadArtwork(_ name: String) throws -> CGImage {
    let url = resourcesURL.appendingPathComponent(name)
    guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
        throw IconError(message: "Could not read the icon artwork \(url.path).")
    }
    guard image.width == image.height, image.width >= 1024 else {
        throw IconError(message: "\(name) must be a square of at least 1024 px; it is \(image.width) × \(image.height).")
    }
    return image
}

/// Whether the artwork reads as light overall, from the mean of an 8 × 8 downsample.
func isLight(_ image: CGImage) throws -> Bool {
    let sample = try makeContext(pixels: 8)
    sample.interpolationQuality = .high
    sample.draw(image, in: CGRect(x: 0, y: 0, width: 8, height: 8))
    guard let data = sample.data else { return false }
    let bytes = data.bindMemory(to: UInt8.self, capacity: 8 * 8 * 4)
    var luminance: CGFloat = 0
    for pixel in 0..<64 {
        luminance += 0.2126 * CGFloat(bytes[pixel * 4]) + 0.7152 * CGFloat(bytes[pixel * 4 + 1]) + 0.0722 * CGFloat(bytes[pixel * 4 + 2])
    }
    return luminance / 64 / 255 > 0.5
}

func render(_ artwork: CGImage, light: Bool, pixels: Int) throws -> CGImage {
    let context = try makeContext(pixels: pixels)
    let side = CGFloat(pixels)
    context.setAllowsAntialiasing(true); context.setShouldAntialias(true)
    context.interpolationQuality = .high
    context.translateBy(x: 0, y: side); context.scaleBy(x: 1, y: -1)
    let frame = CGRect(x: side * tileInset, y: side * tileInset,
                       width: side * (1 - 2 * tileInset), height: side * (1 - 2 * tileInset))
    let tile = tilePath(in: frame, side: side)

    // The artwork casts the system's icon shadow as one layer: soft, and a little below the tile.
    // Shadow offsets ignore the flip.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -side * 10 / 1024), blur: side * 22 / 1024,
                      color: CGColor(gray: 0, alpha: 0.4))
    context.beginTransparencyLayer(auxiliaryInfo: nil)
    context.addPath(tile)
    context.clip()
    // CGContext draws images upright in an unflipped space.
    context.translateBy(x: frame.minX, y: frame.maxY)
    context.scaleBy(x: 1, y: -1)
    context.draw(artwork, in: CGRect(origin: .zero, size: frame.size))
    context.endTransparencyLayer()
    context.restoreGState()

    // A faint bezel along the edge, as on the system's icons: light on dark artwork, dark on light.
    if pixels >= 64 {
        context.saveGState()
        context.addPath(tile)
        context.clip()
        context.addPath(tile)
        context.setLineWidth(side * 5 / 1024)
        context.setStrokeColor(CGColor(gray: light ? 0 : 1, alpha: light ? 0.08 : 0.14))
        context.strokePath()
        context.restoreGState()
    }

    if isTestVariant {
        let banner = CGRect(x: side * testPill.minX, y: side * testPill.minY, width: side * testPill.width, height: side * testPill.height)
        let pill = CGPath(roundedRect: banner, cornerWidth: banner.height / 2, cornerHeight: banner.height / 2, transform: nil)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -side * 4 / 1024), blur: side * 10 / 1024, color: CGColor(gray: 0, alpha: 0.35))
        context.addPath(pill)
        context.setFillColor(color(pillBottom))
        context.fillPath()
        context.restoreGState()
        context.saveGState()
        context.addPath(pill)
        context.clip()
        if let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
           let gradient = CGGradient(colorsSpace: colorSpace, colors: [color(pillTop), color(pillBottom)] as CFArray, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: banner.minY), end: CGPoint(x: 0, y: banner.maxY), options: [])
        }
        context.restoreGState()

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let text = "TESTING" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: side * 0.066, weight: .heavy),
            .kern: side * 0.004,
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph
        ]
        let textSize = text.size(withAttributes: attributes)
        let textFrame = CGRect(x: banner.minX, y: banner.midY - textSize.height / 2,
                               width: banner.width, height: textSize.height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        text.draw(in: textFrame, withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
    }

    guard let image = context.makeImage() else { throw IconError(message: "Could not render icon.") }
    return image
}

func png(_ image: CGImage) throws -> Data {
    let data = NSMutableData()
    guard let output = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
        throw IconError(message: "Could not encode icon PNG.")
    }
    CGImageDestinationAddImage(output, image, nil)
    guard CGImageDestinationFinalize(output) else { throw IconError(message: "Could not finish icon PNG.") }
    return data as Data
}

/// Writes the ICNS for one appearance and returns its 256 px rendition for the preview.
func writeIcon(artworkName: String, to destination: URL) throws -> CGImage {
    let artwork = try loadArtwork(artworkName)
    let light = try isLight(artwork)
    let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("GrokDesktop-\(UUID().uuidString).iconset")
    try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: iconset) }
    var renditions: [Int: CGImage] = [:]
    for size in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let pixels = size * scale
            let image = try renditions[pixels] ?? render(artwork, light: light, pixels: pixels)
            renditions[pixels] = image
            let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
            try png(image).write(to: iconset.appendingPathComponent(name), options: .atomic)
        }
    }
    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    process.arguments = ["-c", "icns", "-o", destination.path, iconset.path]
    try process.run(); process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw IconError(message: "iconutil failed (\(process.terminationStatus)).") }
    guard let preview = renditions[256] else { throw IconError(message: "No 256 px rendition.") }
    return preview
}

// The appearance each artwork is shown in, not its own colours: the dark tile is the light-mode icon.
let lightPreview = try writeIcon(artworkName: "AppIcon-LightMode.jpg", to: lightDestination)
let darkPreview = try writeIcon(artworkName: "AppIcon-DarkMode.jpg", to: darkDestination)

// The preview shows both icons side by side: light mode, then dark mode.
let previewContext = try makeContext(pixels: 512, height: 256)
previewContext.draw(lightPreview, in: CGRect(x: 0, y: 0, width: 256, height: 256))
previewContext.draw(darkPreview, in: CGRect(x: 256, y: 0, width: 256, height: 256))
guard let previewImage = previewContext.makeImage() else { throw IconError(message: "Could not compose the icon preview.") }
try FileManager.default.createDirectory(at: previewDestination.deletingLastPathComponent(), withIntermediateDirectories: true)
try png(previewImage).write(to: previewDestination, options: .atomic)

func swiftPoint(_ point: CGPoint) -> String { "CGPoint(x: \(point.x), y: \(point.y))" }
var instructions: [String] = []
for shape in reader.shapes {
    shape.path.applyWithBlock { pointer in
        let element = pointer.pointee
        switch element.type {
        case .moveToPoint: instructions.append("path.move(to: \(swiftPoint(element.points[0])))")
        case .addLineToPoint: instructions.append("path.addLine(to: \(swiftPoint(element.points[0])))")
        case .addQuadCurveToPoint:
            instructions.append("path.addQuadCurve(to: \(swiftPoint(element.points[1])), control: \(swiftPoint(element.points[0])))")
        case .addCurveToPoint:
            instructions.append("path.addCurve(to: \(swiftPoint(element.points[2])), control1: \(swiftPoint(element.points[0])), control2: \(swiftPoint(element.points[1])))")
        case .closeSubpath: instructions.append("path.closeSubpath()")
        @unknown default: break
        }
    }
}
let symbol = """
// Generated from Resources/GrokMark.svg by scripts/make-icon.swift. Do not edit by hand.
import SwiftUI

struct GrokSymbol: Shape {
    /// The mark in its SVG coordinates, built once: it has hundreds of segments, and every reply row draws it.
    private static let outline: Path = {
        var path = Path()
\(instructions.map { "        " + $0 }.joined(separator: "\n"))
        return path
    }()

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width / \(viewBox.width), rect.height / \(viewBox.height))
        return Self.outline.applying(CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
                                                       tx: rect.midX - \(viewBox.midX) * scale,
                                                       ty: rect.midY - \(viewBox.midY) * scale))
    }
}

"""
try FileManager.default.createDirectory(at: symbolDestination.deletingLastPathComponent(), withIntermediateDirectories: true)
// Keep SwiftPM's incremental build intact when the canonical geometry has not changed.
if (try? String(contentsOf: symbolDestination, encoding: .utf8)) != symbol {
    try symbol.write(to: symbolDestination, atomically: true, encoding: .utf8)
}
print("Generated \(lightDestination.path) and \(darkDestination.path) (16–1024 px), the SwiftUI shape from \(source.lastPathComponent), and \(previewDestination.path).")
