import ImageIO
import UIKit

/// The demo's photos and files (no network): drawn here and put in the attachment store under the storage ids the demo
/// transcript names, so bubbles, the viewer and Quick Look find them on the phone.
enum DemoMedia {
    static func url(_ storageId: String) -> String { "https://demo.crok.invalid/storage/\(storageId)" }

    /// The list preview of a prompt that is photos and files alone, as the computer writes it.
    static func preview(_ attachments: [Attachment]) -> String {
        guard let first = attachments.first else { return "" }
        let glyph = first.kind == .image ? "🖼" : "📎"
        return attachments.count > 1 ? "\(glyph) \(first.name) +\(attachments.count - 1)" : "\(glyph) \(first.name)"
    }

    static let mockupLight = "demo-mockup-light"
    static let mockupDark = "demo-mockup-dark"
    static let sketch = "demo-sketch"
    static let spec = "demo-settings-spec"

    static func thumbId(_ id: String) -> String { id + "-thumb" }

    /// The demo transcript's attachments, by storage id.
    static func attachment(_ id: String) -> Attachment {
        switch id {
        case mockupLight, mockupDark:
            return Attachment(
                storageId: id, thumbId: thumbId(id), name: id == mockupLight ? "settings-light.png" : "settings-dark.png",
                mimeType: "image/png", size: 412_000, kind: .image, width: 600, height: 1300, url: url(id),
                thumbUrl: url(thumbId(id)))
        case sketch:
            return Attachment(
                storageId: id, thumbId: thumbId(id), name: "photo-20261026-184212.jpg", mimeType: "image/jpeg",
                size: 238_000, kind: .image, width: 1200, height: 900, url: url(id), thumbUrl: url(thumbId(id)))
        default:
            return Attachment(
                storageId: id, name: "settings-spec.pdf", mimeType: "application/pdf", size: 86_000, kind: .file,
                url: url(id))
        }
    }

    /// Draws the demo files into the attachment store once.
    @MainActor
    static func seed(into store: AttachmentStore = .shared) {
        func keep(_ id: String, _ make: () -> UIImage) {
            guard !store.hasData(id) || !store.hasData(thumbId(id)) else { return }
            let image = make()
            if let data = image.pngData() { store.store(data, key: id) }
            if let source = image.jpegData(compressionQuality: 0.9).flatMap({ CGImageSourceCreateWithData($0 as CFData, nil) }),
                let thumb = ImagePreparer.makeThumbnail(source)
            {
                store.store(thumb, key: thumbId(id))
            }
        }
        keep(mockupLight) { mockup(dark: false) }
        keep(mockupDark) { mockup(dark: true) }
        keep(sketch) { sketchPhoto() }
        if !store.hasData(spec) { store.store(specPDF(), key: spec) }
    }

    /// Photos for the attach menu's demo item: JPEGs as a camera would make them, named like the phone names photos.
    static func photos(count: Int, at date: Date) -> [(data: Data, name: String)] {
        (0..<count).compactMap { index in
            let image = index % 2 == 0 ? sketchPhoto(hue: 0.58) : sketchPhoto(hue: 0.08)
            guard let data = image.jpegData(compressionQuality: 0.9) else { return nil }
            return (data, AttachmentText.photoName(at: date, index: index + 1))
        }
    }

    // MARK: Drawing

