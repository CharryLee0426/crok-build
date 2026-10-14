//! What the `browser` and `computer` tools share.
//!
//! Both follow the contract of Anthropic's client toolsets (`browser_toolset_20260801` and
//! `computer_toolset_20260801`, driven by `anthropic.tools.browser` and `anthropic.tools.computer`
//! in the Python SDK): the same member names and inputs, the same acknowledgments after a pure
//! action, the same refusals, and the same batch rule. They are offered to every provider as
//! ordinary function tools, so any model with tool calling can use them.

pub mod screenshot;

use serde::{Deserialize, Serialize};

use crate::types::output::ImageContent;

/// Whether the `browser` and `computer` tools are offered, and how the browser is set up.
#[derive(Debug, Clone, Default)]
pub struct DeviceUseConfig {
    pub browser: crate::implementations::grok_build::browser_use::BrowserUseConfig,
    /// Offer the `computer` tool to the primary agent; only where it is supported (macOS).
    pub computer: bool,
}

/// What a browser call reads after an earlier call in the same response failed.
pub const BROWSER_HALT_TEXT: &str = "Not executed: an earlier action in this turn failed.";
/// What a computer call reads after an earlier computer call in the same response failed.
pub const COMPUTER_HALT_TEXT: &str =
    "Not executed: an earlier computer action in this turn failed.";

/// The longest text one result carries before it is cut, as the toolsets cap page reads.
pub const MAX_RESULT_CHARS: usize = 50_000;

/// One action's result: what the model reads, the image it sees, and what a client shows.
#[derive(Debug, Clone, Default, Serialize, Deserialize, schemars::JsonSchema)]
pub struct DeviceActionResult {
    /// The member the call named (`navigate`, `left_click`, …).
    pub action: String,
    /// What the model reads.
    pub text: String,
    /// A screenshot or zoomed region, already sized to fit model image limits.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub image: Option<ImageContent>,
    /// The call failed, was refused, or was skipped after an earlier failure.
    #[serde(default)]
    pub is_error: bool,
    /// The tab a browser call ran on, after it ran.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tab: Option<TabSummary>,
}

impl DeviceActionResult {
    pub fn ok(action: &str, text: impl Into<String>) -> Self {
        Self {
            action: action.to_owned(),
            text: text.into(),
            ..Self::default()
        }
    }

    pub fn error(action: &str, text: impl Into<String>) -> Self {
        Self {
            action: action.to_owned(),
            text: text.into(),
            is_error: true,
            ..Self::default()
        }
    }

    pub fn with_image(mut self, image: screenshot::FittedImage) -> Self {
        self.image = Some(image.into_content());
        self
    }

    /// The same result without image data, for `raw_output`: the image already travels as content.
    pub fn without_image_data(&self) -> Self {
        Self {
            image: None,
            ..self.clone()
        }
    }

    /// What the model reads, as content blocks: the text, then the image.
    pub fn content_blocks(&self) -> Vec<xai_tool_runtime::ContentBlock> {
        let mut blocks = vec![xai_tool_runtime::ContentBlock::Text {
            text: self.text.clone(),
        }];
        if let Some(image) = &self.image {
            blocks.push(xai_tool_runtime::ContentBlock::Image {
                mime_type: image.mime_type.clone(),
                data: image.data.clone(),
                media_id: None,
                filename: None,
                path: None,
                metadata: Default::default(),
            });
        }
        blocks
    }
}

/// A tab as a client shows it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
pub struct TabSummary {
    pub tab_id: String,
    pub title: String,
    pub url: String,
}

/// The batch rule: run a response's calls in order and stop at the first failure.
///
/// The shell dispatches one response's calls of a tool in order under one lock, and stamps each
/// with the response's [`ToolCallBatch`](crate::types::tool_call_origin::ToolCallBatch). A failed
/// call marks its batch, and every later call of the same batch is answered with the halt text
/// instead of running, because it was planned on the assumption that the earlier one worked.
#[derive(Debug, Default)]
pub struct BatchHalt {
    failed: parking_lot::Mutex<Option<u64>>,
}

