//! The user's iPhone, through the Mac's iPhone Mirroring app (macOS 15 or later).
//!
//! iPhone Mirroring draws the phone as a Mac window and forwards the mouse and keyboard to it as
//! touches and keys. The window is a video stream: Accessibility sees nothing inside it while the
//! phone is live, and sees ordinary Mac labels and buttons when it is not (iPhone in Use, Connect,
//! Mac locked), which is how the connection is judged in any language. Text is recognized in a
//! capture of the window; input is posted at the window's place on screen, with the window in
//! front, because events posted to an app that is behind are swallowed.
//!
//! Coordinates here are fractions of the window, so a window that moved between a look and an
//! action is still hit where the model chose.

use super::text::TextBox;

/// Why an iPhone cannot be used on this computer.
#[cfg(not(target_os = "macos"))]
pub const NEEDS_A_MAC: &str = "An iPhone is driven through the Mac's iPhone Mirroring app, so it needs Crok on a Mac (macOS 15 or later). On this computer only an Android phone can be used (device: \"android\").";

/// The iPhone side of the phone session. iPhone Mirroring keeps no state of Crok's.
#[derive(Debug, Default)]
pub struct IphoneState;

/// The text on screen, the window's size in points, and a note on where the text came from.
pub type Texts = (Vec<TextBox>, (f64, f64), String);

#[cfg(not(target_os = "macos"))]
impl IphoneState {
    pub async fn status(&mut self) -> String {
        format!("iPhone: {NEEDS_A_MAC}")
    }
    pub async fn connect(&mut self) -> Result<String, String> {
        Err(NEEDS_A_MAC.to_owned())
    }
    pub async fn capture(&mut self) -> Result<(Vec<u8>, (f64, f64)), String> {
        Err(NEEDS_A_MAC.to_owned())
    }
    pub async fn texts(&mut self) -> Result<Texts, String> {
        Err(NEEDS_A_MAC.to_owned())
    }
    pub async fn tap(&mut self, _fx: f64, _fy: f64) -> Result<(), String> {
        Err(NEEDS_A_MAC.to_owned())
    }
    pub async fn long_press(&mut self, _fx: f64, _fy: f64, _s: f64) -> Result<(), String> {
        Err(NEEDS_A_MAC.to_owned())
    }
    pub async fn drag(&mut self, _a: (f64, f64), _b: (f64, f64), _s: f64) -> Result<(), String> {
        Err(NEEDS_A_MAC.to_owned())
    }
    pub async fn scroll(&mut self, _fx: f64, _fy: f64, _dx: f64, _dy: f64) -> Result<(), String> {
        Err(NEEDS_A_MAC.to_owned())
    }
    pub async fn type_text(&mut self, _text: &str) -> Result<(), String> {
        Err(NEEDS_A_MAC.to_owned())
    }
    pub async fn key(&mut self, _name: &str) -> Result<String, String> {
        Err(NEEDS_A_MAC.to_owned())
    }
    pub async fn home(&mut self) -> Result<(), String> {
        Err(NEEDS_A_MAC.to_owned())
    }
    pub async fn app_switcher(&mut self) -> Result<(), String> {
        Err(NEEDS_A_MAC.to_owned())
    }
    pub async fn open_app(&mut self, _name: &str) -> Result<String, String> {
        Err(NEEDS_A_MAC.to_owned())
    }
}

#[cfg(target_os = "macos")]
impl IphoneState {
    pub async fn status(&mut self) -> String {
        blocking(|| Ok(imp::status())).await.unwrap_or_else(|e| e)
    }
    pub async fn connect(&mut self) -> Result<String, String> {
        blocking(imp::connect).await
    }
    pub async fn capture(&mut self) -> Result<(Vec<u8>, (f64, f64)), String> {
        blocking(|| {
            let (png, window) = imp::capture()?;
            Ok((png, (window.bounds.size.width, window.bounds.size.height)))
        })
        .await
    }
    pub async fn texts(&mut self) -> Result<Texts, String> {
        blocking(imp::texts).await
    }
    pub async fn tap(&mut self, fx: f64, fy: f64) -> Result<(), String> {
        blocking(move || imp::act(|w| imp::tap(w, fx, fy))).await
    }
    pub async fn long_press(&mut self, fx: f64, fy: f64, seconds: f64) -> Result<(), String> {
        blocking(move || imp::act(|w| imp::long_press(w, fx, fy, seconds))).await
    }
    pub async fn drag(
        &mut self,
        from: (f64, f64),
        to: (f64, f64),
        seconds: f64,
    ) -> Result<(), String> {
        blocking(move || imp::act(|w| imp::drag(w, from, to, seconds))).await
    }
    pub async fn scroll(&mut self, fx: f64, fy: f64, dx: f64, dy: f64) -> Result<(), String> {
        blocking(move || imp::act(|w| imp::scroll(w, fx, fy, dx, dy))).await
    }
    pub async fn type_text(&mut self, text: &str) -> Result<(), String> {
        let text = text.to_owned();
        blocking(move || imp::act(|_| imp::paste(&text))).await
    }
    pub async fn key(&mut self, name: &str) -> Result<String, String> {
        let name = name.to_owned();
        blocking(move || imp::act(|_| imp::press_named(&name))).await
    }
    pub async fn home(&mut self) -> Result<(), String> {
        blocking(|| imp::act(|_| imp::shortcut("1", 800))).await
    }
    pub async fn app_switcher(&mut self) -> Result<(), String> {
        blocking(|| imp::act(|_| imp::shortcut("2", 800))).await
    }
    pub async fn open_app(&mut self, name: &str) -> Result<String, String> {
        let name = name.to_owned();
        blocking(move || imp::act(|_| imp::open_app(&name))).await
    }
}

