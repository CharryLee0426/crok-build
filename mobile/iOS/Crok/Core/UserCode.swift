import Foundation

/// The short code a device shows while it waits to be linked: `BCDF-GHJK`, eight letters from a consonant alphabet
/// (relay/convex/lib/crypto.ts). People type it in any case, with or without the dash, or scan it as a link.
enum UserCode {
    static let alphabet = Set("BCDFGHJKLMNPQRSTVWXZ")

    /// `bcdf ghjk`, `BCDFGHJK`, ` bcdf-ghjk ` → `BCDF-GHJK`. Nil unless exactly eight letters of the code alphabet.
    static func normalize(_ input: String) -> String? {
        let letters = input.uppercased().filter { $0.isASCII && $0.isLetter }
        guard letters.count == 8, letters.allSatisfy({ alphabet.contains($0) }) else { return nil }
        return "\(letters.prefix(4))-\(letters.suffix(4))"
    }

    /// What the QR code from `crok remote login` holds: a link like `https://…/link?code=BCDF-GHJK`, or just the code.
    static func fromScan(_ payload: String) -> String? {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        if let components = URLComponents(string: trimmed), components.scheme != nil,
            let code = components.queryItems?.first(where: { $0.name.lowercased() == "code" })?.value
        {
            return normalize(code)
        }
        return normalize(trimmed)
    }

    /// Formats partial typing as the person goes: letters only, upper case, a dash after the fourth.
    static func formatTyping(_ input: String) -> String {
        let letters = String(input.uppercased().filter { $0.isASCII && $0.isLetter }.prefix(8))
        guard letters.count > 4 else { return letters }
        return "\(letters.prefix(4))-\(letters.dropFirst(4))"
    }
}
