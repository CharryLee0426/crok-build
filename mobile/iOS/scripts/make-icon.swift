#!/usr/bin/env swift
// Renders the Crok mark (desktop/macOS/Resources/GrokMark.svg, the labubu head traced to filled outlines) into the
// iOS asset catalog: the app icon (light, dark and tinted variants) and a vector PDF of the mark for in-app use.
//
//   swift mobile/iOS/scripts/make-icon.swift            # from the repository root
//
// The SVG keeps absolute M/L/C/Z commands only (see the comment in the SVG), so a tiny parser is enough.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
let iosRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let repoRoot = iosRoot.deletingLastPathComponent().deletingLastPathComponent()
let svgURL = repoRoot.appendingPathComponent("desktop/macOS/Resources/GrokMark.svg")
let assets = iosRoot.appendingPathComponent("Crok/Resources/Assets.xcassets")

// MARK: - SVG path

struct Mark {
    var width: CGFloat
    var height: CGFloat
    var path: CGPath
}

func loadMark() throws -> Mark {
    let svg = try String(contentsOf: svgURL, encoding: .utf8)
    guard let viewBoxRange = svg.range(of: #"viewBox="([^"]+)""#, options: .regularExpression) else {
        throw NSError(domain: "make-icon", code: 1, userInfo: [NSLocalizedDescriptionKey: "no viewBox"])
    }
    let viewBox = svg[viewBoxRange].dropFirst("viewBox=\"".count).dropLast()
    let box = viewBox.split(separator: " ").compactMap { Double($0) }
    let path = CGMutablePath()
    var cursor = svg.startIndex
    while let start = svg.range(of: " d=\"", range: cursor..<svg.endIndex) {
        guard let end = svg.range(of: "\"", range: start.upperBound..<svg.endIndex) else { break }
        appendPathData(String(svg[start.upperBound..<end.lowerBound]), to: path)
        cursor = end.upperBound
    }
    return Mark(width: CGFloat(box[2]), height: CGFloat(box[3]), path: path)
}

func appendPathData(_ data: String, to path: CGMutablePath) {
    var tokens: [String] = []
    var current = ""
    for ch in data {
        if ch.isLetter {
            if !current.isEmpty { tokens.append(current); current = "" }
            tokens.append(String(ch))
        } else if ch == " " || ch == "," || ch == "\n" || ch == "\t" {
            if !current.isEmpty { tokens.append(current); current = "" }
        } else if ch == "-" && !current.isEmpty && !current.hasSuffix("e") {
            tokens.append(current); current = "-"
        } else {
            current.append(ch)
        }
    }
    if !current.isEmpty { tokens.append(current) }
    var index = 0
    func number() -> CGFloat { defer { index += 1 }; return CGFloat(Double(tokens[index]) ?? 0) }
    var command = "M"
    while index < tokens.count {
        if let first = tokens[index].first, first.isLetter {
            command = tokens[index]
            index += 1
            if command == "Z" { path.closeSubpath(); continue }
        }
        switch command {
        case "M":
            path.move(to: CGPoint(x: number(), y: number()))
            command = "L"
        case "L":
            path.addLine(to: CGPoint(x: number(), y: number()))
        case "C":
            let c1 = CGPoint(x: number(), y: number())
            let c2 = CGPoint(x: number(), y: number())
            let to = CGPoint(x: number(), y: number())
            path.addCurve(to: to, control1: c1, control2: c2)
        default:
            index += 1
        }
    }
}

// MARK: - Drawing

func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// Draws the mark into `rect`, flipped from SVG (y down) to Core Graphics (y up), centred and aspect-fit.
func drawMark(_ mark: Mark, in ctx: CGContext, rect: CGRect, color: CGColor) {
    let scale = min(rect.width / mark.width, rect.height / mark.height)
    let w = mark.width * scale
    let h = mark.height * scale
    ctx.saveGState()
    ctx.translateBy(x: rect.midX - w / 2, y: rect.midY + h / 2)
    ctx.scaleBy(x: scale, y: -scale)
    ctx.addPath(mark.path)
    ctx.setFillColor(color)
    ctx.fillPath(using: .winding)
    ctx.restoreGState()
}