#[cfg(target_os = "macos")]
async fn blocking<T: Send + 'static>(
    work: impl FnOnce() -> Result<T, String> + Send + 'static,
) -> Result<T, String> {
    tokio::task::spawn_blocking(work)
        .await
        .map_err(|e| format!("the iPhone action stopped: {e}"))?
}

#[cfg(target_os = "macos")]
mod imp {
    use std::thread::sleep;
    use std::time::{Duration, Instant};

    use super::super::macos::{self as mac, Ax, WindowInfo};
    use super::super::ocr;
    use super::Texts;
    use crate::implementations::grok_build::computer_use::keys;
    use crate::implementations::grok_build::computer_use::macos as cg;

    pub const APP_PATH: &str = "/System/Applications/iPhone Mirroring.app";
    const EXECUTABLE_PREFIX: &str = "/System/Applications/iPhone Mirroring.app/Contents/";

    /// App launch to phone window.
    const LAUNCH_WAIT: Duration = Duration::from_secs(12);
    /// App running, window still coming up.
    const WINDOW_WAIT: Duration = Duration::from_secs(6);
    /// A Connect press to the live stream, at most.
    const CONNECT_WAIT: Duration = Duration::from_secs(12);
    /// By now a press has drawn Connecting and then its outcome.
    const ATTEMPT_SETTLE: Duration = Duration::from_millis(2500);

    /// Buttons of an interstitial that try to connect, pressed once per `connect`.
    const CONNECT_BUTTONS: &[&str] = &["connect", "try again", "retry", "continue", "reconnect"];
    /// A lone button that is not an attempt to connect.
    const NOT_CONNECT_BUTTONS: &[&str] = &[
        "background",
        "cancel",
        "quit",
        "unlock",
        "ok",
        "done",
        "settings",
    ];

    /// Where the session stands, from Accessibility alone (no capture, no recognition).
    #[derive(Debug, Clone, PartialEq)]
    pub enum State {
        NotInstalled,
        NotRunning,
        NoWindow,
        /// An interstitial is up: the labels and button titles in the window.
        Blocked(Vec<Node>),
        Ready(WindowInfo),
    }

    #[derive(Debug, Clone, PartialEq)]
    pub struct Node {
        pub role: String,
        pub text: String,
    }

    fn installed() -> bool {
        std::path::Path::new(APP_PATH).exists()
    }

    fn pid() -> Option<i32> {
        mac::pid_under(EXECUTABLE_PREFIX)
    }

    /// The phone window. The app also owns a Welcome window, a 54-point button and several
    /// screen-wide 30-point strips that the full window list shows, so the window titled with the
    /// app's own name wins (both are localized together); without Screen Recording there are no
    /// titles, and the on-screen window comes next. No minimum size otherwise: with Stage Manager
    /// a window in the side rail is a real, shrunk phone window.
    fn find_window(pid: i32, on_screen: bool) -> Option<WindowInfo> {
        let ours = |w: &WindowInfo| {
            w.pid == pid && w.layer == 0 && w.bounds.size.width > 0.0 && w.bounds.size.height > 0.0
        };
        let all: Vec<WindowInfo> = mac::windows(on_screen).into_iter().filter(ours).collect();
        if let Some(named) = all
            .iter()
            .find(|w| w.name.as_deref().is_some_and(|n| !n.is_empty()) && w.name == w.owner)
        {
            return Some(named.clone());
        }
        if on_screen {
            return all.into_iter().next();
        }
        if let Some(visible) = mac::windows(true).into_iter().find(|w| ours(w)) {
            return Some(visible);
        }
        all.into_iter()
            .filter(|w| w.name.as_deref().is_none_or(str::is_empty))
            .find(|w| w.bounds.size.width > 40.0 && w.bounds.size.height > 40.0)
    }

