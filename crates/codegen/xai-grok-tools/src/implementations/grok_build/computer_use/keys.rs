//! Key names to macOS virtual key codes (ANSI layout).
//!
//! Names follow xdotool, as models use them (`Return`, `BackSpace`, `Page_Down`, `super+c`), with
//! DOM spellings accepted too. A chord joins modifiers and one key with `+`; `key` may also be a
//! space-separated sequence of chords.

use crate::implementations::grok_build::device_use::Modifiers;

/// One key on the keyboard, and whether Shift must be held to type the character named.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Key {
    pub code: u16,
    pub shifted: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Chord {
    pub modifiers: Modifiers,
    pub key: Key,
}

pub const SHIFT: u16 = 56;
pub const CONTROL: u16 = 59;
pub const OPTION: u16 = 58;
pub const COMMAND: u16 = 55;
pub const RETURN: u16 = 36;
pub const TAB: u16 = 48;

/// CoreGraphics event flags for the modifiers a chord holds.
pub fn flags(modifiers: Modifiers, shifted: bool) -> u64 {
    const SHIFT_MASK: u64 = 0x0002_0000;
    const CONTROL_MASK: u64 = 0x0004_0000;
    const OPTION_MASK: u64 = 0x0008_0000;
    const COMMAND_MASK: u64 = 0x0010_0000;
    let mut bits = 0;
    if modifiers.shift || shifted {
        bits |= SHIFT_MASK;
    }
    if modifiers.ctrl {
        bits |= CONTROL_MASK;
    }
    if modifiers.alt {
        bits |= OPTION_MASK;
    }
    if modifiers.meta {
        bits |= COMMAND_MASK;
    }
    bits
}

pub fn parse_sequence(text: &str) -> Result<Vec<Chord>, String> {
    let chords: Vec<Chord> = text
        .split_whitespace()
        .map(parse_chord)
        .collect::<Result<_, _>>()?;
    if chords.is_empty() {
        return Err("`text` must name a key, such as \"Return\" or \"cmd+s\"".to_owned());
    }
    Ok(chords)
}

pub fn parse_chord(chord: &str) -> Result<Chord, String> {
    let (head, last) = match chord.strip_suffix("++") {
        Some(head) => (head, "+"),
        None => match chord.rsplit_once('+') {
            Some((head, last)) if !last.is_empty() => (head, last),
            _ => ("", chord),
        },
    };
    let mut modifiers = Modifiers::default();
    for part in head.split('+').filter(|part| !part.is_empty()) {
        if !modifiers.set(part) {
            return Err(format!("'{part}' in '{chord}' is not a modifier key"));
        }
    }
    let key = key(last).ok_or_else(|| format!("'{last}' is not a key on this keyboard"))?;
    Ok(Chord { modifiers, key })
}

fn plain(code: u16) -> Key {
    Key {
        code,
        shifted: false,
    }
}

fn shifted(code: u16) -> Key {
    Key {
        code,
        shifted: true,
    }
}

/// The key a name or a single character names.
pub fn key(name: &str) -> Option<Key> {
    let mut chars = name.chars();
    if let (Some(c), None) = (chars.next(), chars.next()) {
        return char_key(c);
    }
    let lower = name.to_ascii_lowercase();
    if let Some(n) = lower.strip_prefix('f').and_then(|n| n.parse::<u8>().ok()) {
        const F: [u16; 20] = [
            122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80,
            90,
        ];
        return F.get(usize::from(n).checked_sub(1)?).copied().map(plain);
    }
    Some(plain(match lower.as_str() {
        "return" | "enter" | "kp_enter" => RETURN,
        "tab" | "iso_left_tab" => TAB,
        "space" => 49,
        "backspace" => 51,
        "delete" | "del" => 117,
        "escape" | "esc" => 53,
        "up" | "arrowup" => 126,
        "down" | "arrowdown" => 125,
        "left" | "arrowleft" => 123,
        "right" | "arrowright" => 124,
        "home" => 115,
        "end" => 119,
        "page_up" | "pageup" | "prior" => 116,
        "page_down" | "pagedown" | "next" => 121,
        "help" | "insert" => 114,
        "shift" | "shift_l" | "shift_r" => SHIFT,
        "ctrl" | "control" | "control_l" | "control_r" => CONTROL,
        "alt" | "alt_l" | "alt_r" | "option" => OPTION,
        "super" | "super_l" | "super_r" | "cmd" | "command" | "meta" | "meta_l" | "win" => COMMAND,
        "caps_lock" | "capslock" => 57,
        "minus" => 27,
        "equal" => 24,
        "comma" => 43,
        "period" => 47,
        "slash" => 44,
        "backslash" => 42,
        "semicolon" => 41,
        "apostrophe" | "quote" => 39,
        "grave" => 50,
        "bracketleft" => 33,
        "bracketright" => 30,
        "plus" => return Some(shifted(24)),
        "volumeup" | "audioraisevolume" => 72,
        "volumedown" | "audiolowervolume" => 73,
        "mute" | "audiomute" => 74,
        _ => return None,
    }))
}