enum Variant { case light, dark, tinted }

func renderIcon(_ mark: Mark, variant: Variant, size: Int) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let full = CGRect(x: 0, y: 0, width: size, height: size)
    let s = CGFloat(size)
    switch variant {
    case .light:
        // Telegram blue (the app's accent, #3390EC), a touch lighter at the top, like light falling on a matte tile.
        let gradient = CGGradient(
            colorsSpace: space, colors: [rgb(0x4FA4F4), rgb(0x2A80DE)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: 0), options: [])
    case .dark:
        let gradient = CGGradient(
            colorsSpace: space, colors: [rgb(0x1D2330), rgb(0x111419)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: 0), options: [])
    case .tinted:
        ctx.clear(full)
    }
    let markColor: CGColor
    switch variant {
    case .light: markColor = rgb(0xFFFFFF)
    case .dark: markColor = rgb(0x3E88F7)
    case .tinted: markColor = rgb(0xFFFFFF)
    }
    // The head fills about 60% of the tile, nudged down a little so the ears balance the face.
    let markHeight = s * 0.60
    let rect = CGRect(x: 0, y: (s - markHeight) / 2 - s * 0.015, width: s, height: markHeight)
    drawMark(mark, in: ctx, rect: rect, color: markColor)
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw NSError(domain: "make-icon", code: 2)
    }
    CGImageDestinationAddImage(dest, image, nil)
    if !CGImageDestinationFinalize(dest) { throw NSError(domain: "make-icon", code: 3) }
}

func writeMarkPDF(_ mark: Mark, to url: URL) {
    var box = CGRect(x: 0, y: 0, width: mark.width / 8, height: mark.height / 8)
    let ctx = CGContext(url as CFURL, mediaBox: &box, nil)!
    ctx.beginPDFPage(nil)
    drawMark(mark, in: ctx, rect: box, color: rgb(0x000000))
    ctx.endPDFPage()
    ctx.closePDF()
}

func writeJSON(_ object: Any, to url: URL) throws {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: url)
}

// MARK: - Main

let mark = try loadMark()
let fm = FileManager.default

let iconSet = assets.appendingPathComponent("AppIcon.appiconset")
try fm.createDirectory(at: iconSet, withIntermediateDirectories: true)
try writePNG(renderIcon(mark, variant: .light, size: 1024), to: iconSet.appendingPathComponent("AppIcon-Light.png"))
try writePNG(renderIcon(mark, variant: .dark, size: 1024), to: iconSet.appendingPathComponent("AppIcon-Dark.png"))
try writePNG(renderIcon(mark, variant: .tinted, size: 1024), to: iconSet.appendingPathComponent("AppIcon-Tinted.png"))
try writeJSON(
    [
        "images": [
            ["filename": "AppIcon-Light.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"],
            [
                "appearances": [["appearance": "luminosity", "value": "dark"]],
                "filename": "AppIcon-Dark.png", "idiom": "universal", "platform": "ios", "size": "1024x1024",
            ],
            [
                "appearances": [["appearance": "luminosity", "value": "tinted"]],
                "filename": "AppIcon-Tinted.png", "idiom": "universal", "platform": "ios", "size": "1024x1024",
            ],
        ],
        "info": ["author": "xcode", "version": 1],
    ], to: iconSet.appendingPathComponent("Contents.json"))

let markSet = assets.appendingPathComponent("CrokMark.imageset")
try fm.createDirectory(at: markSet, withIntermediateDirectories: true)
writeMarkPDF(mark, to: markSet.appendingPathComponent("CrokMark.pdf"))
try writeJSON(
    [
        "images": [["filename": "CrokMark.pdf", "idiom": "universal"]],
        "info": ["author": "xcode", "version": 1],
        "properties": ["preserves-vector-representation": true, "template-rendering-intent": "template"],
    ], to: markSet.appendingPathComponent("Contents.json"))

print("Wrote \(iconSet.path) and \(markSet.path)")
