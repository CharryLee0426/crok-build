import SwiftUI
import UIKit

/// Telegram's topic glyph: a speech bubble (a circle with a short tail at the bottom left) in the topic's colour, with
/// the title's first letter (mobile/DESIGN.md "Topic icon").
struct TopicIconView: View {
    let sessionDocId: DocID
    let title: String
    var size: CGFloat = 40
    var dimmed = false

    var body: some View {
        let color = UIColor(hex: TopicIcon.colors[TopicIcon.colorIndex(for: sessionDocId)])
        ZStack {
            TopicBubbleShape()
                .fill(LinearGradient(
                    colors: [Color(uiColor: color.lightened(0.15)), Color(uiColor: color)],
                    startPoint: .top, endPoint: .bottom))
            Text(TopicIcon.letter(for: title))
                .font(.system(size: size * 0.44, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .minimumScaleFactor(0.5)
                .position(x: size * TopicBubbleShape.center.x, y: size * TopicBubbleShape.center.y)
        }
        .frame(width: size, height: size)
        .saturation(dimmed ? 0 : 1)
        .opacity(dimmed ? 0.55 : 1)
        .accessibilityHidden(true)
    }
}

/// Topic icons as images, to sit inside a line of text (the topics strip of a project row).
@MainActor
enum TopicIconImages {
    private static var cache: [String: UIImage] = [:]

    static func image(for sessionDocId: DocID, title: String, size: CGFloat, dimmed: Bool = false) -> UIImage {
        let key = "\(TopicIcon.colorIndex(for: sessionDocId))-\(TopicIcon.letter(for: title))-\(size)-\(dimmed)"
        if let cached = cache[key] { return cached }
        let renderer = ImageRenderer(
            content: TopicIconView(sessionDocId: sessionDocId, title: title, size: size, dimmed: dimmed))
        renderer.scale = 3
        let image = (renderer.uiImage ?? UIImage()).withRenderingMode(.alwaysOriginal)
        if cache.count > 400 { cache.removeAll() }
        cache[key] = image
        return image
    }
}

/// The topic bubble, in a square: the round body up and to the right, the tail at the bottom left.
struct TopicBubbleShape: Shape {
    static let center = CGPoint(x: 0.53, y: 0.47)
    static let radius: CGFloat = 0.44

    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height)
        let origin = CGPoint(x: rect.midX - s / 2, y: rect.midY - s / 2)
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: origin.x + x * s, y: origin.y + y * s) }
        let c = p(Self.center.x, Self.center.y)
        let r = Self.radius * s
        let body = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        var tail = Path()
        tail.move(to: p(0.17, 0.62))
        tail.addQuadCurve(to: p(0.05, 0.95), control: p(0.19, 0.86))
        tail.addQuadCurve(to: p(0.42, 0.87), control: p(0.27, 0.96))
        tail.closeSubpath()
        return body.union(tail)
    }
}

/// A computer's avatar (an account in the switcher): its initials on a colour keyed by the device, with the online
/// dot.
struct ComputerAvatarView: View {
    let computer: ComputerAccount
    var size: CGFloat = 32
    var showsOnline = true

    var body: some View {
        ZStack {
            Circle().fill(Theme.avatarColor(for: computer.id).gradient)
            Text(ProjectAvatar.initials(forFolder: computer.name))
                .font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .minimumScaleFactor(0.5)
        }
        .frame(width: size, height: size)
        .overlay(alignment: .bottomTrailing) {
            if showsOnline && computer.online {
                Circle()
                    .fill(Theme.online)
                    .frame(width: size * 0.3, height: size * 0.3)
                    .overlay(Circle().strokeBorder(Color(uiColor: .systemBackground), lineWidth: max(1.5, size * 0.06)))
                    .offset(x: size * 0.04, y: size * 0.04)
            }
        }
        .accessibilityHidden(true)
    }
}

/// UIKit images of the avatars, for places SwiftUI views cannot go: the tab bar item and the system context menus.
enum AvatarImages {
    /// A computer's avatar as a menu icon.
    static func computer(_ computer: ComputerAccount, size: CGFloat = 28) -> UIImage {
        let color = UIColor(Theme.avatarColor(for: computer.id)).resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        return initials(ProjectAvatar.initials(forFolder: computer.name), color: color, size: size)
    }

