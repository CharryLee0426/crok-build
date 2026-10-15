//! An Android phone over adb.
//!
//! No app on the phone: `screencap` is the picture, `uiautomator dump` the text (exact, from the
//! accessibility tree), and `input` the hands. The phone is found by itself: `ANDROID_SERIAL` when
//! set, else a phone plugged in over USB, else one connected over Wi‑Fi, else a paired phone
//! announcing itself on the network. Connecting it (USB debugging and Allow, or Wireless
//! debugging and pairing) and unlocking it are the user's; a PIN is never typed.

use std::path::PathBuf;
use std::time::{Duration, Instant};

use super::adb::{self, Attached, Transport};
use super::text::TextBox;
use super::uitree;

const QUICK: Duration = Duration::from_secs(15);
const SLOW: Duration = Duration::from_secs(60);
/// How long a screen whose tree uiautomator refused is read from pixels instead: it waits about
/// ten seconds for the screen to go idle before refusing, so asking again at once costs as much.
const TREE_BUSY_FOR: Duration = Duration::from_secs(20);
/// How long one wake-and-lock check holds for a burst of actions.
const GATE_FOR: Duration = Duration::from_secs(2);

/// Names a person says, for apps whose package id does not contain them.
const APP_IDS: &[(&str, &[&str])] = &[
    (
        "tiktok",
        &["com.zhiliaoapp.musically", "com.ss.android.ugc.trill"],
    ),
    ("x", &["com.twitter.android"]),
    ("twitter", &["com.twitter.android"]),
    ("threads", &["com.instagram.barcelona"]),
    ("facebook", &["com.facebook.katana", "com.facebook.lite"]),
    ("messenger", &["com.facebook.orca"]),
    ("signal", &["org.thoughtcrime.securesms"]),
    ("gmail", &["com.google.android.gm"]),
    ("playstore", &["com.android.vending"]),
    ("googleplay", &["com.android.vending"]),
    ("uber", &["com.ubercab"]),
    ("ubereats", &["com.ubercab.eats"]),
    ("cashapp", &["com.squareup.cash"]),
    ("amazon", &["com.amazon.mShop.android.shopping"]),
    ("maps", &["com.google.android.apps.maps"]),
    ("googlemaps", &["com.google.android.apps.maps"]),
    (
        "messages",
        &[
            "com.google.android.apps.messaging",
            "com.samsung.android.messaging",
        ],
    ),
    (
        "phone",
        &[
            "com.google.android.dialer",
            "com.android.dialer",
            "com.samsung.android.dialer",
        ],
    ),
    (
        "clock",
        &[
            "com.google.android.deskclock",
            "com.android.deskclock",
            "com.sec.android.app.clockpackage",
        ],
    ),
    (
        "files",
        &["com.google.android.documentsui", "com.android.documentsui"],
    ),
    ("settings", &["com.android.settings"]),
    (
        "camera",
        &[
            "com.google.android.GoogleCamera",
            "com.android.camera2",
            "com.sec.android.app.camera",
        ],
    ),
    ("photos", &["com.google.android.apps.photos"]),
    ("youtube", &["com.google.android.youtube"]),
    ("whatsapp", &["com.whatsapp"]),
    ("wechat", &["com.tencent.mm"]),
    ("weixin", &["com.tencent.mm"]),
    (
        "calendar",
        &[
            "com.google.android.calendar",
            "com.samsung.android.calendar",
        ],
    ),
    (
        "contacts",
        &[
            "com.google.android.contacts",
            "com.samsung.android.app.contacts",
        ],
    ),
];

/// Key names to Android key codes. `input keyevent` presses one key, so chords are refused.
fn key_code(name: &str) -> Option<String> {
    let lower = name.trim().to_ascii_lowercase().replace([' ', '-'], "_");
    let code = match lower.as_str() {
        "enter" | "return" => "ENTER",
        "tab" => "TAB",
        "space" => "SPACE",
        "delete" | "backspace" | "del" => "DEL",
        "forward_delete" => "FORWARD_DEL",
        "escape" | "esc" => "ESCAPE",
        "home" => "HOME",
        "back" => "BACK",
        "recents" | "app_switch" | "app_switcher" => "APP_SWITCH",
        "menu" => "MENU",
        "up" | "arrowup" => "DPAD_UP",
        "down" | "arrowdown" => "DPAD_DOWN",
        "left" | "arrowleft" => "DPAD_LEFT",
        "right" | "arrowright" => "DPAD_RIGHT",
        "center" | "dpad_center" => "DPAD_CENTER",
        "power" => "POWER",
        "volume_up" | "volumeup" => "VOLUME_UP",
        "volume_down" | "volumedown" => "VOLUME_DOWN",
        "mute" | "volume_mute" => "VOLUME_MUTE",
        "search" => "SEARCH",
        "camera" => "CAMERA",
        "page_up" | "pageup" => "PAGE_UP",
        "page_down" | "pagedown" => "PAGE_DOWN",
        "move_home" => "MOVE_HOME",
        "move_end" | "end" => "MOVE_END",
        "play_pause" | "media_play_pause" => "MEDIA_PLAY_PAUSE",
        "wakeup" => "WAKEUP",
        "sleep" => "SLEEP",
        other => {
            let mut chars = other.chars();
            return match (chars.next(), chars.next()) {
                (Some(c), None) if c.is_ascii_alphanumeric() => {
                    Some(format!("KEYCODE_{}", c.to_ascii_uppercase()))
                }
                _ => None,
            };
        }
    };
    Some(format!("KEYCODE_{code}"))
}

