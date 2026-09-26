import AppKit
import ImageIO
import UniformTypeIdentifiers

// The SVG is the single source for both the lossless artwork and each ICNS size.
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

func escapedXML(_ value: String) -> String {
    value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
}

let scriptURL = URL(fileURLWithPath: #filePath).standardizedFileURL
let resourcesURL = scriptURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources")
let rawArguments = Array(CommandLine.arguments.dropFirst())
let isTestVariant = rawArguments.last == "--test"
let arguments = isTestVariant ? Array(rawArguments.dropLast()) : rawArguments
guard arguments.count <= 4 else {
    throw IconError(message: "Usage: swift make-icon.swift [AppIcon.icns] [GrokMark.svg] [GrokSymbol.swift] [AppIcon-preview.png] [--test]")
}
let destination = arguments.first.map { URL(fileURLWithPath: $0) } ?? resourcesURL.appendingPathComponent("AppIcon.icns")
let source = arguments.dropFirst().first.map { URL(fileURLWithPath: $0) } ?? resourcesURL.appendingPathComponent("GrokMark.svg")
let symbolDestination = arguments.dropFirst(2).first.map { URL(fileURLWithPath: $0) }
    ?? resourcesURL.deletingLastPathComponent().appendingPathComponent("Sources/GrokDesktop/GrokSymbol.swift")
let previewDestination = arguments.dropFirst(3).first.map { URL(fileURLWithPath: $0) }
    ?? resourcesURL.deletingLastPathComponent().appendingPathComponent("dist/AppIcon-preview.png")
let reader = SVGReader()
guard let parser = XMLParser(contentsOf: source) else { throw IconError(message: "Could not open \(source.path).") }
parser.delegate = reader
parser.shouldResolveExternalEntities = false
guard parser.parse(), let viewBox = reader.viewBox, !reader.shapes.isEmpty else {
    throw reader.failure ?? parser.parserError ?? IconError(message: "No usable paths in \(source.path).")
}
try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("GrokDesktop-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }

// Apple's macOS icon grid, which the other coding agents' icons (ChatGPT, Claude, Cursor) follow: an
// 824 pt continuous-corner tile centred on the 1024 pt canvas, leaving room for the drop shadow, with
// the mark at about half the tile. The test variant uses a bright orange tile and a dark "TESTING"
// pill so a workspace build stays recognizable beside the production app.
let tileInset: CGFloat = 100.0 / 1024.0
/// The tile's outline: a superellipse, which matches the system's continuous-corner icon shape.
let tileExponent: CGFloat = 5
let markFraction: CGFloat = isTestVariant ? 0.37 : 0.44
let markCenterFraction: CGFloat = isTestVariant ? 0.435 : 0.5
let testPill = CGRect(x: 0.215, y: 0.69, width: 0.57, height: 0.125)
let tileTop = isTestVariant ? (1.0, 0.525, 0.184) : (0.184, 0.184, 0.196)
let tileBottom = isTestVariant ? (0.945, 0.353, 0.024) : (0.043, 0.043, 0.047)

/// Points on the tile's outline within `frame`, clockwise from the right-hand edge.
func tileOutline(in frame: CGRect, samples: Int = 720) -> [CGPoint] {
    (0..<samples).map { index in
        let angle = CGFloat(index) / CGFloat(samples) * 2 * .pi
        let cosine = cos(angle), sine = sin(angle)
        let x = pow(abs(cosine), 2 / tileExponent) * (cosine < 0 ? -1 : 1)
        let y = pow(abs(sine), 2 / tileExponent) * (sine < 0 ? -1 : 1)
        return CGPoint(x: frame.midX + x * frame.width / 2, y: frame.midY + y * frame.height / 2)
    }
}

func tilePath(in frame: CGRect) -> CGPath {
    let path = CGMutablePath()
    path.addLines(between: tileOutline(in: frame))
    path.closeSubpath()
    return path
}

func color(_ rgb: (Double, Double, Double), alpha: CGFloat = 1) -> CGColor {
    CGColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: alpha)
}

func hex(_ rgb: (Double, Double, Double)) -> String {
    String(format: "#%02X%02X%02X", Int((rgb.0 * 255).rounded()), Int((rgb.1 * 255).rounded()), Int((rgb.2 * 255).rounded()))
}

func render(pixels: Int) throws -> Data {
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                                  bytesPerRow: pixels * 4, space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw IconError(message: "Could not allocate \(pixels) × \(pixels) icon pixels.")
    }
    let side = CGFloat(pixels)
    context.setAllowsAntialiasing(true); context.setShouldAntialias(true)
    context.translateBy(x: 0, y: side); context.scaleBy(x: 1, y: -1)
    let frame = CGRect(x: side * tileInset, y: side * tileInset,
                       width: side * (1 - 2 * tileInset), height: side * (1 - 2 * tileInset))
    let tile = tilePath(in: frame)

    // The system's icon shadow: soft, and a little below the tile. Shadow offsets ignore the flip.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -side * 10 / 1024), blur: side * 22 / 1024,
                      color: CGColor(gray: 0, alpha: isTestVariant ? 0.28 : 0.4))
    context.addPath(tile)
    context.setFillColor(color(tileBottom))
    context.fillPath()
    context.restoreGState()

    // A gentle top-to-bottom gradient, lighter at the top as though lit from above.
    context.saveGState()
    context.addPath(tile)
    context.clip()
    if let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
       let gradient = CGGradient(colorsSpace: colorSpace, colors: [color(tileTop), color(tileBottom)] as CFArray, locations: [0, 1]) {
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: frame.minY), end: CGPoint(x: 0, y: frame.maxY), options: [])
    }
    context.restoreGState()

    // A faint bezel along the edge, as on the system's icons.
    if pixels >= 64 {
        context.saveGState()
        context.addPath(tile)
        context.clip()
        context.addPath(tile)
        context.setLineWidth(side * 5 / 1024)
        context.setStrokeColor(CGColor(gray: 1, alpha: isTestVariant ? 0.22 : 0.14))
        context.strokePath()
        context.restoreGState()
    }

    context.saveGState()
    let scale = side * markFraction / max(viewBox.width, viewBox.height)
    let markCenterY = side * markCenterFraction
    context.translateBy(x: (side - viewBox.width * scale) / 2, y: markCenterY - viewBox.height * scale / 2)
    context.scaleBy(x: scale, y: scale)
    context.translateBy(x: -viewBox.minX, y: -viewBox.minY)
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    for shape in reader.shapes {
        context.addPath(shape.path)
        context.drawPath(using: shape.evenOdd ? .eoFill : .fill)
    }
    context.restoreGState()

    if isTestVariant {
        let banner = CGRect(x: side * testPill.minX, y: side * testPill.minY, width: side * testPill.width, height: side * testPill.height)
        context.setFillColor(CGColor(red: 0.15, green: 0.06, blue: 0.02, alpha: 0.82))
        context.addPath(CGPath(roundedRect: banner, cornerWidth: banner.height / 2, cornerHeight: banner.height / 2, transform: nil))
        context.fillPath()

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let text = "TESTING" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: side * 0.068, weight: .heavy),
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
    let data = NSMutableData()
    guard let output = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
        throw IconError(message: "Could not encode icon PNG.")
    }
    CGImageDestinationAddImage(output, image, nil)
    guard CGImageDestinationFinalize(output) else { throw IconError(message: "Could not finish icon PNG.") }
    return data as Data
}

