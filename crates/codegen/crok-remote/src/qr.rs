//! A QR code for the terminal, two modules per character cell, so a phone can open the sign-in link (or approve it
//! from the Crok app's "Link a computer").

use qrcode::{Color, QrCode};

const QUIET_ZONE: usize = 2;

/// The QR code for `data` as lines of text, dark modules on a light background. With `ansi`, the colours are set
/// explicitly (black on white) so the code scans on dark terminal themes too; without it, dark modules are drawn
/// with block characters and the background is left to the terminal.
pub fn render(data: &str, ansi: bool) -> Option<Vec<String>> {
    let code = QrCode::new(data.as_bytes()).ok()?;
    let width = code.width();
    let colors = code.to_colors();
    let size = width + 2 * QUIET_ZONE;
    let dark = |x: usize, y: usize| -> bool {
        if x < QUIET_ZONE || y < QUIET_ZONE || x >= width + QUIET_ZONE || y >= width + QUIET_ZONE {
            return false;
        }
        colors[(y - QUIET_ZONE) * width + (x - QUIET_ZONE)] == Color::Dark
    };
    let mut lines = Vec::with_capacity(size.div_ceil(2));
    for y in (0..size).step_by(2) {
        let mut line = String::new();
        if ansi {
            line.push_str("\x1b[38;5;16;48;5;231m");
        }
        for x in 0..size {
            let top = dark(x, y);
            let bottom = y + 1 < size && dark(x, y + 1);
            line.push(match (top, bottom) {
                (true, true) => '█',
                (true, false) => '▀',
                (false, true) => '▄',
                (false, false) => ' ',
            });
        }
        if ansi {
            line.push_str("\x1b[0m");
        }
        lines.push(line);
    }
    Some(lines)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn renders_a_square_block() {
        let lines = render("https://crok.example/link?code=BCDF-GHJK", false).unwrap();
        let width = lines[0].chars().count();
        assert!(width >= 21 + 2 * QUIET_ZONE);
        assert!(lines.iter().all(|l| l.chars().count() == width));
        assert_eq!(lines.len(), width.div_ceil(2));
        assert!(lines.iter().any(|l| l.contains('█')));
    }

    #[test]
    fn ansi_wraps_each_line() {
        let lines = render("x", true).unwrap();
        assert!(
            lines
                .iter()
                .all(|l| l.starts_with("\x1b[") && l.ends_with("\x1b[0m"))
        );
    }
}