/// The Android side of the phone session.
#[derive(Debug, Default)]
pub struct AndroidState {
    adb: Option<PathBuf>,
    serial: Option<String>,
    model: Option<String>,
    transport: Option<Transport>,
    /// The screen's size in device pixels, as the last look saw it.
    size: Option<(f64, f64)>,
    /// Whether this phone's `input` knows `motionevent`.
    motionevents: Option<bool>,
    tree_busy_until: Option<Instant>,
    gate_at: Option<Instant>,
}

/// Why no phone could be used, worded for the user.
fn not_reachable(rows: &[Attached]) -> String {
    if rows.iter().any(|row| row.state == "unauthorized") {
        return "The Android phone is plugged in but has not allowed this computer. Ask the user to unlock it and tap Allow on the \"Allow USB debugging?\" prompt (tick \"Always allow from this computer\"); if no prompt appears, unplug and plug it in again.".to_owned();
    }
    if !rows.is_empty() {
        return "adb sees the Android phone but it is offline. Ask the user to unplug and plug it in again, or turn Wireless debugging off and on.".to_owned();
    }
    "No Android phone is connected. Ask the user to connect one: over USB, turn on Settings › Developer options › USB debugging (Developer options appear after tapping Settings › About phone › Build number seven times), plug the phone in and tap Allow; or over Wi‑Fi (same network as this computer), open Developer options › Wireless debugging › Pair device with pairing code and read you the six-digit code for pair_android.".to_owned()
}

impl AndroidState {
    /// The adb to use; with `fetch`, downloaded when this machine has none.
    async fn adb(&mut self, fetch: bool) -> Result<PathBuf, String> {
        if let Some(path) = &self.adb
            && path.is_file()
        {
            return Ok(path.clone());
        }
        let path = if fetch {
            adb::ensure().await?
        } else {
            adb::find_local().ok_or_else(|| {
                "adb is not on this computer yet. Crok downloads Google's Android platform-tools the first time an Android phone is used.".to_owned()
            })?
        };
        self.adb = Some(path.clone());
        Ok(path)
    }

    async fn run(&mut self, args: &[&str], timeout: Duration) -> Result<adb::Output, String> {
        let adb = self.adb(true).await?;
        adb::run(&adb, None, args, timeout).await
    }

    async fn attached(&mut self) -> Result<Vec<Attached>, String> {
        let out = self.run(&["devices"], QUICK).await?;
        Ok(adb::parse_devices(&out.text()))
    }

    /// Whether a phone is ready without downloading adb or connecting anything: how a call with
    /// no `device` picks Android.
    pub async fn ready_without_setup(&mut self) -> bool {
        let Ok(adb) = self.adb(false).await else {
            return false;
        };
        match adb::run(&adb, None, &["devices"], QUICK).await {
            Ok(out) => adb::parse_devices(&out.text())
                .iter()
                .any(|row| row.state == "device"),
            Err(_) => false,
        }
    }

    /// Pick the phone: `ANDROID_SERIAL`, a USB phone, a Wi‑Fi phone, then a paired phone on the
    /// network. `None` when there is none, with the rows adb sees.
    async fn resolve(&mut self) -> Result<String, String> {
        if let Some(serial) = &self.serial {
            return Ok(serial.clone());
        }
        let chosen = if let Some(serial) = std::env::var("ANDROID_SERIAL")
            .ok()
            .filter(|s| !s.trim().is_empty())
        {
            Some((serial, None))
        } else {
            let pick = |rows: &[Attached]| {
                let ready = rows.iter().filter(|row| row.state == "device");
                let mut usb = ready.clone().filter(|row| row.transport == Transport::Usb);
                usb.next()
                    .or_else(|| ready.clone().find(|row| row.transport == Transport::Wifi))
                    .map(|row| (row.id.clone(), Some(row.transport)))
            };
            let rows = self.attached().await?;
            match pick(&rows) {
                Some(found) => Some(found),
                None => {
                    let services = self.run(&["mdns", "services"], QUICK).await;
                    let services = services
                        .map(|out| adb::parse_mdns(&out.text(), "connect"))
                        .unwrap_or_default();
                    for service in services {
                        let out = self
                            .run(&["connect", &service.address], QUICK)
                            .await
                            .map(|out| out.text())
                            .unwrap_or_default();
                        if out.contains("connected") && !out.contains("cannot") {
                            break;
                        }
                    }
                    let rows = self.attached().await?;
                    match pick(&rows) {
                        Some(found) => Some(found),
                        None => return Err(not_reachable(&rows)),
                    }
                }
            }
        };
        let Some((serial, transport)) = chosen else {
            return Err(not_reachable(&[]));
        };
        self.serial = Some(serial.clone());
        self.transport = transport.or(Some(if serial.contains(':') {
            Transport::Wifi
        } else {
            Transport::Usb
        }));
        self.model = self.model_of(&serial).await;
        Ok(serial)
    }