impl BatchHalt {
    /// Whether a call of `batch` must be skipped.
    pub fn is_halted(&self, batch: Option<u64>) -> bool {
        batch.is_some() && *self.failed.lock() == batch
    }

    /// Record the outcome of a call of `batch`.
    pub fn record(&self, batch: Option<u64>, failed: bool) {
        if failed && batch.is_some() {
            *self.failed.lock() = batch;
        }
    }
}

/// `value` on one line: control characters and line or paragraph separators become spaces.
pub fn one_line(value: &str) -> String {
    value
        .chars()
        .map(|c| {
            if c.is_control() || c == '\u{2028}' || c == '\u{2029}' {
                ' '
            } else {
                c
            }
        })
        .collect::<String>()
        .trim()
        .to_owned()
}

/// At most `max` characters of `value`, with `…` when it was cut.
pub fn truncate_chars(value: &str, max: usize) -> String {
    match value.char_indices().nth(max) {
        Some((at, _)) => format!("{}…", &value[..at]),
        None => value.to_owned(),
    }
}

/// `text` cut to [`MAX_RESULT_CHARS`], saying so when it was, as the toolsets ask of a page read.
pub fn capped_result_text(text: String, narrower: &str) -> String {
    match text.char_indices().nth(MAX_RESULT_CHARS) {
        Some((at, _)) => format!(
            "{}\n\n[Output cut at {MAX_RESULT_CHARS} characters. {narrower}]",
            &text[..at]
        ),
        None if text.is_empty() => "(empty)".to_owned(),
        None => text,
    }
}

/// Modifier keys named in a `+`-joined chord such as `ctrl+shift`, in a canonical order.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Modifiers {
    pub shift: bool,
    pub ctrl: bool,
    pub alt: bool,
    pub meta: bool,
}

impl Modifiers {
    /// Parse a modifier chord; `None` names the first part that is not a modifier.
    pub fn parse(chord: Option<&str>) -> Result<Self, String> {
        let mut modifiers = Self::default();
        let Some(chord) = chord.map(str::trim).filter(|chord| !chord.is_empty()) else {
            return Ok(modifiers);
        };
        for part in chord
            .split('+')
            .map(str::trim)
            .filter(|part| !part.is_empty())
        {
            if !modifiers.set(part) {
                return Err(format!(
                    "'{part}' is not a modifier key; use shift, ctrl, alt or super (cmd), joined with '+'"
                ));
            }
        }
        Ok(modifiers)
    }

    /// Turn on the modifier `name` names; `false` when it names none.
    pub fn set(&mut self, name: &str) -> bool {
        match name.to_ascii_lowercase().as_str() {
            "shift" => self.shift = true,
            "ctrl" | "control" => self.ctrl = true,
            "alt" | "option" | "opt" => self.alt = true,
            "super" | "cmd" | "command" | "meta" | "win" | "windows" => self.meta = true,
            _ => return false,
        }
        true
    }

    pub fn is_empty(self) -> bool {
        self == Self::default()
    }
}

/// The input fields an acknowledgment template may name.
#[derive(Debug, Clone, Copy, Default)]
pub struct ConfirmationFields<'a> {
    pub scroll_direction: Option<&'a str>,
    pub text: Option<&'a str>,
    pub duration: Option<f64>,
    pub element_ref: Option<&'a str>,
}

/// Fill an acknowledgment such as `Scrolled {scroll_direction}.` in a single pass, so a value the
/// model wrote (`"{ref}"`) stays data and is never read again as a placeholder.
pub fn fill_confirmation(template: &str, fields: ConfirmationFields<'_>) -> String {
    let mut out = String::new();
    let mut rest = template;
    while let Some(start) = rest.find('{') {
        out.push_str(&rest[..start]);
        let Some(length) = rest[start..].find('}') else {
            break;
        };
        let value = match &rest[start + 1..start + length] {
            "scroll_direction" => fields.scroll_direction.unwrap_or("").to_owned(),
            "text" => one_line(fields.text.unwrap_or("")),
            "duration" => fields.duration.map(format_seconds).unwrap_or_default(),
            "ref" => one_line(fields.element_ref.unwrap_or("")),
            other => format!("{{{other}}}"),
        };
        out.push_str(&value);
        rest = &rest[start + length + 1..];
    }
    out.push_str(rest);
    out
}