var preview: Data?
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let png = try render(pixels: pixels)
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try png.write(to: iconset.appendingPathComponent(name), options: .atomic)
        if pixels == 256 { preview = png }
    }
}
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", "-o", destination.path, iconset.path]
try process.run(); process.waitUntilExit()
guard process.terminationStatus == 0 else { throw IconError(message: "iconutil failed (\(process.terminationStatus)).") }

let outputBase = destination.deletingPathExtension()
if let preview {
    try FileManager.default.createDirectory(at: previewDestination.deletingLastPathComponent(), withIntermediateDirectories: true)
    try preview.write(to: previewDestination, options: .atomic)
}
let vectorSide: CGFloat = 1024
let vectorScale = vectorSide * markFraction / max(viewBox.width, viewBox.height)
let vectorX = (vectorSide - viewBox.width * vectorScale) / 2 - viewBox.minX * vectorScale
let vectorMarkCenterY = vectorSide * markCenterFraction
let vectorY = vectorMarkCenterY - viewBox.height * vectorScale / 2 - viewBox.minY * vectorScale
let paths = reader.shapes.map { "    <path d=\"\(escapedXML($0.data))\" fill-rule=\"\($0.evenOdd ? "evenodd" : "nonzero")\"/>" }.joined(separator: "\n")
let title = isTestVariant ? "Crok Desktop test app icon" : "Crok Desktop app icon"
let vectorTile = CGRect(x: vectorSide * tileInset, y: vectorSide * tileInset,
                        width: vectorSide * (1 - 2 * tileInset), height: vectorSide * (1 - 2 * tileInset))