    /// The phone's model name, read straight from adb rather than through [`Self::exec`], which
    /// picks the phone.
    async fn model_of(&mut self, serial: &str) -> Option<String> {
        let adb = self.adb(true).await.ok()?;
        let out = adb::run(
            &adb,
            Some(serial),
            &["shell", "getprop", "ro.product.model"],
            QUICK,
        )
        .await
        .ok()?;
        let model = out.text().trim().to_owned();
        (out.success && !model.is_empty()).then_some(model)
    }

    /// Forget the chosen phone, so the next command finds one again.
    fn forget(&mut self) {
        self.serial = None;
        self.model = None;
        self.transport = None;
        self.size = None;
        self.motionevents = None;
        self.gate_at = None;
        self.tree_busy_until = None;
    }

    /// Run `adb -s <phone> args…`; when the phone is gone, find a phone once more and retry.
    async fn exec(&mut self, args: &[&str], timeout: Duration) -> Result<Vec<u8>, String> {
        for attempt in 0..2 {
            let serial = self.resolve().await?;
            let adb = self.adb(true).await?;
            let out = adb::run(&adb, Some(&serial), args, timeout).await?;
            if out.success {
                return Ok(out.stdout);
            }
            let message = out.message();
            let gone = message.contains("not found")
                || message.contains("offline")
                || message.contains("no devices")
                || message.contains("unauthorized");
            if gone && attempt == 0 {
                self.forget();
                continue;
            }
            if message.contains("unauthorized") {
                return Err(not_reachable(&[Attached {
                    id: serial,
                    state: "unauthorized".into(),
                    transport: Transport::Usb,
                }]));
            }
            return Err(format!("adb {} failed: {}", args.join(" "), message));
        }
        Err(not_reachable(&[]))
    }

    async fn exec_text(&mut self, args: &[&str], timeout: Duration) -> Result<String, String> {
        Ok(String::from_utf8_lossy(&self.exec(args, timeout).await?).into_owned())
    }

    async fn shell(&mut self, command: &str) -> Result<String, String> {
        self.exec_text(&["shell", command], SLOW).await
    }

    /// The phone as the model and the user read it: `Pixel 8 over USB`.
    fn describe(&self) -> String {
        let model = self.model.as_deref().unwrap_or("Android phone");
        match self.transport {
            Some(transport) => format!("{model} over {}", transport.label()),
            None => model.to_owned(),
        }
    }

    /// (awake, locked) from two quick reads: adb taps a lock screen without complaint, so ask.
    async fn screen_status(&mut self) -> Result<(bool, bool), String> {
        let power = self.shell("dumpsys power | grep -m1 mWakefulness=").await?;
        let window = self
            .shell("dumpsys window | grep -E -m3 'isKeyguardShowing|mShowingLockscreen|mDreamingLockscreen'")
            .await
            .unwrap_or_default();
        let awake = power.contains("Awake") || power.trim().is_empty();
        let locked =
            window.contains("isKeyguardShowing=true") || window.contains("mShowingLockscreen=true");
        Ok((awake, locked))
    }

    /// Refuse to act on a phone that is asleep or locked. Waking it and dismissing a lock screen
    /// that has no PIN are harmless and done here; unlocking a secured phone is the user's.
    async fn gate(&mut self) -> Result<(), String> {
        if self.gate_at.is_some_and(|at| at.elapsed() < GATE_FOR) {
            return Ok(());
        }
        let (mut awake, mut locked) = self.screen_status().await?;
        if !awake {
            self.shell("input keyevent KEYCODE_WAKEUP").await?;
            tokio::time::sleep(Duration::from_millis(500)).await;
            (awake, locked) = self.screen_status().await?;
        }
        if locked {
            let _ = self.shell("wm dismiss-keyguard").await;
            tokio::time::sleep(Duration::from_millis(700)).await;
            (awake, locked) = self.screen_status().await?;
        }
        if locked || !awake {
            self.gate_at = None;
            return Err("The Android phone is locked. Ask the user to unlock it (PIN, pattern or fingerprint) and say when it is done; Crok never types a PIN. It locks again after its screen timeout.".to_owned());
        }
        self.gate_at = Some(Instant::now());
        Ok(())
    }