/// The key that types `c` on a US layout; `None` for characters typed as text.
pub fn char_key(c: char) -> Option<Key> {
    const LETTERS: [u16; 26] = [
        0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46, 45, 31, 35, 12, 15, 1, 17, 32, 9, 13, 7, 16,
        6,
    ];
    const DIGITS: [u16; 10] = [29, 18, 19, 20, 21, 23, 22, 26, 28, 25];
    Some(match c {
        'a'..='z' => plain(*LETTERS.get(usize::from(c as u8 - b'a'))?),
        'A'..='Z' => shifted(*LETTERS.get(usize::from(c as u8 - b'A'))?),
        '0'..='9' => plain(*DIGITS.get(usize::from(c as u8 - b'0'))?),
        ')' => shifted(29),
        '!' => shifted(18),
        '@' => shifted(19),
        '#' => shifted(20),
        '$' => shifted(21),
        '%' => shifted(23),
        '^' => shifted(22),
        '&' => shifted(26),
        '*' => shifted(28),
        '(' => shifted(25),
        ' ' => plain(49),
        '-' => plain(27),
        '_' => shifted(27),
        '=' => plain(24),
        '+' => shifted(24),
        '[' => plain(33),
        '{' => shifted(33),
        ']' => plain(30),
        '}' => shifted(30),
        '\\' => plain(42),
        '|' => shifted(42),
        ';' => plain(41),
        ':' => shifted(41),
        '\'' => plain(39),
        '"' => shifted(39),
        ',' => plain(43),
        '<' => shifted(43),
        '.' => plain(47),
        '>' => shifted(47),
        '/' => plain(44),
        '?' => shifted(44),
        '`' => plain(50),
        '~' => shifted(50),
        '\n' | '\r' => plain(RETURN),
        '\t' => plain(TAB),
        _ => return None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_map_to_ansi_key_codes() {
        assert_eq!(key("Return"), Some(plain(RETURN)));
        assert_eq!(key("BackSpace"), Some(plain(51)));
        assert_eq!(key("Page_Down"), Some(plain(121)));
        assert_eq!(key("F1"), Some(plain(122)));
        assert_eq!(key("f12"), Some(plain(111)));
        assert_eq!(key("a"), Some(plain(0)));
        assert_eq!(key("A"), Some(shifted(0)));
        assert_eq!(key("?"), Some(shifted(44)));
        assert!(key("Hyper").is_none());
        assert!(key("F25").is_none());
    }

    #[test]
    fn chords_set_the_right_flags() {
        let save = parse_chord("cmd+s").unwrap();
        assert_eq!(save.key, plain(1));
        assert_eq!(flags(save.modifiers, save.key.shifted), 0x0010_0000);
        let tab = parse_chord("alt+Tab").unwrap();
        assert!(tab.modifiers.alt);
        assert_eq!(parse_chord("ctrl++").unwrap().key, shifted(24));
        assert_eq!(parse_sequence("Down Down Return").unwrap().len(), 3);
        assert!(parse_chord("cmd+nope").is_err());
    }
}
