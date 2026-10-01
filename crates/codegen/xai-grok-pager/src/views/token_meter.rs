//! Token readout for the status bar: `↑1.2M ↓45K`, `83% cached`, `61 tok/s`, each its own item beside the context meter.
//!
//! Figures are a step brighter than their arrows and units, so the row scans as numbers.
//! A rate estimated from a stream still in flight is marked `~`; the shell's measured figure replaces it.

use ratatui::style::Style;
use ratatui::text::{Line, Span};

use super::context_bar::fmt_tokens;
use crate::app::token_meter::{TokenRate, TokenReadout};
use crate::theme::Theme;

/// Both are in CP437, so legacy ConHost draws them too.
const INPUT_ARROW: &str = "\u{2191}";
const OUTPUT_ARROW: &str = "\u{2193}";

/// A rate past this is a burst over a short window, not a speed worth four more columns.
const MAX_DISPLAYED_RATE: f64 = 9_999.0;

/// `8.4` under ten tokens a second, where the tenth is the signal; whole numbers above.
pub(crate) fn fmt_rate(tokens_per_sec: f64) -> String {
    let rate = tokens_per_sec.clamp(0.0, MAX_DISPLAYED_RATE);
    if rate < 9.95 {
        format!("{rate:.1}")
    } else {
        format!("{rate:.0}")
    }
}

/// A run of an item's text: a number, or the arrow or unit that says what it counts.
enum Part {
    Figure(String),
    Unit(String),
}

/// One status-bar item of the readout. The id names it for hit-testing and is unique in the bar.
pub(crate) struct TokenMeterItem {
    pub(crate) id: &'static str,
    parts: Vec<Part>,
}

impl TokenMeterItem {
    /// The item as the full view draws it.
    pub(crate) fn line(&self, theme: &Theme) -> Line<'static> {
        let figure = Style::default().fg(theme.gray).bg(theme.bg_base);
        let unit = theme.dim().bg(theme.bg_base);
        Line::from(
            self.parts
                .iter()
                .map(|part| match part {
                    Part::Figure(text) => Span::styled(text.clone(), figure),
                    Part::Unit(text) => Span::styled(text.clone(), unit),
                })
                .collect::<Vec<_>>(),
        )
    }

    /// The item unstyled, for minimal mode's one-colour row.
    pub(crate) fn text(&self) -> String {
        self.parts
            .iter()
            .map(|part| match part {
                Part::Figure(text) | Part::Unit(text) => text.as_str(),
            })
            .collect()
    }
}

/// The readout's items, most wanted first, so a narrow row keeps the counts and drops the rate.
pub(crate) fn token_meter_items(readout: &TokenReadout) -> Vec<TokenMeterItem> {
    let mut items = vec![TokenMeterItem {
        id: "tokens",
        parts: vec![
            Part::Unit(INPUT_ARROW.into()),
            Part::Figure(fmt_tokens(readout.input_tokens)),
            Part::Unit(format!(" {OUTPUT_ARROW}")),
            Part::Figure(fmt_tokens(readout.output_tokens)),
        ],
    }];
    if let Some(pct) = readout.cache_hit_pct {
        items.push(TokenMeterItem {
            id: "cache_hit",
            parts: vec![
                Part::Figure(format!("{pct:.0}%")),
                Part::Unit(" cached".into()),
            ],
        });
    }
    if let Some(rate) = readout.rate {
        let estimated = match rate {
            TokenRate::Estimated(_) => "~",
            TokenRate::Measured(_) => "",
        };
        items.push(TokenMeterItem {
            id: "token_rate",
            parts: vec![
                Part::Figure(format!("{estimated}{}", fmt_rate(rate.tokens_per_sec()))),
                Part::Unit(" tok/s".into()),
            ],
        });
    }
    items
}

#[cfg(test)]
mod tests {
    use super::*;

    fn texts(readout: &TokenReadout) -> Vec<(&'static str, String)> {
        token_meter_items(readout)
            .iter()
            .map(|item| (item.id, item.text()))
            .collect()
    }

    #[test]
    fn a_full_readout_is_three_items_in_priority_order() {
        let readout = TokenReadout {
            input_tokens: 1_234_567,
            output_tokens: 45_300,
            cache_hit_pct: Some(83.4),
            rate: Some(TokenRate::Measured(61.2)),
        };
        assert_eq!(
            texts(&readout),
            vec![
                ("tokens", "↑1.2M ↓45K".to_string()),
                ("cache_hit", "83% cached".to_string()),
                ("token_rate", "61 tok/s".to_string()),
            ]
        );
    }

    #[test]
    fn an_estimated_rate_is_marked() {
        let readout = TokenReadout {
            input_tokens: 0,
            output_tokens: 12,
            cache_hit_pct: None,
            rate: Some(TokenRate::Estimated(8.44)),
        };
        assert_eq!(
            texts(&readout),
            vec![
                ("tokens", "↑0 ↓12".to_string()),
                ("token_rate", "~8.4 tok/s".to_string()),
            ]
        );
    }

    #[test]
    fn the_styled_line_reads_the_same_as_the_plain_text() {
        let readout = TokenReadout {
            input_tokens: 2_000,
            output_tokens: 120,
            cache_hit_pct: Some(75.0),
            rate: Some(TokenRate::Measured(12.0)),
        };
        let theme = Theme::default();
        for item in token_meter_items(&readout) {
            let line = item.line(&theme);
            let drawn: String = line.spans.iter().map(|s| s.content.as_ref()).collect();
            assert_eq!(drawn, item.text());
            // Figures and units differ, or the row would not scan as numbers.
            let styles: std::collections::HashSet<_> =
                line.spans.iter().map(|s| s.style.fg).collect();
            assert_eq!(styles.len(), 2, "{drawn:?}");
        }
    }

    #[test]
    fn rate_keeps_a_tenth_only_below_ten() {
        assert_eq!(fmt_rate(0.0), "0.0");
        assert_eq!(fmt_rate(9.94), "9.9");
        // Rounds to a whole number rather than to `10.0`.
        assert_eq!(fmt_rate(9.96), "10");
        assert_eq!(fmt_rate(142.6), "143");
        assert_eq!(fmt_rate(1e9), "9999");
        assert_eq!(fmt_rate(-3.0), "0.0");
    }
}