    static func initials(_ text: String, color: UIColor, size: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        return UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format).image { context in
            let rect = CGRect(x: 0, y: 0, width: size, height: size)
            let colors = [color.lightened(0.12).cgColor, color.cgColor] as CFArray
            context.cgContext.addEllipse(in: rect)
            context.cgContext.clip()
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size), options: [])
            }
            let font = UIFont.systemFont(ofSize: size * 0.4, weight: .semibold)
            let rounded = font.fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: 0) } ?? font
            let attributes: [NSAttributedString.Key: Any] = [.font: rounded, .foregroundColor: UIColor.white]
            let string = NSAttributedString(string: text, attributes: attributes)
            let bounds = string.size()
            string.draw(at: CGPoint(x: (size - bounds.width) / 2, y: (size - bounds.height) / 2))
        }.withRenderingMode(.alwaysOriginal)
    }

    /// The Profile tab's icon: the account picture (or initials) in a circle, ringed with the accent while selected.
    static func profileTab(picture: UIImage?, user: AccountUser, selected: Bool, size: CGFloat = 28) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        let accent = UIColor(Theme.accent).resolvedColor(with: UITraitCollection.current)
        let inner = selected ? size - 6 : size
        let face: UIImage =
            if let picture {
                UIGraphicsImageRenderer(size: CGSize(width: inner, height: inner), format: format).image { _ in
                    UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: inner, height: inner)).addClip()
                    picture.drawAspectFill(in: CGRect(x: 0, y: 0, width: inner, height: inner))
                }
            } else {
                initials(ProjectAvatar.initials(forFolder: user.name ?? user.email ?? "?"), color: accent, size: inner)
            }
        return UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format).image { _ in
            if selected {
                let ring = UIBezierPath(ovalIn: CGRect(x: 1, y: 1, width: size - 2, height: size - 2))
                ring.lineWidth = 2
                accent.setStroke()
                ring.stroke()
            }
            let offset = (size - inner) / 2
            face.draw(in: CGRect(x: offset, y: offset, width: inner, height: inner))
        }.withRenderingMode(.alwaysOriginal)
    }
}

/// The account picture as a `UIImage` (the Profile tab's icon cannot be an `AsyncImage`), kept in Caches so the tab
/// shows it at once on the next launch.
@MainActor
@Observable
final class AccountPicture {
    private(set) var image: UIImage?
    @ObservationIgnored private var loadedURL: String?
    @ObservationIgnored private var task: Task<Void, Never>?

    func load(_ urlString: String?) {
        guard urlString != loadedURL else { return }
        loadedURL = urlString
        task?.cancel()
        guard let urlString, let url = URL(string: urlString), url.scheme == "https" else {
            image = nil
            return
        }
        let file = Self.cacheFile(for: urlString)
        if let data = try? Data(contentsOf: file), let cached = UIImage(data: data) { image = cached }
        task = Task { [weak self] in
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                (response as? HTTPURLResponse)?.statusCode == 200, let picture = UIImage(data: data)
            else { return }
            guard !Task.isCancelled else { return }
            self?.image = picture
            try? FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
    }

    private static func cacheFile(for url: String) -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let name = "account-picture-\(ProjectAvatar.colorIndex(for: url, paletteSize: Int(Int32.max)))"
        return caches.appendingPathComponent("crok", isDirectory: true).appendingPathComponent(name)
    }
}

extension UIImage {
    /// Draws the image filling `rect`, cropped to keep its aspect ratio.
    func drawAspectFill(in rect: CGRect) {
        guard size.width > 0, size.height > 0 else { return }
        let scale = max(rect.width / size.width, rect.height / size.height)
        let drawn = CGSize(width: size.width * scale, height: size.height * scale)
        draw(in: CGRect(
            x: rect.midX - drawn.width / 2, y: rect.midY - drawn.height / 2, width: drawn.width, height: drawn.height))
    }
}

extension UIColor {
    /// The colour mixed with white by `amount` (0…1).
    func lightened(_ amount: CGFloat) -> UIColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard getRed(&r, green: &g, blue: &b, alpha: &a) else { return self }
        return UIColor(red: r + (1 - r) * amount, green: g + (1 - g) * amount, blue: b + (1 - b) * amount, alpha: a)
    }
}