    /// Make the phone usable and say which phone it is.
    pub async fn connect(&mut self) -> Result<String, String> {
        self.forget();
        self.resolve().await?;
        self.gate().await?;
        let (width, height) = self.physical_size().await?;
        Ok(format!(
            "Connected to the {} ({}x{} pixels), awake and unlocked.",
            self.describe(),
            width as i64,
            height as i64
        ))
    }

    /// What `status` reports for Android, without downloading or connecting anything.
    pub async fn status(&mut self) -> String {
        let Ok(adb) = self.adb(false).await else {
            return "Android: adb is not on this computer yet; Crok downloads Google's Android platform-tools by itself the first time an Android phone is used (device: \"android\").".to_owned();
        };
        let rows = match adb::run(&adb, None, &["devices"], QUICK).await {
            Ok(out) => adb::parse_devices(&out.text()),
            Err(error) => return format!("Android: adb did not answer: {error}"),
        };
        if !rows.iter().any(|row| row.state == "device") {
            let mdns = adb::run(&adb, None, &["mdns", "services"], QUICK)
                .await
                .map(|out| adb::parse_mdns(&out.text(), "connect"))
                .unwrap_or_default();
            if !mdns.is_empty() {
                return format!(
                    "Android: a paired phone is on this network ({}); connect reaches it.",
                    mdns.iter()
                        .map(|s| s.address.as_str())
                        .collect::<Vec<_>>()
                        .join(", ")
                );
            }
            return format!("Android: {}", not_reachable(&rows));
        }
        if let Err(error) = self.resolve().await {
            return format!("Android: {error}");
        }
        match self.screen_status().await {
            Ok((_, true)) => format!("Android: {} is connected but locked.", self.describe()),
            Ok((awake, false)) => format!(
                "Android: {} is connected{}.",
                self.describe(),
                if awake {
                    " and unlocked"
                } else {
                    " (screen off; it is woken when used)"
                }
            ),
            Err(error) => format!("Android: {} is connected, but {error}", self.describe()),
        }
    }

    /// `wm size`, as device pixels in the phone's natural orientation.
    async fn physical_size(&mut self) -> Result<(f64, f64), String> {
        let out = self.shell("wm size").await?;
        let size = parse_wm_size(&out).ok_or_else(|| {
            "The Android phone gave no screen size; is it still starting up?".to_owned()
        })?;
        if self.size.is_none() {
            self.size = Some(size);
        }
        Ok(size)
    }

    /// The screen's size as actions use it: the last look's, else `wm size`.
    async fn current_size(&mut self) -> Result<(f64, f64), String> {
        match self.size {
            Some(size) => Ok(size),
            None => self.physical_size().await,
        }
    }

    /// The screen as PNG, and its size in device pixels.
    pub async fn capture(&mut self) -> Result<(Vec<u8>, (f64, f64)), String> {
        self.resolve().await?;
        let png = self.exec(&["exec-out", "screencap", "-p"], SLOW).await?;
        let (width, height) =
            png_size(&png).ok_or("The Android phone's screenshot could not be read; try again.")?;
        let size = (f64::from(width), f64::from(height));
        self.size = Some(size);
        Ok((png, size))
    }

    /// The text on screen and the screen's size; a note says where the text came from.
    pub async fn texts(&mut self) -> Result<(Vec<TextBox>, (f64, f64), String), String> {
        self.gate().await?;
        let busy = self
            .tree_busy_until
            .is_some_and(|until| Instant::now() < until);
        if !busy {
            match self.tree().await {
                Ok(nodes) => {
                    let size = match uitree::screen_size(&nodes) {
                        Some(size) => size,
                        None => self.current_size().await?,
                    };
                    self.size = Some(size);
                    let mut note = "Read from the accessibility tree (exact); [name] is a control with no text, named by its id.".to_owned();
                    if let Some(app) = self.current_app().await {
                        note.push_str(&format!(" Foreground app: {app}."));
                    }
                    return Ok((uitree::text_boxes(&nodes), size, note));
                }
                Err(TreeError::Busy(message)) => {
                    if !cfg!(target_os = "macos") {
                        return Err(message);
                    }
                }
                Err(TreeError::Failed(message)) => return Err(message),
            }
        }
        self.pixel_texts().await
    }

    #[cfg(target_os = "macos")]
    async fn pixel_texts(&mut self) -> Result<(Vec<TextBox>, (f64, f64), String), String> {
        let (png, size) = self.capture().await?;
        let found = tokio::task::spawn_blocking(move || super::ocr::recognize(&png))
            .await
            .map_err(|e| e.to_string())??;
        let boxes = found
            .into_iter()
            .map(|r| r.into_box(size.0, size.1))
            .collect();
        Ok((
            boxes,
            size,
            "This screen never settles (a video or an animation), so its accessibility tree is not available; the text was recognized in the picture and may be misread.".to_owned(),
        ))
    }

