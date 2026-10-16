import SwiftUI
import UIKit

/// Crok's semantic colours in one place (Telegram's PresentationTheme idea): screens ask for a role, never a hex
/// value, so light and dark stay consistent. Palette: sage accent `#41634C` / `#A1BFA8`, Crok Day `#EEEEEE`,
/// Crok Night `#141414`.
enum Theme {
    private static func dynamic(_ light: UInt32, _ dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> Color {
        Color(
            UIColor { traits in
                traits.userInterfaceStyle == .dark ? UIColor(hex: dark, alpha: darkAlpha) : UIColor(hex: light, alpha: lightAlpha)
            })
    }

    static let accent = dynamic(0x41634C, 0xA1BFA8)
    /// Text and glyphs on an accent fill.
    static let onAccent = dynamic(0xFFFFFF, 0x10140F)

    /// The transcript's background (Crok Day / Crok Night).
    static let canvas = dynamic(0xEEEEEE, 0x141414)
    /// Bubbles from the person: an accent tint.
    static let userBubble = dynamic(0xD5E3D8, 0x2B3A2F)
    static let userBubbleText = dynamic(0x16231A, 0xE6EFE8)
    /// Bubbles from the agent.
    static let agentBubble = dynamic(0xFFFFFF, 0x222322)
    static let agentBubbleText = dynamic(0x1B1C1B, 0xE9EAE9)
    /// Tool cards and code blocks.
    static let card = dynamic(0xFFFFFF, 0x1D1E1D, lightAlpha: 0.75)
    static let codeBackground = dynamic(0xF0F2F0, 0x2F322F)
    static let hairline = dynamic(0x000000, 0xFFFFFF, lightAlpha: 0.08, darkAlpha: 0.10)
    /// System notices in the transcript.
    static let noticeBackground = dynamic(0x000000, 0xFFFFFF, lightAlpha: 0.07, darkAlpha: 0.09)
    static let noticeText = dynamic(0x55585A, 0xA9ACAE)

    static let secondaryText = Color.secondary
    static let online = dynamic(0x34A853, 0x4CD964)
    static let waiting = dynamic(0xC56A00, 0xFFA640)
    static let danger = Color.red
    static let unreadBadge = accent
    static let mutedBadge = dynamic(0x9A9EA3, 0x5C6064)

    /// Avatar colours, picked per project folder.
    static let avatarPalette: [Color] = [
        dynamic(0x5B8A6B, 0x6E9C7E),  // sage
        dynamic(0x5E7FB8, 0x7091C8),  // blue
        dynamic(0xB0705A, 0xC2826C),  // clay
        dynamic(0x8B6BB1, 0x9C7EC0),  // violet
        dynamic(0x3F8F95, 0x52A2A8),  // teal
        dynamic(0xB58A3A, 0xC69C4C),  // ochre
        dynamic(0xA0607E, 0xB37390),  // plum
    ]

    static func avatarColor(for key: String) -> Color {
        avatarPalette[ProjectAvatar.colorIndex(for: key, paletteSize: avatarPalette.count)]
    }
}

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
    }
}
