//! A `browser` or `computer` tool call, worded in the interface language each time it is drawn.

use xai_grok_i18n::{tl, tlf, tlm};

/// The call as the model made it (its `raw_input`), so its line follows the interface language.
#[derive(Debug, Clone, PartialEq)]
pub struct DeviceAction {
    /// The `computer` tool; the `browser` tool otherwise.
    pub computer: bool,
    pub input: serde_json::Value,
}

impl DeviceAction {
    /// The action of a `browser` or `computer` call, read from its `raw_input`.
    pub fn from_raw_input(raw: &serde_json::Value) -> Option<Self> {
        let computer = match raw.get("variant")?.as_str()? {
            "Browser" => false,
            "Computer" => true,
            _ => return None,
        };
        Some(Self {
            computer,
            input: raw.clone(),
        })
    }

    /// The tool's name, as the line starts.
    pub fn label(&self) -> &'static str {
        if self.computer {
            tl("Computer")
        } else {
            tl("Browser")
        }
    }

    pub fn action(&self) -> &str {
        self.str("action").unwrap_or("")
    }

    fn str(&self, key: &str) -> Option<&str> {
        self.input
            .get(key)
            .and_then(|v| v.as_str())
            .map(str::trim)
            .filter(|v| !v.is_empty())
    }

    fn point(&self, key: &str) -> Option<String> {
        let pair = self.input.get(key)?.as_array()?;
        let x = pair.first()?.as_f64()?.round() as i64;
        let y = pair.get(1)?.as_f64()?.round() as i64;
        Some(format!("({x}, {y})"))
    }

    /// What the call points at: an element reference, or a point in the screenshot.
    fn target(&self) -> Option<String> {
        self.str("ref")
            .map(str::to_owned)
            .or_else(|| self.point("coordinate"))
    }

    /// `with` naming the target when there is one; `without` otherwise.
    fn targeted(&self, with: &'static str, without: &'static str) -> String {
        match self.target() {
            Some(target) => tlf(with, &[("target", &target)]),
            None => tl(without).to_owned(),
        }
    }

    /// What the call does: `Click ref_3`, `Open https://example.com`.
    pub fn phrase(&self) -> String {
        let short = |text: &str, max: usize| match text.char_indices().nth(max) {
            Some((at, _)) => format!("{}…", &text[..at]),
            None => text.to_owned(),
        };
        let text = || short(&self.str("text").unwrap_or("").replace('\n', " "), 48);
        match self.action() {
            "navigate" => match self.str("url") {
                Some("back") => tl("Go back").to_owned(),
                Some("forward") => tl("Go forward").to_owned(),
                Some("reload") => tl("Reload page").to_owned(),
                Some(url) => tlf("Open {url}", &[("url", &short(url, 96))]),
                None => tl("Open a page").to_owned(),
            },
            "screenshot" => tl("Take a screenshot").to_owned(),
            "zoom" => tl("Zoom in").to_owned(),
            "left_click" => self.targeted(tlm("Click {target}"), tlm("Click")),
            "right_click" => self.targeted(tlm("Right-click {target}"), tlm("Right-click")),
            "middle_click" => self.targeted(tlm("Middle-click {target}"), tlm("Middle-click")),
            "double_click" => self.targeted(tlm("Double-click {target}"), tlm("Double-click")),
            "triple_click" => self.targeted(tlm("Triple-click {target}"), tlm("Triple-click")),
            "hover" => self.targeted(tlm("Hover over {target}"), tlm("Move the pointer")),
            "mouse_move" => {
                self.targeted(tlm("Move the pointer to {target}"), tlm("Move the pointer"))
            }
            "left_click_drag" => self.targeted(tlm("Drag to {target}"), tlm("Drag")),
            "left_mouse_down" => tl("Press the mouse button").to_owned(),
            "left_mouse_up" => tl("Release the mouse button").to_owned(),
            "scroll" => match self.str("scroll_direction") {
                Some("up") => tl("Scroll up").to_owned(),
                Some("down") => tl("Scroll down").to_owned(),
                Some("left") => tl("Scroll left").to_owned(),
                Some("right") => tl("Scroll right").to_owned(),
                _ => tl("Scroll the page").to_owned(),
            },
            "scroll_to" => self.targeted(tlm("Scroll to {target}"), tlm("Scroll the page")),
            "type" => tlf("Type “{text}”", &[("text", &text())]),
            "key" => tlf("Press {keys}", &[("keys", &text())]),
            "hold_key" => tlf("Hold {keys}", &[("keys", &text())]),
            "wait" => {
                let seconds = self
                    .input
                    .get("duration")
                    .and_then(|v| v.as_f64())
                    .map(|d| {
                        if d.fract() == 0.0 {
                            format!("{}", d as i64)
                        } else {
                            format!("{d}")
                        }
                    })
                    .unwrap_or_default();
                tlf("Wait {seconds} s", &[("seconds", &seconds)])
            }
            "read_page" => tl("Read the page").to_owned(),
            "find" => tlf(
                "Find “{query}”",
                &[("query", &short(self.str("query").unwrap_or(""), 48))],
            ),
            "get_page_text" => tl("Read the page text").to_owned(),
            "form_input" => self.targeted(tlm("Fill in {target}"), tlm("Fill in a field")),
            "file_upload" => tl("Upload files").to_owned(),
            "read_console" => tl("Read the console").to_owned(),
            "read_network" => tl("Read network requests").to_owned(),
            "javascript_exec" => tl("Run JavaScript").to_owned(),
            "new_tab" => tl("Open a new tab").to_owned(),
            "list_tabs" => tl("List tabs").to_owned(),
            "switch_tab" => tlf(
                "Switch to {tab}",
                &[("tab", &self.str("tab_id").unwrap_or(""))],
            ),
            "close_tab" => tlf("Close {tab}", &[("tab", &self.str("tab_id").unwrap_or(""))]),
            "cursor_position" => tl("Find the pointer").to_owned(),
            other => other.to_owned(),
        }
    }

    /// The tool and the action on one line, as a permission prompt names it: `Browser: Click ref_3`.
    pub fn title(&self) -> String {
        tlf(
            "{family}: {action}",
            &[("family", &self.label()), ("action", &self.phrase())],
        )
    }

    /// Lines a permission prompt shows under its title: what would be typed, run or uploaded.
    pub fn detail_lines(&self) -> Vec<String> {
        match self.action() {
            "type" | "javascript_exec" => self
                .input
                .get("text")
                .and_then(|v| v.as_str())
                .map(|text| text.lines().take(40).map(str::to_owned).collect())
                .unwrap_or_default(),
            "file_upload" => self
                .input
                .get("paths")
                .and_then(|v| v.as_array())
                .map(|paths| {
                    paths
                        .iter()
                        .filter_map(|p| p.as_str().map(str::to_owned))
                        .collect()
                })
                .unwrap_or_default(),
            _ => Vec::new(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn action(input: serde_json::Value) -> DeviceAction {
        DeviceAction::from_raw_input(&input).expect("a device call")
    }

    #[test]
    fn calls_are_worded_from_their_input() {
        let click = action(
            serde_json::json!({"variant": "Browser", "action": "left_click", "ref": "ref_3"}),
        );
        assert!(!click.computer);
        assert_eq!(click.phrase(), "Click ref_3");
        let at = action(
            serde_json::json!({"variant": "Computer", "action": "double_click", "coordinate": [640.4, 359.6]}),
        );
        assert!(at.computer);
        assert_eq!(at.phrase(), "Double-click (640, 360)");
        let pointer = action(serde_json::json!({"variant": "Computer", "action": "left_click"}));
        assert_eq!(pointer.phrase(), "Click");
        let open =
            action(serde_json::json!({"variant": "Browser", "action": "navigate", "url": "back"}));
        assert_eq!(open.phrase(), "Go back");
        let typed = action(
            serde_json::json!({"variant": "Computer", "action": "type", "text": "hello\nworld"}),
        );
        assert_eq!(typed.phrase(), "Type “hello world”");
        assert_eq!(typed.detail_lines(), vec!["hello", "world"]);
        assert_eq!(click.title(), "Browser: Click ref_3");
    }

    #[test]
    fn other_tools_are_not_device_calls() {
        assert!(
            DeviceAction::from_raw_input(&serde_json::json!({"variant": "WebFetch"})).is_none()
        );
        assert!(DeviceAction::from_raw_input(&serde_json::json!({})).is_none());
    }
}