    #[cfg(not(target_os = "macos"))]
    async fn pixel_texts(&mut self) -> Result<(Vec<TextBox>, (f64, f64), String), String> {
        Err("The accessibility tree is not available on this screen (it never settles); take a screenshot instead.".to_owned())
    }

    async fn tree(&mut self) -> Result<Vec<uitree::Node>, TreeError> {
        let mut last = String::new();
        for attempt in 0..3u64 {
            let out = self
                .exec(&["exec-out", "uiautomator", "dump", "/dev/tty"], SLOW)
                .await
                .map_err(TreeError::Failed)?;
            let text = String::from_utf8_lossy(&out).into_owned();
            if let Some(nodes) = uitree::parse(&text) {
                self.tree_busy_until = None;
                return Ok(nodes);
            }
            last = text.trim().to_owned();
            if last.contains("idle") {
                self.tree_busy_until = Some(Instant::now() + TREE_BUSY_FOR);
                return Err(TreeError::Busy("The accessibility tree is not available on this screen (uiautomator: could not get idle state); take a screenshot instead.".to_owned()));
            }
            tokio::time::sleep(Duration::from_millis(500 * (attempt + 1))).await;
        }
        Err(TreeError::Failed(format!(
            "uiautomator could not read the screen: {}",
            if last.is_empty() { "empty dump" } else { &last }
        )))
    }

    /// The foreground app's package.
    pub async fn current_app(&mut self) -> Option<String> {
        let out = self
            .shell(
                "dumpsys activity activities | grep -E -m2 'topResumedActivity|mResumedActivity'",
            )
            .await
            .ok()?;
        parse_resumed(&out)
    }

    async fn point(&mut self, fx: f64, fy: f64) -> Result<(i64, i64), String> {
        let (width, height) = self.current_size().await?;
        Ok(((fx * width).round() as i64, (fy * height).round() as i64))
    }

    pub async fn tap(&mut self, fx: f64, fy: f64) -> Result<(), String> {
        self.gate().await?;
        let (x, y) = self.point(fx, fy).await?;
        self.shell(&format!("input tap {x} {y}")).await.map(drop)
    }

    pub async fn long_press(&mut self, fx: f64, fy: f64, seconds: f64) -> Result<(), String> {
        self.gate().await?;
        let (x, y) = self.point(fx, fy).await?;
        let ms = (seconds * 1000.0).round() as i64;
        self.shell(&format!("input swipe {x} {y} {x} {y} {ms}"))
            .await
            .map(drop)
    }

    pub async fn drag(
        &mut self,
        from: (f64, f64),
        to: (f64, f64),
        seconds: f64,
    ) -> Result<(), String> {
        self.gate().await?;
        let (x1, y1) = self.point(from.0, from.1).await?;
        let (x2, y2) = self.point(to.0, to.1).await?;
        let ms = (seconds * 1000.0).round().max(1.0) as i64;
        self.shell(&format!("input swipe {x1} {y1} {x2} {y2} {ms}"))
            .await
            .map(drop)
    }

    /// Scroll without a fling: touch down, move in steps, hold still, lift, so the content moves
    /// the same distance every time and a list walk skips no rows. `(dx, dy)` is in content
    /// space, as fractions of the screen: a negative `dy` reveals what is further down.
    pub async fn scroll(&mut self, fx: f64, fy: f64, dx: f64, dy: f64) -> Result<(), String> {
        self.gate().await?;
        let (width, height) = self.current_size().await?;
        let keep = |v: f64, size: f64| v.clamp(size * 0.06, size * 0.94);
        let (cx, cy) = (fx * width, fy * height);
        let (ddx, ddy) = (dx * width, dy * height);
        let x1 = keep(cx - ddx / 2.0, width);
        let y1 = keep(cy - ddy / 2.0, height);
        let x2 = keep(cx + ddx / 2.0, width);
        let y2 = keep(cy + ddy / 2.0, height);
        const STEPS: i64 = 8;
        if self.motionevents != Some(false) {
            let moves: Vec<String> = (1..=STEPS)
                .map(|i| {
                    let t = i as f64 / STEPS as f64;
                    format!(
                        "input motionevent MOVE {} {}",
                        (x1 + (x2 - x1) * t).round() as i64,
                        (y1 + (y2 - y1) * t).round() as i64
                    )
                })
                .collect();
            let command = format!(
                "input motionevent DOWN {} {} && {} && sleep 0.2 && input motionevent UP {} {}",
                x1.round() as i64,
                y1.round() as i64,
                moves.join(" && "),
                x2.round() as i64,
                y2.round() as i64
            );
            match self.shell(&command).await {
                Ok(out) if !out.contains("Error") && !out.contains("Unknown") => {
                    self.motionevents = Some(true);
                    return Ok(());
                }
                Ok(_) | Err(_) if self.motionevents == Some(true) => {
                    return Err("The scroll gesture failed on the phone.".to_owned());
                }
                _ => self.motionevents = Some(false),
            }
        }
        // Older Android without `motionevent`: a swipe slow enough to coast little
        let travel = (x2 - x1).abs().max((y2 - y1).abs());
        let ms = ((travel * 4.0) as i64).max(600);
        self.shell(&format!(
            "input swipe {} {} {} {} {ms}",
            x1.round() as i64,
            y1.round() as i64,
            x2.round() as i64,
            y2.round() as i64
        ))
        .await
        .map(drop)
    }

