//! A `browser`, `computer` or `phone` tool call, worded in the interface language each time it is drawn.

use xai_grok_i18n::{tl, tlf, tlm};

/// Which tool made a call.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DeviceFamily {
    Browser,
    Computer,
    Phone,
}

/// The call as the model made it (its `raw_input`), so its line follows the interface language.
#[derive(Debug, Clone, PartialEq)]
pub struct DeviceAction {
    pub family: DeviceFamily,
    pub input: serde_json::Value,
}

impl DeviceAction {
    /// The action of a `browser`, `computer` or `phone` call, read from its `raw_input`.
    pub fn from_raw_input(raw: &serde_json::Value) -> Option<Self> {
        let family = match raw.get("variant")?.as_str()? {
            "Browser" => DeviceFamily::Browser,
            "Computer" => DeviceFamily::Computer,
            "Phone" => DeviceFamily::Phone,
            _ => return None,
        };
        Some(Self {
            family,
            input: raw.clone(),
        })
    }

    /// The tool's name, as the line starts. A phone call that names its phone says which.
    pub fn label(&self) -> &'static str {
        match self.family {
            DeviceFamily::Computer => tl("Computer"),
            DeviceFamily::Browser => tl("Browser"),
            DeviceFamily::Phone => match self.str("device") {
                Some("iphone") => "iPhone",
                Some("android") => "Android",
                _ => tl("Phone"),
            },
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

    /// What the call points at: an element reference, a point in the screenshot, or (on a phone)
    /// the visible text it touches.
    fn target(&self) -> Option<String> {
        self.str("ref")
            .map(str::to_owned)
            .or_else(|| self.point("coordinate"))
            .or_else(|| {
                (self.family == DeviceFamily::Phone)
                    .then(|| self.str("text"))
                    .flatten()
                    .map(|text| format!("“{}”", short(&text.replace('\n', " "), 48)))
            })
    }

    /// `with` naming the target when there is one; `without` otherwise.
    fn targeted(&self, with: &'static str, without: &'static str) -> String {
        match self.target() {
            Some(target) => tlf(with, &[("target", &target)]),
            None => tl(without).to_owned(),
        }
    }

    /// What a phone call does: `Tap “Weather”`, `Open Settings`.
    fn phone_phrase(&self) -> Option<String> {
        let text = || short(&self.str("text").unwrap_or("").replace('\n', " "), 48);
        Some(match self.action() {
            "status" => tl("Check the phone connection").to_owned(),
            "connect" => tl("Connect the phone").to_owned(),
            "read_screen" => tl("Read the screen").to_owned(),
            "tap" => self.targeted(tlm("Tap {target}"), tlm("Tap")),
            "long_press" => self.targeted(tlm("Long-press {target}"), tlm("Long-press")),
            "swipe" => match self.str("direction") {
                Some("up") => tl("Swipe up").to_owned(),
                Some("down") => tl("Swipe down").to_owned(),
                Some("left") => tl("Swipe left").to_owned(),
                Some("right") => tl("Swipe right").to_owned(),
                _ => tl("Swipe").to_owned(),
            },
            "scroll" => match self.str("direction") {
                Some("up") => tl("Scroll up").to_owned(),
                Some("down") => tl("Scroll down").to_owned(),
                Some("left") => tl("Scroll left").to_owned(),
                Some("right") => tl("Scroll right").to_owned(),
                _ => tl("Scroll the screen").to_owned(),
            },
            "drag" => self.targeted(tlm("Drag to {target}"), tlm("Drag")),
            "home" => tl("Go to the Home Screen").to_owned(),
            "back" => tl("Go back").to_owned(),
            "app_switcher" => tl("Open the app switcher").to_owned(),
            "open_app" => tlf("Open {app}", &[("app", &text())]),
            "list_apps" => tl("List apps").to_owned(),
            // The pairing code is the user's to read out, not a line to keep
            "pair_android" => tl("Pair an Android phone").to_owned(),
            _ => return None,
        })
    }

    /// What the call does: `Click ref_3`, `Open https://example.com`.
    pub fn phrase(&self) -> String {
        if self.family == DeviceFamily::Phone
            && let Some(phrase) = self.phone_phrase()
        {
            return phrase;
        }
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
        if self.family == DeviceFamily::Phone && self.action() == "pair_android" {
            return Vec::new();
        }
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

/// At most `max` characters of `text`, with `…` when it was cut.
fn short(text: &str, max: usize) -> String {
    match text.char_indices().nth(max) {
        Some((at, _)) => format!("{}…", &text[..at]),
        None => text.to_owned(),
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
        assert_eq!(click.family, DeviceFamily::Browser);
        assert_eq!(click.phrase(), "Click ref_3");
        let at = action(
            serde_json::json!({"variant": "Computer", "action": "double_click", "coordinate": [640.4, 359.6]}),
        );
        assert_eq!(at.family, DeviceFamily::Computer);
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
    fn phone_calls_name_their_phone_and_target() {
        let tap =
            action(serde_json::json!({"variant": "Phone", "action": "tap", "text": "Weather"}));
        assert_eq!(tap.family, DeviceFamily::Phone);
        assert_eq!(tap.title(), "Phone: Tap “Weather”");
        let at = action(
            serde_json::json!({"variant": "Phone", "device": "iphone", "action": "tap", "coordinate": [120.2, 399.7]}),
        );
        assert_eq!(at.title(), "iPhone: Tap (120, 400)");
        let scroll = action(
            serde_json::json!({"variant": "Phone", "device": "android", "action": "scroll", "direction": "down"}),
        );
        assert_eq!(scroll.title(), "Android: Scroll down");
        let open = action(
            serde_json::json!({"variant": "Phone", "action": "open_app", "text": "Settings"}),
        );
        assert_eq!(open.phrase(), "Open Settings");
        let pair = action(
            serde_json::json!({"variant": "Phone", "action": "pair_android", "text": "123456"}),
        );
        assert_eq!(pair.phrase(), "Pair an Android phone");
        assert!(
            pair.detail_lines().is_empty(),
            "the pairing code is not shown"
        );
        let typed =
            action(serde_json::json!({"variant": "Phone", "action": "type", "text": "hi\nthere"}));
        assert_eq!(typed.phrase(), "Type “hi there”");
        assert_eq!(typed.detail_lines(), vec!["hi", "there"]);
        let shot = action(serde_json::json!({"variant": "Phone", "action": "screenshot"}));
        assert_eq!(shot.phrase(), "Take a screenshot");
    }

    #[test]
    fn other_tools_are_not_device_calls() {
        assert!(
            DeviceAction::from_raw_input(&serde_json::json!({"variant": "WebFetch"})).is_none()
        );
        assert!(DeviceAction::from_raw_input(&serde_json::json!({})).is_none());
    }
}