    private static func renderer(_ size: CGSize) -> UIGraphicsImageRenderer {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format)
    }

    /// A settings screen mockup, as a designer would export it.
    private static func mockup(dark: Bool) -> UIImage {
        let size = CGSize(width: 600, height: 1300)
        let background = dark ? UIColor(white: 0.08, alpha: 1) : UIColor(red: 0.95, green: 0.95, blue: 0.97, alpha: 1)
        let card = dark ? UIColor(white: 0.16, alpha: 1) : .white
        let text = dark ? UIColor.white : UIColor(white: 0.1, alpha: 1)
        let secondary = dark ? UIColor(white: 0.6, alpha: 1) : UIColor(white: 0.45, alpha: 1)
        let accent = UIColor(red: 0.2, green: 0.56, blue: 0.93, alpha: 1)
        return renderer(size).image { context in
            background.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let title: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 54, weight: .bold), .foregroundColor: text]
            ("Settings" as NSString).draw(at: CGPoint(x: 40, y: 120), withAttributes: title)
            let rowFont: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 30, weight: .regular), .foregroundColor: text]
            let rows = [["Appearance", "Session Theme", "Text Size"], ["Notifications", "Sounds"], ["Language", "About"]]
            var y: CGFloat = 230
            for (section, items) in rows.enumerated() {
                let height = CGFloat(items.count) * 96
                let rect = CGRect(x: 32, y: y, width: size.width - 64, height: height)
                card.setFill()
                UIBezierPath(roundedRect: rect, cornerRadius: 26).fill()
                for (index, item) in items.enumerated() {
                    let rowY = y + CGFloat(index) * 96
                    let icon = CGRect(x: 56, y: rowY + 26, width: 44, height: 44)
                    UIColor(hue: CGFloat(section * 3 + index) / 9, saturation: 0.6, brightness: 0.9, alpha: 1).setFill()
                    UIBezierPath(roundedRect: icon, cornerRadius: 11).fill()
                    (item as NSString).draw(at: CGPoint(x: 124, y: rowY + 28), withAttributes: rowFont)
                    if index == 0 && section < 2 {
                        let track = CGRect(x: rect.maxX - 120, y: rowY + 26, width: 84, height: 46)
                        (section == 0 ? accent : secondary.withAlphaComponent(0.4)).setFill()
                        UIBezierPath(roundedRect: track, cornerRadius: 23).fill()
                        UIColor.white.setFill()
                        let knob = CGRect(x: section == 0 ? track.maxX - 43 : track.minX + 3, y: track.minY + 3, width: 40, height: 40)
                        UIBezierPath(ovalIn: knob).fill()
                    } else {
                        let chevron: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 30, weight: .semibold), .foregroundColor: secondary]
                        ("›" as NSString).draw(at: CGPoint(x: rect.maxX - 52, y: rowY + 24), withAttributes: chevron)
                    }
                    if index < items.count - 1 {
                        secondary.withAlphaComponent(0.25).setFill()
                        context.fill(CGRect(x: 124, y: rowY + 95, width: rect.width - 110, height: 1))
                    }
                }
                y += height + 48
            }
        }
    }

    /// A photo of a whiteboard sketch: a toggle row drawn in marker.
    private static func sketchPhoto(hue: CGFloat = 0.12) -> UIImage {
        let size = CGSize(width: 1200, height: 900)
        return renderer(size).image { context in
            let colors = [UIColor(hue: hue, saturation: 0.18, brightness: 0.86, alpha: 1).cgColor,
                          UIColor(hue: hue, saturation: 0.28, brightness: 0.62, alpha: 1).cgColor]
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1]) {
                context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
            }
            let board = CGRect(x: 110, y: 90, width: 980, height: 700)
            UIColor(white: 0.98, alpha: 1).setFill()
            UIBezierPath(roundedRect: board, cornerRadius: 18).fill()
            let marker = UIColor(red: 0.12, green: 0.25, blue: 0.62, alpha: 1)
            marker.setStroke()
            let row = UIBezierPath(roundedRect: CGRect(x: 200, y: 300, width: 800, height: 150), cornerRadius: 30)
            row.lineWidth = 9
            row.stroke()
            let toggle = UIBezierPath(roundedRect: CGRect(x: 790, y: 335, width: 160, height: 80), cornerRadius: 40)
            toggle.lineWidth = 9
            toggle.stroke()
            marker.setFill()
            UIBezierPath(ovalIn: CGRect(x: 878, y: 345, width: 60, height: 60)).fill()
            let words: [NSAttributedString.Key: Any] = [
                .font: UIFont(name: "Noteworthy-Bold", size: 64) ?? UIFont.systemFont(ofSize: 64, weight: .bold),
                .foregroundColor: marker,
            ]
            ("Dark mode" as NSString).draw(at: CGPoint(x: 240, y: 335), withAttributes: words)
            ("follow system ↓" as NSString).draw(at: CGPoint(x: 260, y: 520), withAttributes: words)
            UIColor(red: 0.85, green: 0.2, blue: 0.2, alpha: 1).setStroke()
            let arrow = UIBezierPath()
            arrow.move(to: CGPoint(x: 700, y: 600))
            arrow.addQuadCurve(to: CGPoint(x: 860, y: 450), controlPoint: CGPoint(x: 850, y: 600))
            arrow.lineWidth = 8
            arrow.stroke()
        }
    }

    /// A one-page spec, as a PDF.
    private static func specPDF() -> Data {
        let page = CGRect(x: 0, y: 0, width: 612, height: 792)
        return UIGraphicsPDFRenderer(bounds: page).pdfData { context in
            context.beginPage()
            let title: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 26, weight: .bold)]
            ("Settings — dark mode spec" as NSString).draw(at: CGPoint(x: 56, y: 64), withAttributes: title)
            let body: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 14), .foregroundColor: UIColor.darkGray]
            let lines = [
                "1. Appearance gets a Dark Mode switch: Light, Dark, or Follow System (default).",
                "2. Rows keep 44 pt height; icons sit in 29 pt rounded squares.",
                "3. Dark backgrounds: #141414 page, #1F1F1F cards, #3E88F7 accent.",
                "4. The switch applies at once, without a restart.",
                "5. Session themes keep their own colours in both modes.",
            ]
            for (index, line) in lines.enumerated() {
                (line as NSString).draw(at: CGPoint(x: 56, y: 120 + CGFloat(index) * 28), withAttributes: body)
            }
        }
    }
}
