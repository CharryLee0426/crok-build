//! Text on a phone's screen, with where it is, and how the model reads it.

use crate::implementations::grok_build::device_use::screenshot::Scale;
use crate::implementations::grok_build::device_use::{one_line, truncate_chars};

/// Where a piece of text came from.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Source {
    /// The phone's accessibility tree: exact.
    Tree,
    /// Recognized in the screen's pixels: may misread.
    Pixels,
}

/// One visible text, or one labeled element, in the phone's own units (Android: device pixels;
/// iPhone: points of the mirroring window, from its top-left corner).
#[derive(Debug, Clone, PartialEq)]
pub struct TextBox {
    pub text: String,
    /// The centre.
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
    pub source: Source,
    /// Recognition confidence, 1 for the tree.
    pub confidence: f32,
    /// Android: the element takes taps.
    pub clickable: bool,
    /// Android: the element's resource id without its package, for elements with no text.
    pub id: Option<String>,
}

impl TextBox {
    pub fn pixels(text: String, confidence: f32, x: f64, y: f64, width: f64, height: f64) -> Self {
        Self {
            text,
            x,
            y,
            width,
            height,
            source: Source::Pixels,
            confidence,
            clickable: false,
            id: None,
        }
    }

    /// The name a match is made against: the text, or the id of an element that has none.
    fn name(&self) -> &str {
        if self.text.is_empty() {
            self.id.as_deref().unwrap_or("")
        } else {
            &self.text
        }
    }
}

/// The boxes whose text matches `query`: a case-insensitive part of it, or all of it with `exact`.
/// Exact matches come first even when `exact` is off, so "Wi-Fi" picks the row titled that before
/// a sentence that mentions it.
pub fn find<'a>(boxes: &'a [TextBox], query: &str, exact: bool) -> Vec<&'a TextBox> {
    let query = normalize(query);
    if query.is_empty() {
        return Vec::new();
    }
    let mut whole: Vec<&TextBox> = Vec::new();
    let mut part: Vec<&TextBox> = Vec::new();
    for b in boxes {
        let name = normalize(b.name());
        if name == query {
            whole.push(b);
        } else if !exact && name.contains(&query) {
            part.push(b);
        }
    }
    whole.extend(part);
    whole
}

fn normalize(text: &str) -> String {
    one_line(text)
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .to_lowercase()
}

/// The error a text target reads when nothing matches: what is visible instead.
pub fn no_match(query: &str, boxes: &[TextBox]) -> String {
    let visible: Vec<String> = boxes
        .iter()
        .map(|b| b.name())
        .filter(|name| !name.trim().is_empty())
        .take(40)
        .map(|name| format!("\"{}\"", truncate_chars(&one_line(name), 40)))
        .collect();
    if visible.is_empty() {
        format!(
            "No visible text matches \"{}\", and no text was found on the screen. Take a screenshot to see it.",
            one_line(query)
        )
    } else {
        format!(
            "No visible text matches \"{}\". Visible: {}",
            one_line(query),
            visible.join(", ")
        )
    }
}

/// The boxes as the model reads them, one per line, with centres in screenshot pixels.
pub fn describe(boxes: &[TextBox], scale: &Scale) -> String {
    let mut lines = Vec::with_capacity(boxes.len());
    for b in boxes {
        let (x, y) = scale.to_image(b.x, b.y);
        let mut line = if b.text.is_empty() {
            match &b.id {
                Some(id) => format!("[{id}] ({x}, {y})"),
                None => continue,
            }
        } else {
            format!(
                "\"{}\" ({x}, {y})",
                truncate_chars(&one_line(&b.text).replace('"', "'"), 200)
            )
        };
        if b.clickable {
            line.push_str(" clickable");
        }
        if b.source == Source::Pixels && b.confidence < 0.5 {
            line.push_str(" (unsure)");
        }
        lines.push(line);
    }
    lines.join("\n")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn b(text: &str, x: f64, y: f64) -> TextBox {
        TextBox::pixels(text.into(), 0.9, x, y, 10.0, 10.0)
    }

    #[test]
    fn exact_matches_come_before_parts() {
        let boxes = vec![
            b("Turn on Wi-Fi to continue", 1.0, 1.0),
            b("Wi-Fi", 2.0, 2.0),
        ];
        let hits = find(&boxes, "wi-fi", false);
        assert_eq!(hits.len(), 2);
        assert_eq!(hits[0].text, "Wi-Fi");
        assert_eq!(find(&boxes, "wi-fi", true).len(), 1);
        assert!(find(&boxes, "  ", false).is_empty());
    }

    #[test]
    fn elements_without_text_match_by_id() {
        let mut url = b("", 5.0, 5.0);
        url.id = Some("url_bar".into());
        url.clickable = true;
        let boxes = vec![url];
        assert_eq!(find(&boxes, "url_bar", true).len(), 1);
        let scale = Scale::for_source(100.0, 100.0);
        assert_eq!(describe(&boxes, &scale), "[url_bar] (5, 5) clickable");
    }

    #[test]
    fn no_match_lists_what_is_visible() {
        let boxes = vec![b("Settings", 1.0, 1.0), b("Mail", 2.0, 2.0)];
        let text = no_match("Weather", &boxes);
        assert!(text.contains("\"Settings\", \"Mail\""), "{text}");
        assert!(no_match("x", &[]).contains("Take a screenshot"));
    }

    #[test]
    fn descriptions_are_in_screenshot_pixels() {
        let scale = Scale {
            source_width: 300.0,
            source_height: 600.0,
            image_width: 600,
            image_height: 1200,
        };
        let mut low = b("Maybe", 150.0, 300.0);
        low.confidence = 0.3;
        assert_eq!(describe(&[low], &scale), "\"Maybe\" (300, 600) (unsure)");
    }
}