/// Seconds as JSON spells a number: `2`, not `2.0`.
pub fn format_seconds(value: f64) -> String {
    if value.fract() == 0.0 && value.abs() < 1e15 {
        format!("{}", value as i64)
    } else {
        format!("{value}")
    }
}

/// Seconds for `wait` and `hold_key`, refused outside `0..=max` rather than moved into range.
pub fn checked_duration(action: &str, duration: Option<f64>, max: f64) -> Result<f64, String> {
    let Some(duration) = duration else {
        return Err(format!("{action} needs `duration` in seconds"));
    };
    if !duration.is_finite() || duration < 0.0 || duration > max {
        return Err(format!(
            "`duration` must be between 0 and {max} seconds, not {duration}"
        ));
    }
    Ok(duration)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn batch_halt_skips_only_the_failed_batch() {
        let halt = BatchHalt::default();
        assert!(!halt.is_halted(Some(1)));
        halt.record(Some(1), false);
        assert!(!halt.is_halted(Some(1)));
        halt.record(Some(1), true);
        assert!(halt.is_halted(Some(1)));
        assert!(!halt.is_halted(Some(2)), "a later response runs again");
        assert!(
            !halt.is_halted(None),
            "a call outside a batch is never skipped"
        );
    }

    #[test]
    fn modifiers_parse_chords_and_refuse_other_keys() {
        assert_eq!(
            Modifiers::parse(Some("ctrl+shift")).unwrap(),
            Modifiers {
                shift: true,
                ctrl: true,
                ..Modifiers::default()
            }
        );
        assert!(Modifiers::parse(Some("cmd")).unwrap().meta);
        assert!(Modifiers::parse(None).unwrap().is_empty());
        assert!(Modifiers::parse(Some("ctrl+a")).is_err());
    }

    #[test]
    fn capped_text_says_when_it_was_cut() {
        assert_eq!(capped_result_text(String::new(), "x"), "(empty)");
        let long = "a".repeat(MAX_RESULT_CHARS + 5);
        let capped = capped_result_text(long, "Read a smaller part.");
        assert!(capped.contains("Output cut at"));
        assert!(capped.ends_with("Read a smaller part.]"));
    }

    #[test]
    fn one_line_folds_controls() {
        assert_eq!(one_line(" a\nb\u{2028}c\t"), "a b c");
        assert_eq!(truncate_chars("abcdef", 3), "abc…");
        assert_eq!(truncate_chars("abc", 3), "abc");
    }

    #[test]
    fn confirmations_fill_their_fields_once() {
        let fields = ConfirmationFields {
            scroll_direction: Some("down"),
            text: Some("{ref}"),
            duration: Some(2.0),
            element_ref: Some("ref_4"),
        };
        assert_eq!(
            fill_confirmation("Scrolled {scroll_direction}.", fields),
            "Scrolled down."
        );
        assert_eq!(
            fill_confirmation("Pressed {text}.", fields),
            "Pressed {ref}."
        );
        assert_eq!(
            fill_confirmation("Held {text} for {duration}s.", fields),
            "Held {ref} for 2s."
        );
        assert_eq!(
            fill_confirmation("Set the value of {ref}.", fields),
            "Set the value of ref_4."
        );
        assert_eq!(format_seconds(1.5), "1.5");
    }

    #[test]
    fn durations_are_refused_not_clamped() {
        assert_eq!(checked_duration("wait", Some(2.0), 30.0), Ok(2.0));
        assert!(checked_duration("wait", Some(31.0), 30.0).is_err());
        assert!(checked_duration("wait", Some(-1.0), 30.0).is_err());
        assert!(checked_duration("wait", None, 30.0).is_err());
    }
}