let tileOutlineData = tileOutline(in: vectorTile, samples: 240).enumerated()
    .map { String(format: "%@%.2f %.2f", $0.offset == 0 ? "M" : "L", $0.element.x, $0.element.y) }.joined(separator: " ") + " Z"
let pill = CGRect(x: vectorSide * testPill.minX, y: vectorSide * testPill.minY, width: vectorSide * testPill.width, height: vectorSide * testPill.height)
let banner = isTestVariant ? """
  <rect x="\(pill.minX)" y="\(pill.minY)" width="\(pill.width)" height="\(pill.height)" rx="\(pill.height / 2)" fill="#260F05" fill-opacity="0.82"/>
  <text x="512" y="\(pill.midY)" fill="#fff" font-family="-apple-system, BlinkMacSystemFont, 'Helvetica Neue', sans-serif" font-size="70" font-weight="800" letter-spacing="4" text-anchor="middle" dominant-baseline="central">TESTING</text>
""" : ""
let svg = """
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">
  <title>\(title)</title>
  <defs>
    <linearGradient id="tile" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="\(hex(tileTop))"/>
      <stop offset="1" stop-color="\(hex(tileBottom))"/>
    </linearGradient>
    <filter id="shadow" x="-10%" y="-10%" width="120%" height="125%">
      <feDropShadow dx="0" dy="10" stdDeviation="11" flood-color="#000" flood-opacity="\(isTestVariant ? 0.28 : 0.4)"/>
    </filter>
    <clipPath id="tile-clip"><path d="\(tileOutlineData)"/></clipPath>
  </defs>
  <path d="\(tileOutlineData)" fill="url(#tile)" filter="url(#shadow)"/>
  <path d="\(tileOutlineData)" fill="none" stroke="#fff" stroke-opacity="\(isTestVariant ? 0.22 : 0.14)" stroke-width="5" clip-path="url(#tile-clip)"/>
  <g fill="#fff" transform="translate(\(vectorX) \(vectorY)) scale(\(vectorScale))">
\(paths)
  </g>
\(banner)</svg>
"""
try svg.write(to: outputBase.appendingPathExtension("svg"), atomically: true, encoding: .utf8)

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
    func path(in rect: CGRect) -> Path {
        var path = Path()
\(instructions.map { "        " + $0 }.joined(separator: "\n"))
        let scale = min(rect.width / \(viewBox.width), rect.height / \(viewBox.height))
        return path.applying(CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
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
print("Generated \(destination.path) from \(source.lastPathComponent) (16–1024 px), SVG, SwiftUI shape, and \(previewDestination.path).")
