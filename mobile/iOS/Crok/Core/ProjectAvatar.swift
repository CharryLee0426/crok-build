import Foundation

/// The circular avatar of a session row: initials of the project folder on a colour picked from the folder name, so a
/// project keeps its colour everywhere (Telegram's peer avatars work the same way).
enum ProjectAvatar {
    /// `crok-build` → `CB`, `relay` → `R`, `my_app.ios` → `MA`.
    static func initials(forFolder folder: String) -> String {
        let words = folder
            .split(whereSeparator: { !($0.isLetter || $0.isNumber) })
            .filter { !$0.isEmpty }
        guard let first = words.first?.first else { return "·" }
        if words.count >= 2, let second = words[1].first {
            return String(first).uppercased() + String(second).uppercased()
        }
        return String(first).uppercased()
    }

    /// A stable index into the avatar palette (FNV-1a over the UTF-8 bytes; `hashValue` changes between launches).
    static func colorIndex(for key: String, paletteSize: Int) -> Int {
        guard paletteSize > 0 else { return 0 }
        var hash: UInt32 = 2_166_136_261
        for byte in key.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return Int(hash % UInt32(paletteSize))
    }
}
