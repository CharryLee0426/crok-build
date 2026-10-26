import SwiftUI
import UIKit

/// Crok's semantic colours in one place (Telegram's PresentationTheme idea): screens ask for a role, never a hex
/// value, so light and dark stay consistent. Palette (relay/DESIGN.md §5 "Look"): Telegram blue accent `#3390EC` /
/// `#3E88F7` for links, buttons, switches, selection, unread badges, the Menu pill and ticks; the person's own bubbles
/// `#E1EFFD` / `#2B5278`; Crok Day `#EEEEEE`, Crok Night `#141414`. Online dots stay green.
enum Theme {
    private static func dynamic(_ light: UInt32, _ dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> Color {
        Color(
            UIColor { traits in
                traits.userInterfaceStyle == .dark ? UIColor(hex: dark, alpha: darkAlpha) : UIColor(hex: light, alpha: lightAlpha)
            })
    }

    static let accent = dynamic(0x3390EC, 0x3E88F7)
    /// Text and glyphs on an accent fill.
    static let onAccent = dynamic(0xFFFFFF, 0xFFFFFF)

    /// The transcript's background (Crok Day / Crok Night).
    static let canvas = dynamic(0xEEEEEE, 0x141414)
    /// Bubbles from the person: light blue with ordinary text, or deep blue with white text.
    static let userBubble = dynamic(0xE1EFFD, 0x2B5278)
    static let userBubbleText = dynamic(0x000000, 0xFFFFFF)
    /// Time and ticks on the person's bubbles: the accent, lightened on the dark bubble so it stays readable.
    static let userBubbleMeta = dynamic(0x3390EC, 0xA8CCF7)
    /// Bubbles from the agent.
    static let agentBubble = dynamic(0xFFFFFF, 0x222322)
    static let agentBubbleText = dynamic(0x1B1C1B, 0xE9EAE9)
    /// Tool cards and code blocks.
    static let card = dynamic(0xFFFFFF, 0x1D1E1D, lightAlpha: 0.75)

    /// A tool call's states and the reasoning effect, Crok Desktop's colours (mobile/DESIGN.md "Thinking and tool
    /// calls").
    static let toolDone = dynamic(0x3B7751, 0x91C5A1)
    static let toolFailed = dynamic(0xB3261E, 0xF2877E)
    static let toolRunning = dynamic(0x2868E8, 0x5FA8FF)
    static let thinkingColors: [Color] = [0x598CFF, 0x9E6BFF, 0xFA66B8, 0xFF9E52, 0xFA66B8, 0x9E6BFF, 0x598CFF]
        .map { Color(uiColor: UIColor(hex: $0)) }
    static let runningRimColors: [Color] = [0x3366FF, 0x1A9EFF, 0x47DBFA, 0x1A9EFF, 0x3366FF]
        .map { Color(uiColor: UIColor(hex: $0)) }
    static let codeBackground = dynamic(0xF0F2F0, 0x2F322F)
    static let hairline = dynamic(0x000000, 0xFFFFFF, lightAlpha: 0.08, darkAlpha: 0.10)
    /// Tables in replies: the grid lines and the header row's tint.
    static let tableBorder = dynamic(0x000000, 0xFFFFFF, lightAlpha: 0.14, darkAlpha: 0.16)
    static let tableHeader = dynamic(0xF0F2F0, 0x2F322F)

    /// Code highlighting, GitHub's colours (relay/DESIGN.md §5 "Replies in Markdown").
    static func syntax(_ token: CodeToken) -> Color {
        switch token {
        case .comment: syntaxComment
        case .keyword, .meta: syntaxKeyword
        case .string, .regex: syntaxString
        case .number, .literal, .property, .variable: syntaxNumber
        case .function, .section: syntaxFunction
        case .type, .builtin: syntaxType
        case .tag: syntaxTag
        case .inserted: syntaxInserted
        case .deleted: syntaxDeleted
        }
    }

    private static let syntaxComment = dynamic(0x6E7781, 0x8B949E)
    private static let syntaxKeyword = dynamic(0xCF222E, 0xFF7B72)
    private static let syntaxString = dynamic(0x0A3069, 0xA5D6FF)
    private static let syntaxNumber = dynamic(0x0550AE, 0x79C0FF)
    private static let syntaxFunction = dynamic(0x8250DF, 0xD2A8FF)
    private static let syntaxType = dynamic(0x953800, 0xFFA657)
    private static let syntaxTag = dynamic(0x116329, 0x7EE787)
    private static let syntaxInserted = dynamic(0x116329, 0xAFF5B4)
    private static let syntaxDeleted = dynamic(0x82071E, 0xFFDCD7)
    /// The faint row behind a diff's added and removed lines.
    static let diffInsertedBackground = dynamic(0xDAFBE1, 0x033A16)
    static let diffDeletedBackground = dynamic(0xFFEBE9, 0x67060C)
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
        dynamic(0x4B8BD6, 0x5E9BE0),  // blue
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

extension View {
    /// Liquid Glass on iOS 26 (`glassEffect`), a material on iOS 17–25: the composer, the command list, the
    /// scroll-to-bottom button and other controls floating over the transcript.
    @ViewBuilder
    func glassSurface<S: Shape>(in shape: S, interactive: Bool = false) -> some View {
        if #available(iOS 26, *) {
            glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
        }
    }
}

/// Whether this OS draws Liquid Glass (iOS 26 and later).
var hasLiquidGlass: Bool {
    if #available(iOS 26, *) { return true }
    return false
}

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
    }
}
