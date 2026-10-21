import SwiftMath
import SwiftUI
import UIKit

/// A formula drawn by SwiftMath, kept as a template image so it takes the colour of the text around it (and the cache
/// does not depend on light or dark).
final class RenderedMath {
    /// Nil when SwiftMath cannot handle the TeX; the source is shown instead.
    let image: UIImage?
    /// Distance from the image's bottom edge up to the formula's baseline.
    let baseline: CGFloat

    init(image: UIImage?, baseline: CGFloat) {
        self.image = image
        self.baseline = baseline
    }

    var width: CGFloat { image?.size.width ?? 0 }
}

@MainActor
enum MathRenderer {
    private static let inset: CGFloat = 1
    private static let cache: NSCache<NSString, RenderedMath> = {
        let cache = NSCache<NSString, RenderedMath>()
        cache.countLimit = 400
        return cache
    }()

    static func render(_ tex: String, display: Bool, fontSize: CGFloat) -> RenderedMath {
        let key = "\(display ? "D" : "I")\(fontSize)|\(tex)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        var math = MathImage(
            latex: tex, fontSize: fontSize, textColor: .black, labelMode: display ? .display : .text, textAlignment: .left)
        math.contentInsets = MTEdgeInsets(top: inset, left: inset, bottom: inset, right: inset)
        let (error, image, layout) = math.asImage()
        let rendered: RenderedMath
        if error == nil, let image, let layout, image.size.width > 2 * inset {
            // MathImage centres the formula in its (rounded-up) box and puts the baseline `descent` above its bottom.
            let height = max(layout.ascent + layout.descent, fontSize / 2)
            let baseline = (image.size.height - 2 * inset - height) / 2 + layout.descent + inset
            rendered = RenderedMath(image: image.withRenderingMode(.alwaysTemplate), baseline: baseline)
        } else {
            rendered = RenderedMath(image: nil, baseline: 0)
        }
        cache.setObject(rendered, forKey: key)
        return rendered
    }
}
