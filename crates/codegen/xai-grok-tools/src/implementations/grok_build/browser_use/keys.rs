//! Key names to DevTools key events.
//!
//! Models name keys the way xdotool does (`Return`, `BackSpace`, `ctrl+a`, `Page_Down`) or the way
//! the DOM does (`Enter`, `ArrowUp`). Both are accepted. A chord joins modifiers and one key with
//! `+`; `key` may also be a space-separated sequence of chords.

use crate::implementations::grok_build::device_use::Modifiers;

/// One key as the DOM describes it (US layout).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct KeyDef {
    pub key: String,
    pub code: &'static str,
    pub key_code: u32,
    /// The text the key inserts, when it inserts any.
    pub text: Option<String>,
    /// Shift must be held to produce `key` (an upper-case letter, `!`, `:`).
    pub shifted: bool,
    pub location: u8,
}

/// A chord: modifiers held around one key.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Chord {
    pub modifiers: Modifiers,
    pub key: KeyDef,
}

impl Chord {
    /// DevTools modifier bits: Alt 1, Control 2, Meta 4, Shift 8.
    pub fn cdp_modifiers(&self) -> u32 {
        let m = self.modifiers;
        let shift = m.shift || self.key.shifted;
        u32::from(m.alt)
            | (u32::from(m.ctrl) << 1)
            | (u32::from(m.meta) << 2)
            | (u32::from(shift) << 3)
    }

    /// Whether the key inserts its text: a modifier other than Shift turns it into a shortcut.
    pub fn inserts_text(&self) -> bool {
        self.key.text.is_some()
            && !(self.modifiers.ctrl || self.modifiers.alt || self.modifiers.meta)
    }

    /// The editing command a shortcut runs on macOS, where DevTools key events don't reach the
    /// menu shortcuts. `ctrl` counts as `cmd`: models trained on Linux reach for it.
    pub fn mac_editing_command(&self) -> Option<&'static str> {
        let m = self.modifiers;
        if !(m.meta || m.ctrl) || m.alt {
            return None;
        }
        match (self.key.code, m.shift) {
            ("KeyA", false) => Some("selectAll"),
            ("KeyC", false) => Some("copy"),
            ("KeyX", false) => Some("cut"),
            ("KeyV", false) => Some("paste"),
            ("KeyZ", false) => Some("undo"),
            ("KeyZ", true) | ("KeyY", false) => Some("redo"),
            _ => None,
        }
    }
}

/// Parse `key`'s text: chords separated by spaces.
pub fn parse_sequence(text: &str) -> Result<Vec<Chord>, String> {
    let chords: Vec<Chord> = text
        .split_whitespace()
        .map(parse_chord)
        .collect::<Result<_, _>>()?;
    if chords.is_empty() {
        return Err("`text` must name a key, such as \"Enter\" or \"ctrl+a\"".to_owned());
    }
    Ok(chords)
}

/// Parse one chord such as `ctrl+shift+Tab`, `Return` or `ctrl++`.
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
    // A bare modifier is a key of its own (`shift` pressed alone)
    let key = key_def(last).ok_or_else(|| format!("'{last}' is not a key the browser knows"))?;
    Ok(Chord { modifiers, key })
}