    /// Type ASCII text: `input text` takes one token, so spaces travel as `%s` and newlines and
    /// tabs as key presses.
    pub async fn type_text(&mut self, text: &str) -> Result<(), String> {
        if let Some(c) = text
            .chars()
            .find(|c| !(c.is_ascii_graphic() || matches!(c, ' ' | '\n' | '\t' | '\r')))
        {
            return Err(format!(
                "adb can type only plain ASCII text on Android, and the text has '{c}'. Type it in parts that are ASCII, or ask the user to type that part."
            ));
        }
        self.gate().await?;
        let mut run = String::new();
        for c in text.chars() {
            match c {
                '\n' | '\r' | '\t' => {
                    self.flush_text(&mut run).await?;
                    let key = if c == '\t' {
                        "KEYCODE_TAB"
                    } else {
                        "KEYCODE_ENTER"
                    };
                    self.shell(&format!("input keyevent {key}")).await?;
                }
                _ => run.push(c),
            }
            if run.len() >= 200 {
                self.flush_text(&mut run).await?;
            }
        }
        self.flush_text(&mut run).await
    }

    async fn flush_text(&mut self, run: &mut String) -> Result<(), String> {
        if run.is_empty() {
            return Ok(());
        }
        let token = run.replace(' ', "%s");
        run.clear();
        self.shell(&format!("input text {}", adb::shell_quote(&token)))
            .await
            .map(drop)
    }

    pub async fn key(&mut self, name: &str) -> Result<String, String> {
        if name.trim().len() > 1 && name.contains('+') {
            return Err(format!(
                "Android cannot press chords such as \"{name}\": adb presses one key at a time."
            ));
        }
        let code = key_code(name).ok_or_else(|| {
            format!("Android has no key named \"{name}\". Use enter, delete, tab, escape, back, home, menu, up, down, left, right, volume_up, volume_down, power, search, or a single letter or digit.")
        })?;
        self.gate().await?;
        self.shell(&format!("input keyevent {code}")).await?;
        Ok(code)
    }

    pub async fn home(&mut self) -> Result<(), String> {
        self.gate().await?;
        self.shell("input keyevent KEYCODE_HOME").await?;
        tokio::time::sleep(Duration::from_millis(500)).await;
        Ok(())
    }

    pub async fn back(&mut self) -> Result<(), String> {
        self.gate().await?;
        self.shell("input keyevent KEYCODE_BACK").await?;
        tokio::time::sleep(Duration::from_millis(300)).await;
        Ok(())
    }

    pub async fn app_switcher(&mut self) -> Result<(), String> {
        self.gate().await?;
        self.shell("input keyevent KEYCODE_APP_SWITCH").await?;
        tokio::time::sleep(Duration::from_millis(500)).await;
        Ok(())
    }

    pub async fn list_apps(&mut self, include_system: bool) -> Result<Vec<String>, String> {
        let out = self
            .shell(if include_system {
                "pm list packages"
            } else {
                "pm list packages -3"
            })
            .await?;
        let mut packages: Vec<String> = out
            .lines()
            .filter_map(|line| line.trim().strip_prefix("package:"))
            .map(|p| p.trim().to_owned())
            .filter(|p| !p.is_empty())
            .collect();
        packages.sort();
        Ok(packages)
    }

    /// Open an app by package id or by the name a person says; returns the package opened.
    pub async fn open_app(&mut self, name: &str) -> Result<String, String> {
        self.gate().await?;
        let packages = self.list_apps(true).await?;
        let package = match_package(name, &packages);
        let Some(package) = package else {
            if let Some(opened) = self.open_by_label(name).await? {
                return Ok(opened);
            }
            let installed = self.list_apps(false).await.unwrap_or_default();
            return Err(format!(
                "No installed app matches \"{name}\". Installed apps: {}. Pass one of these package ids.",
                if installed.is_empty() {
                    "none besides the system's".to_owned()
                } else {
                    installed.join(", ")
                }
            ));
        };
        let out = self
            .shell(&format!(
                "cmd package resolve-activity --brief -c android.intent.category.LAUNCHER {}",
                adb::shell_quote(&package)
            ))
            .await
            .unwrap_or_default();
        let component = out
            .lines()
            .rev()
            .map(str::trim)
            .find(|line| line.contains('/') && !line.contains(' '));
        match component {
            Some(component) => {
                self.shell(&format!("am start -W -n {}", adb::shell_quote(component)))
                    .await?;
            }
            None => {
                let out = self
                    .shell(&format!(
                        "monkey -p {} -c android.intent.category.LAUNCHER 1",
                        adb::shell_quote(&package)
                    ))
                    .await?;
                if out.contains("No activities found") || out.contains("aborted") {
                    return Err(format!("{package} has no screen to open."));
                }
            }
        }
        Ok(package)
    }