    fn window_element(pid: i32, window: &WindowInfo) -> Option<Ax> {
        let app = Ax::application(pid)?;
        app.elements("AXWindows").into_iter().find(|w| {
            w.frame().is_some_and(|f| {
                (f.origin.x - window.bounds.origin.x).abs() < 4.0
                    && (f.origin.y - window.bounds.origin.y).abs() < 4.0
                    && (f.size.width - window.bounds.size.width).abs() < 4.0
                    && (f.size.height - window.bounds.size.height).abs() < 4.0
            })
        })
    }

    /// The Mac interface drawn inside the phone window: none while the phone is live.
    fn window_nodes(pid: i32, window: &WindowInfo) -> Vec<(Node, Ax)> {
        let Some(target) = window_element(pid, window) else {
            return Vec::new();
        };
        let mut out = Vec::new();
        fn walk(node: Ax, depth: usize, out: &mut Vec<(Node, Ax)>) {
            if depth > 6 || out.len() > 40 {
                return;
            }
            let role = node.string("AXRole").unwrap_or_default();
            let children = node.elements("AXChildren");
            if matches!(
                role.as_str(),
                "AXStaticText" | "AXButton" | "AXTextField" | "AXSecureTextField" | "AXImage"
            ) {
                let text = ["AXTitle", "AXValue", "AXDescription"]
                    .iter()
                    .filter_map(|attribute| node.string(attribute))
                    .map(|s| s.split_whitespace().collect::<Vec<_>>().join(" "))
                    .filter(|s| !s.is_empty())
                    .collect::<Vec<_>>()
                    .join(" ");
                out.push((Node { role, text }, node));
            }
            for child in children {
                walk(child, depth + 1, out);
            }
        }
        walk(target, 0, &mut out);
        out
    }

    pub fn state() -> State {
        if !installed() {
            return State::NotInstalled;
        }
        let Some(pid) = pid() else {
            return State::NotRunning;
        };
        let Some(window) = find_window(pid, false) else {
            return State::NoWindow;
        };
        let nodes = window_nodes(pid, &window);
        if nodes.is_empty() {
            State::Ready(window)
        } else {
            State::Blocked(nodes.into_iter().map(|(node, _)| node).collect())
        }
    }

    /// The window's words, as the user would read them.
    fn detail(nodes: &[Node]) -> String {
        let texts: Vec<&str> = nodes
            .iter()
            .filter(|n| n.role == "AXStaticText" && !n.text.is_empty())
            .map(|n| n.text.as_str())
            .collect();
        let buttons: Vec<String> = nodes
            .iter()
            .filter(|n| n.role == "AXButton" && !n.text.is_empty())
            .map(|n| format!("'{}'", n.text))
            .collect();
        let mut parts = Vec::new();
        if !texts.is_empty() {
            parts.push(texts.join(" "));
        }
        if !buttons.is_empty() {
            parts.push(format!("buttons: {}", buttons.join(", ")));
        }
        parts.join(" ")
    }