/// The key a name or a single character names.
pub fn key_def(name: &str) -> Option<KeyDef> {
    let mut chars = name.chars();
    if let (Some(c), None) = (chars.next(), chars.next()) {
        return char_def(c);
    }
    let canonical = match name.to_ascii_lowercase().as_str() {
        "return" | "enter" | "kp_enter" => "Enter",
        "tab" | "iso_left_tab" => "Tab",
        "backspace" => "Backspace",
        "delete" | "del" => "Delete",
        "escape" | "esc" => "Escape",
        "space" => " ",
        "up" | "arrowup" => "ArrowUp",
        "down" | "arrowdown" => "ArrowDown",
        "left" | "arrowleft" => "ArrowLeft",
        "right" | "arrowright" => "ArrowRight",
        "home" => "Home",
        "end" => "End",
        "page_up" | "pageup" | "prior" => "PageUp",
        "page_down" | "pagedown" | "next" => "PageDown",
        "insert" => "Insert",
        "shift" | "shift_l" | "shift_r" => "Shift",
        "ctrl" | "control" | "control_l" | "control_r" => "Control",
        "alt" | "alt_l" | "alt_r" | "option" => "Alt",
        "super" | "super_l" | "super_r" | "cmd" | "command" | "meta" | "meta_l" | "win" => "Meta",
        "minus" => "-",
        "plus" => "+",
        "equal" => "=",
        "comma" => ",",
        "period" => ".",
        "slash" => "/",
        "backslash" => "\\",
        "semicolon" => ";",
        "apostrophe" | "quote" => "'",
        "grave" => "`",
        "bracketleft" => "[",
        "bracketright" => "]",
        other => {
            if let Some(n) = other.strip_prefix('f').and_then(|n| n.parse::<u32>().ok())
                && (1..=12).contains(&n)
            {
                return Some(named(&format!("F{n}"), static_code_f(n), 111 + n, None));
            }
            return None;
        }
    };
    if canonical.chars().count() == 1 {
        return canonical.chars().next().and_then(char_def);
    }
    Some(match canonical {
        "Enter" => named("Enter", "Enter", 13, Some("\r")),
        "Tab" => named("Tab", "Tab", 9, None),
        "Backspace" => named("Backspace", "Backspace", 8, None),
        "Delete" => named("Delete", "Delete", 46, None),
        "Escape" => named("Escape", "Escape", 27, None),
        "ArrowUp" => named("ArrowUp", "ArrowUp", 38, None),
        "ArrowDown" => named("ArrowDown", "ArrowDown", 40, None),
        "ArrowLeft" => named("ArrowLeft", "ArrowLeft", 37, None),
        "ArrowRight" => named("ArrowRight", "ArrowRight", 39, None),
        "Home" => named("Home", "Home", 36, None),
        "End" => named("End", "End", 35, None),
        "PageUp" => named("PageUp", "PageUp", 33, None),
        "PageDown" => named("PageDown", "PageDown", 34, None),
        "Insert" => named("Insert", "Insert", 45, None),
        "Shift" => modifier("Shift", "ShiftLeft", 16),
        "Control" => modifier("Control", "ControlLeft", 17),
        "Alt" => modifier("Alt", "AltLeft", 18),
        "Meta" => modifier("Meta", "MetaLeft", 91),
        _ => return None,
    })
}

fn named(key: &str, code: &'static str, key_code: u32, text: Option<&str>) -> KeyDef {
    KeyDef {
        key: key.to_owned(),
        code,
        key_code,
        text: text.map(str::to_owned),
        shifted: false,
        location: 0,
    }
}

fn modifier(key: &str, code: &'static str, key_code: u32) -> KeyDef {
    KeyDef {
        location: 1,
        ..named(key, code, key_code, None)
    }
}

fn static_code_f(n: u32) -> &'static str {
    const CODES: [&str; 12] = [
        "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12",
    ];
    CODES
        .get((n as usize).saturating_sub(1))
        .copied()
        .unwrap_or("F12")
}