    /// Tap the icon labeled `name` on the home screen, else in the app drawer.
    async fn open_by_label(&mut self, name: &str) -> Result<Option<String>, String> {
        let wanted = name.trim().to_lowercase();
        self.home().await?;
        let launcher = self.current_app().await;
        for drawer in [false, true] {
            if drawer {
                let (width, height) = self.current_size().await?;
                self.shell(&format!(
                    "input swipe {} {} {} {} 250",
                    (width / 2.0) as i64,
                    (height * 0.8) as i64,
                    (width / 2.0) as i64,
                    (height * 0.25) as i64
                ))
                .await?;
                tokio::time::sleep(Duration::from_secs(1)).await;
            }
            let Ok(nodes) = self.tree().await else {
                continue;
            };
            let hit = nodes.iter().find(|n| {
                let label = if n.text.trim().is_empty() {
                    &n.desc
                } else {
                    &n.text
                };
                label.trim().to_lowercase() == wanted
            });
            if let Some(hit) = hit {
                let (x, y) = ((hit.left + hit.right) / 2, (hit.top + hit.bottom) / 2);
                self.shell(&format!("input tap {x} {y}")).await?;
                for _ in 0..20 {
                    tokio::time::sleep(Duration::from_millis(250)).await;
                    let now = self.current_app().await;
                    if now.is_some() && now != launcher {
                        return Ok(now);
                    }
                }
            }
        }
        self.home().await?;
        Ok(None)
    }

    /// Pair a phone with Wireless debugging's pairing code, then connect it.
    pub async fn pair(&mut self, code: &str, address: Option<&str>) -> Result<String, String> {
        let code: String = code.chars().filter(|c| !c.is_whitespace()).collect();
        if code.len() != 6 || !code.chars().all(|c| c.is_ascii_digit()) {
            return Err("pair_android needs `text`: the six-digit code from the phone's \"Pair device with pairing code\" dialog.".to_owned());
        }
        let address = match address.map(str::trim).filter(|a| !a.is_empty()) {
            Some(address) => address.to_owned(),
            None => {
                let mut found = None;
                for _ in 0..30 {
                    let out = self.run(&["mdns", "services"], QUICK).await?;
                    if let Some(service) =
                        adb::parse_mdns(&out.text(), "pairing").into_iter().next()
                    {
                        found = Some(service.address);
                        break;
                    }
                    tokio::time::sleep(Duration::from_secs(1)).await;
                }
                found.ok_or("No phone is offering to pair on this network. Ask the user to keep the \"Pair device with pairing code\" dialog open on a phone on the same Wi‑Fi, or to read you the IP address and port shown in it (pass them as `address`).")?
            }
        };
        let out = self
            .run(&["pair", &address, &code], Duration::from_secs(30))
            .await?;
        if !out.text().contains("Successfully paired") {
            return Err(format!(
                "Pairing with {address} failed: {}",
                if out.message().is_empty() {
                    "no answer".to_owned()
                } else {
                    out.message()
                }
            ));
        }
        let host = address
            .rsplit_once(':')
            .map(|(host, _)| host.to_owned())
            .unwrap_or_default();
        let mut connected = None;
        for _ in 0..10 {
            let services = self
                .run(&["mdns", "services"], QUICK)
                .await
                .map(|out| adb::parse_mdns(&out.text(), "connect"))
                .unwrap_or_default();
            if let Some(service) = services.into_iter().find(|s| s.host == host) {
                let out = self.run(&["connect", &service.address], QUICK).await?;
                let text = out.text();
                if text.contains("connected") && !text.contains("cannot") {
                    connected = Some(service.address);
                    break;
                }
            }
            tokio::time::sleep(Duration::from_secs(1)).await;
        }
        self.forget();
        let Some(connected) = connected else {
            return Ok(format!(
                "Paired with {address}, but the phone's connection port was not found on this network yet. Ask the user to turn Wireless debugging off and on, then use connect."
            ));
        };
        self.serial = Some(connected.clone());
        self.transport = Some(Transport::Wifi);
        self.model = self.model_of(&connected).await;
        Ok(format!(
            "Paired and connected the {} ({connected}). From now on it is found by itself while Wireless debugging is on.",
            self.describe()
        ))
    }
}

enum TreeError {
    /// The screen never goes idle; reading the picture is the way.
    Busy(String),
    Failed(String),
}