    /// What the user must do, from the words the window shows.
    fn guidance(said: &str) -> &'static str {
        let low = said.to_lowercase();
        if ["in use", "timed out", "lock your iphone"]
            .iter()
            .any(|p| low.contains(p))
        {
            return "This needs the user: ask them to LOCK their iPhone (press the side button), then say so, and connect again. Crok never types a passcode.";
        }
        let words: Vec<&str> = low
            .split(|c: char| !c.is_alphanumeric())
            .filter(|w| !w.is_empty())
            .collect();
        if low.contains("touch id") || words.contains(&"password") {
            return "This needs the user: the Mac is asking for Touch ID or a password. Ask them to approve or cancel it; Crok never types a password.";
        }
        "This needs the user: ask them to clear this in the iPhone Mirroring window on the Mac."
    }

    fn not_live(state: &State, pressed: Option<&str>) -> String {
        match state {
            State::NotInstalled => "This Mac has no iPhone Mirroring app; it comes with macOS Sequoia 15 or later. Ask the user to update macOS, or use an Android phone (device: \"android\").".to_owned(),
            State::NotRunning => "iPhone Mirroring would not open. Ask the user to open the iPhone Mirroring app on the Mac and connect their iPhone, then try again.".to_owned(),
            State::NoWindow => "iPhone Mirroring is open but shows no phone. Ask the user to set it up in the iPhone Mirroring app: the iPhone has to be nearby, locked, and signed in to the same Apple Account as the Mac. Then connect again.".to_owned(),
            State::Blocked(nodes) => {
                let said = detail(nodes);
                let said = if said.is_empty() { "a screen with no text".to_owned() } else { said };
                let stop = if said.ends_with(['.', '!', '?']) { "" } else { "." };
                let did = match pressed {
                    Some(button) => format!("Crok pressed {button} and it came back with"),
                    None => "It says".to_owned(),
                };
                format!(
                    "iPhone Mirroring is not connected. {did}: {said}{stop} {} Take a screenshot to see the window.",
                    guidance(&said)
                )
            }
            State::Ready(_) => String::new(),
        }
    }

    fn still_connecting(nodes: &[Node]) -> bool {
        let text = nodes
            .iter()
            .map(|n| n.text.to_lowercase())
            .collect::<Vec<_>>()
            .join(" ");
        text.contains("connecting to")
            || nodes
                .iter()
                .any(|n| n.role == "AXButton" && n.text.eq_ignore_ascii_case("background"))
    }

    /// An interstitial with something to read that is not the Connecting screen.
    fn finished(nodes: &[Node]) -> bool {
        !still_connecting(nodes) && nodes.iter().any(|n| !n.text.trim().is_empty())
    }

    /// Press the interstitial's own button once: its only button, or one that connects. Never a
    /// login prompt's, whose password is never Crok's to type.
    fn press_connect() -> Option<String> {
        let pid = pid()?;
        let window = find_window(pid, false)?;
        let nodes = window_nodes(pid, &window);
        if nodes
            .iter()
            .any(|(n, _)| matches!(n.role.as_str(), "AXTextField" | "AXSecureTextField"))
        {
            return None;
        }
        let buttons: Vec<&(Node, Ax)> =
            nodes.iter().filter(|(n, _)| n.role == "AXButton").collect();
        let choice = match buttons.as_slice() {
            [(only, element)]
                if !NOT_CONNECT_BUTTONS.contains(&only.text.to_lowercase().as_str()) =>
            {
                Some((only, element))
            }
            _ => buttons
                .iter()
                .find(|(n, _)| CONNECT_BUTTONS.contains(&n.text.to_lowercase().as_str()))
                .map(|(n, e)| (n, e)),
        };
        let (node, element) = choice?;
        element.perform("AXPress").then(|| {
            if node.text.is_empty() {
                "its button".to_owned()
            } else {
                format!("'{}'", node.text)
            }
        })
    }

    fn wait_for(timeout: Duration, done: impl Fn(&State) -> bool) -> State {
        let deadline = Instant::now() + timeout;
        let mut current = state();
        while !done(&current) && Instant::now() < deadline {
            sleep(Duration::from_millis(500));
            current = state();
        }
        current
    }

    /// Wait for the live stream after a press: it must hold for three looks in a row, because
    /// the window is empty for a moment before "Connecting to" is drawn. A finished
    /// interstitial (iPhone in Use, locked) is the answer once the attempt has had time to draw.
    fn wait_connected(timeout: Duration) -> State {
        let start = Instant::now();
        sleep(Duration::from_secs(1));
        let mut streak = 0;
        let mut current = state();
        while start.elapsed() < timeout {
            match &current {
                State::Ready(_) => {
                    streak += 1;
                    if streak >= 3 {
                        return current;
                    }
                }
                State::Blocked(nodes) => {
                    streak = 0;
                    if start.elapsed() > ATTEMPT_SETTLE && finished(nodes) {
                        return current;
                    }
                }
                _ => streak = 0,
            }
            sleep(Duration::from_millis(500));
            current = state();
        }
        match current {
            State::Ready(_) if streak < 3 => State::Blocked(Vec::new()),
            other => other,
        }
    }

    fn launch() {
        let _ = std::process::Command::new("/usr/bin/open")
            .args(["-g", "-a", APP_PATH])
            .output();
    }

    /// Whether iPhone Mirroring has the keyboard and its window is the frontmost one: both are
    /// needed, because events reach the app with keyboard focus but are routed by window order.
    fn is_frontmost(pid: i32) -> bool {
        let front = Ax::application(pid)
            .and_then(|app| app.boolean("AXFrontmost"))
            .unwrap_or(false);
        front
            && mac::windows(true)
                .into_iter()
                .find(|w| w.layer == 0)
                .is_some_and(|w| w.pid == pid)
    }

    /// Bring the phone window in front and confirm it, or refuse: input sent to whatever is in
    /// front instead would land in another app.
    pub fn activate() -> Result<(), String> {
        let pid = pid().ok_or("iPhone Mirroring is not open. Use connect first.")?;
        if is_frontmost(pid) {
            return Ok(());
        }
        let window = find_window(pid, false).and_then(|w| window_element(pid, &w));
        if let Some(window) = &window
            && window.boolean("AXMinimized") == Some(true)
        {
            window.set_bool("AXMinimized", false);
        }
        let app = Ax::application(pid);
        let deadline = Instant::now() + Duration::from_millis(2500);
        while Instant::now() < deadline {
            if let Some(app) = &app {
                app.set_bool("AXFrontmost", true);
            }
            if let Some(window) = &window {
                window.perform("AXRaise");
            }
            sleep(Duration::from_millis(80));
            if is_frontmost(pid) {
                return Ok(());
            }
        }
        // Launch Services also switches to the window's Space
        let _ = std::process::Command::new("/usr/bin/open")
            .args(["-a", APP_PATH])
            .output();
        let deadline = Instant::now() + Duration::from_millis(1500);
        while Instant::now() < deadline {
            sleep(Duration::from_millis(100));
            if is_frontmost(pid) {
                return Ok(());
            }
        }
        let owner = mac::windows(true)
            .into_iter()
            .find(|w| w.layer == 0)
            .and_then(|w| w.owner)
            .unwrap_or_else(|| "another app".to_owned());
        Err(format!(
            "Could not bring iPhone Mirroring in front ({owner} kept it), so nothing was sent: input would have gone to that app. Ask the user to click the iPhone Mirroring window, then try again."
        ))
    }

    /// `connect`: what a person would do by hand. Opens iPhone Mirroring when it is closed,
    /// brings it forward so the user can watch, presses the window's Connect once, and waits for
    /// the live stream. What is left after that (an unlocked phone, a login prompt, a phone that
    /// is not paired) is physical, and is said rather than pressed again.
    pub fn connect() -> Result<String, String> {
        cg::check_accessibility()?;
        let mut current = state();
        if current == State::NotInstalled {
            return Err(not_live(&current, None));
        }
        if current == State::NotRunning {
            launch();
            current = wait_for(LAUNCH_WAIT, |s| {
                matches!(s, State::Blocked(_) | State::Ready(_))
            });
        }
        let _ = activate();
        if current == State::NoWindow {
            current = wait_for(WINDOW_WAIT, |s| {
                matches!(s, State::Blocked(_) | State::Ready(_))
            });
        }
        let mut pressed = None;
        if let State::Blocked(nodes) = &current {
            pressed = press_connect();
            if pressed.is_some() || !finished(nodes) {
                current = wait_connected(CONNECT_WAIT);
            }
        }
        match current {
            State::Ready(window) => {
                let _ = activate();
                let permissions = match cg::check_screen_recording() {
                    Ok(()) => String::new(),
                    Err(refused) => format!(" But {refused}"),
                };
                Ok(format!(
                    "The iPhone is connected through iPhone Mirroring and its window is in front ({}x{} points).{permissions}",
                    window.bounds.size.width as i64, window.bounds.size.height as i64
                ))
            }
            other => Err(not_live(&other, pressed.as_deref())),
        }
    }

    /// The live window, or the reason it is not live, without pressing anything.
    fn live() -> Result<WindowInfo, String> {
        match state() {
            State::Ready(window) => Ok(window),
            State::NotRunning | State::NoWindow => Err(
                "iPhone Mirroring is not connected. Use connect first; it opens iPhone Mirroring and connects the phone.".to_owned(),
            ),
            other => Err(not_live(&other, None)),
        }
    }

    /// Run one input action on the live, frontmost window, and check that it is still live.
    pub fn act<T>(work: impl FnOnce(&WindowInfo) -> Result<T, String>) -> Result<T, String> {
        cg::check_accessibility()?;
        live()?;
        activate()?;
        // The window may have moved while it came forward
        let window = live()?;
        let out = work(&window)?;
        live().map_err(|e| format!("The action was sent, but then: {e}"))?;
        Ok(out)
    }

    fn global(window: &WindowInfo, fx: f64, fy: f64) -> (f64, f64) {
        let b = window.bounds;
        (
            b.origin.x + fx.clamp(0.0, 1.0) * b.size.width,
            b.origin.y + fy.clamp(0.0, 1.0) * b.size.height,
        )
    }

    pub fn tap(window: &WindowInfo, fx: f64, fy: f64) -> Result<(), String> {
        long_press(window, fx, fy, 0.06)
    }

    pub fn long_press(window: &WindowInfo, fx: f64, fy: f64, seconds: f64) -> Result<(), String> {
        let (x, y) = global(window, fx, fy);
        cg::mouse(cg::MOVED, x, y, cg::BUTTON_LEFT, 0, 0)?;
        sleep(Duration::from_millis(100));
        cg::mouse(cg::LEFT_DOWN, x, y, cg::BUTTON_LEFT, 1, 0)?;
        sleep(Duration::from_secs_f64(seconds));
        cg::mouse(cg::LEFT_UP, x, y, cg::BUTTON_LEFT, 1, 0)
    }

    /// A touch drag. Fast and short is a momentum flick; iPhone Mirroring on macOS 26 drops
    /// vertical drags in lists, so lists move with `scroll`.
    pub fn drag(
        window: &WindowInfo,
        from: (f64, f64),
        to: (f64, f64),
        seconds: f64,
    ) -> Result<(), String> {
        let (x1, y1) = global(window, from.0, from.1);
        let (x2, y2) = global(window, to.0, to.1);
        let steps = if seconds < 0.3 { 6 } else { 14 };
        cg::mouse(cg::MOVED, x1, y1, cg::BUTTON_LEFT, 0, 0)?;
        sleep(Duration::from_millis(100));
        cg::mouse(cg::LEFT_DOWN, x1, y1, cg::BUTTON_LEFT, 1, 0)?;
        for step in 1..=steps {
            let t = f64::from(step) / f64::from(steps);
            cg::mouse(
                cg::LEFT_DRAGGED,
                x1 + (x2 - x1) * t,
                y1 + (y2 - y1) * t,
                cg::BUTTON_LEFT,
                0,
                0,
            )?;
            sleep(Duration::from_secs_f64(seconds / f64::from(steps)));
        }
        cg::mouse(cg::LEFT_UP, x2, y2, cg::BUTTON_LEFT, 1, 0)
    }

    /// Whether the phone window is the topmost window at a global point: a scroll goes to the
    /// window under the pointer, so it would otherwise move whatever covers the phone.
    fn owns_point(pid: i32, x: f64, y: f64) -> bool {
        mac::windows(true)
            .into_iter()
            .filter(|w| w.layer == 0)
            .find(|w| w.bounds.contains(x, y))
            .is_some_and(|w| w.pid == pid)
    }

    /// Scroll in content space: `(dx, dy)` fractions of the window, a negative `dy` revealing
    /// what is further down. The same deltas move the phone the same way whatever the Mac's
    /// natural-scrolling setting.
    pub fn scroll(window: &WindowInfo, fx: f64, fy: f64, dx: f64, dy: f64) -> Result<(), String> {
        let (x, y) = global(window, fx, fy);
        let pid = window.pid;
        if !owns_point(pid, x, y) {
            activate()?;
            sleep(Duration::from_millis(150));
            if !owns_point(pid, x, y) {
                return Err(format!(
                    "Another window covers the phone at ({}, {}), so the scroll was not sent: it would have scrolled that app. Ask the user to move it away from the iPhone Mirroring window.",
                    x as i64, y as i64
                ));
            }
        }
        cg::mouse(cg::MOVED, x, y, cg::BUTTON_LEFT, 0, 0)?;
        sleep(Duration::from_millis(100));
        const STEPS: i32 = 6;
        let total_y = (dy * window.bounds.size.height).round() as i32;
        let total_x = (dx * window.bounds.size.width).round() as i32;
        for _ in 0..STEPS {
            mac::scroll_pixels(x, y, total_y / STEPS, total_x / STEPS)?;
            sleep(Duration::from_millis(30));
        }
        sleep(Duration::from_millis(150));
        Ok(())
    }

    const SHIFT_MASK: u64 = 0x0002_0000;
    const CONTROL_MASK: u64 = 0x0004_0000;
    const OPTION_MASK: u64 = 0x0008_0000;
    const COMMAND_MASK: u64 = 0x0010_0000;

    /// Press `code` with real modifier keys held: iPhone Mirroring forwards raw key codes and
    /// drops the event's flag bits, so cmd+v sent as a flag arrives as a bare v. Each modifier's
    /// bit is cleared before its release is posted, or the Mac reads it as still held.
    fn press_with(code: u16, modifiers: &[(u16, u64)]) -> Result<(), String> {
        let mut flags = 0u64;
        let mut held = Vec::new();
        let result = (|| {
            for &(modifier, mask) in modifiers {
                flags |= mask;
                mac::key(modifier, true, flags)?;
                held.push((modifier, mask));
                sleep(Duration::from_millis(10));
            }
            mac::key(code, true, flags)?;
            sleep(Duration::from_millis(30));
            mac::key(code, false, flags)?;
            sleep(Duration::from_millis(30));
            Ok(())
        })();
        for (modifier, mask) in held.into_iter().rev() {
            flags &= !mask;
            let _ = mac::key(modifier, false, flags);
            sleep(Duration::from_millis(10));
        }
        result
    }

    fn modifier_keys(chord: keys::Chord) -> Vec<(u16, u64)> {
        let mut out = Vec::new();
        if chord.modifiers.ctrl {
            out.push((keys::CONTROL, CONTROL_MASK));
        }
        if chord.modifiers.alt {
            out.push((keys::OPTION, OPTION_MASK));
        }
        if chord.modifiers.meta {
            out.push((keys::COMMAND, COMMAND_MASK));
        }
        if chord.modifiers.shift || chord.key.shifted {
            out.push((keys::SHIFT, SHIFT_MASK));
        }
        out
    }

    /// A key by name: "enter", "delete" (backspace on a phone), "cmd+a"…
    pub fn press_named(name: &str) -> Result<String, String> {
        let lower = name.trim().to_ascii_lowercase();
        let spelled = match lower.as_str() {
            "delete" | "del" | "backspace" => "backspace",
            "enter" | "return" => "return",
            other => other,
        };
        let chord = keys::parse_chord(spelled).map_err(|e| {
            format!("{e}. Use enter, delete, tab, escape, space, up, down, left, right, or a chord such as \"cmd+a\".")
        })?;
        press_with(chord.key.code, &modifier_keys(chord))?;
        Ok(name.trim().to_owned())
    }

    /// cmd+`key`: a menu shortcut of iPhone Mirroring (1 Home Screen, 2 App Switcher, 3 Spotlight).
    pub fn shortcut(key: &str, settle_ms: u64) -> Result<(), String> {
        let chord = keys::parse_chord(&format!("cmd+{key}"))?;
        press_with(chord.key.code, &modifier_keys(chord))?;
        sleep(Duration::from_millis(settle_ms));
        Ok(())
    }

    /// Type with real key presses on a US layout; iOS autocorrect sees each word as it lands.
    fn type_keys(text: &str) -> Result<(), String> {
        for c in text.chars() {
            let key = match c {
                ' ' => Some(keys::Key {
                    code: 49,
                    shifted: false,
                }),
                '\n' => Some(keys::Key {
                    code: keys::RETURN,
                    shifted: false,
                }),
                other => keys::char_key(other),
            };
            let key = key.ok_or_else(|| format!("'{c}' cannot be typed as a key"))?;
            let held: &[(u16, u64)] = if key.shifted {
                &[(keys::SHIFT, SHIFT_MASK)]
            } else {
                &[]
            };
            press_with(key.code, held)?;
            sleep(Duration::from_millis(30));
        }
        Ok(())
    }

    fn typable(text: &str) -> bool {
        text.chars()
            .all(|c| c == ' ' || c == '\n' || keys::char_key(c).is_some())
    }

    /// Type by pasting: the text goes on the Mac's clipboard and cmd+v sends it to the phone,
    /// exactly as written, past autocorrect and keyboard layout. It stays on the clipboard
    /// afterwards: the phone fetches it some unknown time after the paste, and putting back the
    /// earlier contents too soon would paste those (a password, a token) instead.
    pub fn paste(text: &str) -> Result<(), String> {
        use std::io::Write as _;
        if text.is_empty() {
            return Ok(());
        }
        #[allow(clippy::disallowed_methods)] // waited on just below
        let mut copy = std::process::Command::new("/usr/bin/pbcopy")
            .stdin(std::process::Stdio::piped())
            .spawn()
            .map_err(|e| format!("could not use the Mac's clipboard: {e}"))?;
        if let Some(mut stdin) = copy.stdin.take() {
            stdin
                .write_all(text.as_bytes())
                .map_err(|e| format!("could not use the Mac's clipboard: {e}"))?;
        }
        copy.wait()
            .map_err(|e| format!("could not use the Mac's clipboard: {e}"))?;
        let check = std::process::Command::new("/usr/bin/pbpaste")
            .output()
            .map_err(|e| format!("could not read the Mac's clipboard: {e}"))?;
        if check.stdout != text.as_bytes() {
            return Err(
                "The Mac's clipboard did not take the text, so nothing was pasted.".to_owned(),
            );
        }
        // The clipboard has to reach the phone
        sleep(Duration::from_millis(150));
        activate()?;
        let v = keys::char_key('v').ok_or("no key for v")?;
        press_with(v.code, &[(keys::COMMAND, COMMAND_MASK)])
    }

    /// Open an app through Spotlight: cmd+3, type the name, let results fill, then Return.
    pub fn open_app(name: &str) -> Result<String, String> {
        shortcut("3", 900)?;
        if typable(name) {
            type_keys(name)?;
        } else {
            paste(name)?;
        }
        sleep(Duration::from_millis(1200));
        press_with(keys::RETURN, &[])?;
        sleep(Duration::from_millis(1000));
        Ok(name.to_owned())
    }

    /// The window as PNG. `screencapture -l` takes the window alone, even when covered; when the
    /// window is not composited it fails, so the window comes forward and its rectangle is taken.
    pub fn capture() -> Result<(Vec<u8>, WindowInfo), String> {
        cg::check_screen_recording()?;
        let pid = pid().ok_or("iPhone Mirroring is not open. Use connect first.")?;
        let mut last = String::new();
        for _ in 0..3 {
            let window = find_window(pid, false)
                .ok_or("iPhone Mirroring shows no phone window. Use connect first.")?;
            let file = tempfile::Builder::new()
                .prefix("crok-iphone-")
                .suffix(".png")
                .tempfile()
                .map_err(|e| format!("could not make a file for the screenshot: {e}"))?;
            let path = file.path().to_path_buf();
            let attempt = |args: Vec<String>| -> Option<Vec<u8>> {
                let out = std::process::Command::new("/usr/sbin/screencapture")
                    .args(&args)
                    .arg(&path)
                    .output()
                    .ok()?;
                let bytes = std::fs::read(&path).ok()?;
                (out.status.success() && bytes.len() > 1000).then_some(bytes)
            };
            if let Some(png) = attempt(vec!["-x".into(), "-o".into(), format!("-l{}", window.id)]) {
                return Ok((png, window));
            }
            let _ = activate();
            let window = find_window(pid, true).unwrap_or(window);
            let b = window.bounds;
            if let Some(png) = attempt(vec![
                "-x".into(),
                format!(
                    "-R{},{},{},{}",
                    b.origin.x.floor(),
                    b.origin.y.floor(),
                    b.size.width.ceil(),
                    b.size.height.ceil()
                ),
            ]) {
                return Ok((png, window));
            }
            last = "screencapture could not take the window".to_owned();
            sleep(Duration::from_millis(300));
        }
        Err(format!("Could not take a picture of the iPhone: {last}."))
    }

    /// The text in the window, recognized in a capture; only while the phone is live, because
    /// an interstitial's words are the Mac's, not the phone's.
    pub fn texts() -> Result<Texts, String> {
        cg::check_accessibility()?;
        live()?;
        let (png, window) = capture()?;
        let (width, height) = (window.bounds.size.width, window.bounds.size.height);
        let boxes = ocr::recognize(&png)?
            .into_iter()
            .filter(|r| r.confidence >= 0.3)
            .map(|r| r.into_box(width, height))
            .collect();
        Ok((
            boxes,
            (width, height),
            "Recognized in the picture: words may be misread, and icons without a label are not listed (take a screenshot for those).".to_owned(),
        ))
    }

    pub fn status() -> String {
        let (screen, accessibility) = cg::permissions();
        let mut missing = Vec::new();
        if !accessibility {
            missing.push("Accessibility");
        }
        if !screen {
            missing.push("Screen & System Audio Recording");
        }
        let permissions = if missing.is_empty() {
            String::new()
        } else {
            format!(
                " macOS has not yet allowed Crok {}: the first phone action asks, or the user turns on the app that runs Crok (Crok Desktop, or the terminal) in System Settings › Privacy & Security.",
                missing.join(" and ")
            )
        };
        let state_text = match state() {
            State::NotInstalled => "this Mac has no iPhone Mirroring (it needs macOS 15 or later).".to_owned(),
            State::NotRunning => "iPhone Mirroring is closed; connect opens it and connects the phone.".to_owned(),
            State::NoWindow => "iPhone Mirroring is open but shows no phone; it may need to be set up with the iPhone first.".to_owned(),
            State::Blocked(nodes) => {
                let said = detail(&nodes);
                format!(
                    "iPhone Mirroring is open but not connected ({}); connect presses its Connect button.",
                    if said.is_empty() { "no text" } else { &said }
                )
            }
            State::Ready(window) => format!(
                "connected through iPhone Mirroring ({}x{} points).",
                window.bounds.size.width as i64, window.bounds.size.height as i64
            ),
        };
        format!("iPhone: {state_text}{permissions}")
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        fn node(role: &str, text: &str) -> Node {
            Node {
                role: role.into(),
                text: text.into(),
            }
        }

        #[test]
        fn guidance_follows_the_window_words() {
            assert!(guidance("iPhone in Use").contains("LOCK"));
            assert!(guidance("Timed Out due to iPhone use").contains("LOCK"));
            assert!(guidance("Enter your password to unlock").contains("password"));
            assert!(!guidance("Passwords").contains("Touch ID"));
            assert!(guidance("Something else").contains("clear this"));
        }

        #[test]
        fn connecting_is_not_finished() {
            assert!(!finished(&[node("AXStaticText", "Connecting to iPhone")]));
            assert!(!finished(&[node("AXButton", "Background")]));
            assert!(!finished(&[node("AXImage", "")]));
            assert!(finished(&[node("AXStaticText", "iPhone in Use")]));
        }

        #[test]
        fn blocked_messages_quote_the_window() {
            let text = not_live(
                &State::Blocked(vec![
                    node("AXStaticText", "iPhone in Use"),
                    node("AXButton", "Connect"),
                ]),
                Some("'Connect'"),
            );
            assert!(text.contains("Crok pressed 'Connect' and it came back with: iPhone in Use buttons: 'Connect'."), "{text}");
            assert!(text.contains("LOCK"));
        }

        #[test]
        fn typable_text_is_plain_us_keys() {
            assert!(typable("Notes app"));
            assert!(!typable("微信"));
        }
    }
}