/// The key that types `c` on a US layout, or `None` for anything else (typed as inserted text).
pub fn char_def(c: char) -> Option<KeyDef> {
    const LETTER_CODES: [&str; 26] = [
        "KeyA", "KeyB", "KeyC", "KeyD", "KeyE", "KeyF", "KeyG", "KeyH", "KeyI", "KeyJ", "KeyK",
        "KeyL", "KeyM", "KeyN", "KeyO", "KeyP", "KeyQ", "KeyR", "KeyS", "KeyT", "KeyU", "KeyV",
        "KeyW", "KeyX", "KeyY", "KeyZ",
    ];
    const DIGIT_CODES: [&str; 10] = [
        "Digit0", "Digit1", "Digit2", "Digit3", "Digit4", "Digit5", "Digit6", "Digit7", "Digit8",
        "Digit9",
    ];
    let def = |code: &'static str, key_code: u32, shifted: bool| KeyDef {
        key: c.to_string(),
        code,
        key_code,
        text: Some(c.to_string()),
        shifted,
        location: 0,
    };
    Some(match c {
        'a'..='z' => def(
            LETTER_CODES.get(usize::from(c as u8 - b'a'))?,
            65 + u32::from(c as u8 - b'a'),
            false,
        ),
        'A'..='Z' => def(
            LETTER_CODES.get(usize::from(c as u8 - b'A'))?,
            65 + u32::from(c as u8 - b'A'),
            true,
        ),
        '0'..='9' => def(
            DIGIT_CODES.get(usize::from(c as u8 - b'0'))?,
            48 + u32::from(c as u8 - b'0'),
            false,
        ),
        ')' => def("Digit0", 48, true),
        '!' => def("Digit1", 49, true),
        '@' => def("Digit2", 50, true),
        '#' => def("Digit3", 51, true),
        '$' => def("Digit4", 52, true),
        '%' => def("Digit5", 53, true),
        '^' => def("Digit6", 54, true),
        '&' => def("Digit7", 55, true),
        '*' => def("Digit8", 56, true),
        '(' => def("Digit9", 57, true),
        ' ' => def("Space", 32, false),
        ';' => def("Semicolon", 186, false),
        ':' => def("Semicolon", 186, true),
        '=' => def("Equal", 187, false),
        '+' => def("Equal", 187, true),
        ',' => def("Comma", 188, false),
        '<' => def("Comma", 188, true),
        '-' => def("Minus", 189, false),
        '_' => def("Minus", 189, true),
        '.' => def("Period", 190, false),
        '>' => def("Period", 190, true),
        '/' => def("Slash", 191, false),
        '?' => def("Slash", 191, true),
        '`' => def("Backquote", 192, false),
        '~' => def("Backquote", 192, true),
        '[' => def("BracketLeft", 219, false),
        '{' => def("BracketLeft", 219, true),
        '\\' => def("Backslash", 220, false),
        '|' => def("Backslash", 220, true),
        ']' => def("BracketRight", 221, false),
        '}' => def("BracketRight", 221, true),
        '\'' => def("Quote", 222, false),
        '"' => def("Quote", 222, true),
        '\n' | '\r' => named("Enter", "Enter", 13, Some("\r")),
        '\t' => named("Tab", "Tab", 9, None),
        _ => return None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn xdotool_and_dom_names_agree() {
        assert_eq!(key_def("Return"), key_def("Enter"));
        assert_eq!(key_def("BackSpace").unwrap().code, "Backspace");
        assert_eq!(key_def("Page_Down").unwrap().key, "PageDown");
        assert_eq!(key_def("Up").unwrap().code, "ArrowUp");
        assert_eq!(key_def("f5").unwrap().key_code, 116);
        assert_eq!(key_def("space").unwrap().code, "Space");
        assert!(key_def("Hyper").is_none());
    }

    #[test]
    fn chords_carry_modifiers_and_commands() {
        let chord = parse_chord("ctrl+a").unwrap();
        assert!(chord.modifiers.ctrl);
        assert_eq!(chord.cdp_modifiers(), 2);
        assert!(!chord.inserts_text());
        assert_eq!(chord.mac_editing_command(), Some("selectAll"));
        let redo = parse_chord("cmd+shift+z").unwrap();
        assert_eq!(redo.mac_editing_command(), Some("redo"));
        let plus = parse_chord("ctrl++").unwrap();
        assert_eq!(plus.key.key, "+");
        let upper = parse_chord("A").unwrap();
        assert_eq!(upper.cdp_modifiers(), 8, "an upper-case letter holds shift");
        assert!(upper.inserts_text());
        assert!(parse_chord("hyper+a").is_err());
    }

    #[test]
    fn sequences_split_on_spaces() {
        let keys = parse_sequence("Backspace Backspace ctrl+s").unwrap();
        assert_eq!(keys.len(), 3);
        assert!(keys[2].modifiers.ctrl);
        assert!(parse_sequence("   ").is_err());
    }
}