/// The package of an installed app that `name` means.
fn match_package(name: &str, packages: &[String]) -> Option<String> {
    let name = name.trim();
    if packages.iter().any(|p| p == name) {
        return Some(name.to_owned());
    }
    let wanted: String = name
        .to_lowercase()
        .chars()
        .filter(|c| c.is_ascii_alphanumeric())
        .collect();
    if wanted.is_empty() {
        return None;
    }
    if let Some((_, ids)) = APP_IDS.iter().find(|(alias, _)| *alias == wanted)
        && let Some(id) = ids.iter().find(|id| packages.iter().any(|p| p == *id))
    {
        return Some((*id).to_owned());
    }
    let mut hits: Vec<&String> = packages
        .iter()
        .filter(|p| p.to_lowercase().replace('.', "").contains(&wanted))
        .collect();
    // The shortest is the least qualified: com.android.chrome before com.android.chrome.helper
    hits.sort_by_key(|p| p.len());
    hits.first().map(|p| (*p).clone())
}

fn parse_wm_size(out: &str) -> Option<(f64, f64)> {
    let find = |label: &str| {
        out.lines().find_map(|line| {
            let rest = line.trim().strip_prefix(label)?.trim();
            let (w, h) = rest.split_once('x')?;
            Some((w.trim().parse::<f64>().ok()?, h.trim().parse::<f64>().ok()?))
        })
    };
    find("Override size:").or_else(|| find("Physical size:"))
}

fn parse_resumed(out: &str) -> Option<String> {
    out.lines().find_map(|line| {
        let record = line.split("ActivityRecord{").nth(1)?;
        record
            .split_whitespace()
            .find(|part| part.contains('/'))
            .and_then(|component| component.split('/').next())
            .map(str::to_owned)
    })
}

/// A PNG's width and height from its header.
pub fn png_size(png: &[u8]) -> Option<(u32, u32)> {
    if png.get(..8)? != b"\x89PNG\r\n\x1a\n" || png.get(12..16)? != b"IHDR" {
        return None;
    }
    let width = u32::from_be_bytes(png.get(16..20)?.try_into().ok()?);
    let height = u32::from_be_bytes(png.get(20..24)?.try_into().ok()?);
    (width > 0 && height > 0).then_some((width, height))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keys_map_to_key_codes() {
        assert_eq!(key_code("Enter").as_deref(), Some("KEYCODE_ENTER"));
        assert_eq!(key_code("delete").as_deref(), Some("KEYCODE_DEL"));
        assert_eq!(key_code("volume up").as_deref(), Some("KEYCODE_VOLUME_UP"));
        assert_eq!(key_code("a").as_deref(), Some("KEYCODE_A"));
        assert_eq!(key_code("7").as_deref(), Some("KEYCODE_7"));
        assert_eq!(key_code("hyper"), None);
    }

    #[test]
    fn apps_are_found_by_id_alias_and_fragment() {
        let installed: Vec<String> = [
            "com.android.chrome",
            "com.android.chrome.helper",
            "com.zhiliaoapp.musically",
            "com.android.settings",
        ]
        .into_iter()
        .map(String::from)
        .collect();
        assert_eq!(
            match_package("com.android.settings", &installed).as_deref(),
            Some("com.android.settings")
        );
        assert_eq!(
            match_package("TikTok", &installed).as_deref(),
            Some("com.zhiliaoapp.musically")
        );
        assert_eq!(
            match_package("chrome", &installed).as_deref(),
            Some("com.android.chrome")
        );
        assert_eq!(match_package("Weather", &installed), None);
        assert_eq!(match_package("  ", &installed), None);
    }

    #[test]
    fn screen_sizes_prefer_the_override() {
        assert_eq!(
            parse_wm_size("Physical size: 1080x2400\nOverride size: 720x1600\n"),
            Some((720.0, 1600.0))
        );
        assert_eq!(
            parse_wm_size("Physical size: 1080x2400"),
            Some((1080.0, 2400.0))
        );
        assert_eq!(parse_wm_size("error"), None);
    }

    #[test]
    fn the_foreground_app_is_read_from_the_activity_record() {
        let out = "  topResumedActivity=ActivityRecord{8e1c2f u0 com.android.chrome/org.chromium.chrome.browser.ChromeTabbedActivity t42}\n";
        assert_eq!(parse_resumed(out).as_deref(), Some("com.android.chrome"));
        assert_eq!(parse_resumed("nothing"), None);
    }

    #[test]
    fn png_headers_give_the_size() {
        let mut png = b"\x89PNG\r\n\x1a\n\0\0\0\rIHDR".to_vec();
        png.extend_from_slice(&1080u32.to_be_bytes());
        png.extend_from_slice(&2400u32.to_be_bytes());
        assert_eq!(png_size(&png), Some((1080, 2400)));
        assert_eq!(png_size(b"GIF89a"), None);
    }

    #[test]
    fn unreachable_phones_say_what_the_user_must_do() {
        assert!(not_reachable(&[]).contains("USB debugging"));
        let unauthorized = Attached {
            id: "x".into(),
            state: "unauthorized".into(),
            transport: Transport::Usb,
        };
        assert!(not_reachable(&[unauthorized]).contains("Allow"));
    }
}
