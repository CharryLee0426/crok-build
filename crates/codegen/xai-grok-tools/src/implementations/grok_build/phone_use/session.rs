//! The phone as Crok uses it: one action at a time, and one Crok process at a time.
//!
//! Every point the model sends is a pixel of the latest look (a screenshot or `read_screen`) at
//! that phone. Points become fractions of the screen before a backend sees them, so an iPhone
//! window that moved since the look is still hit where the model chose.

use std::sync::{Arc, LazyLock};
use std::time::Duration;

use super::android::AndroidState;
use super::iphone::IphoneState;
use super::text::{self, TextBox};
use super::{PhoneAction, PhoneDevice, PhoneInput};
use crate::implementations::grok_build::browser_use::ScrollDirection;
use crate::implementations::grok_build::device_use::screenshot::{self, Scale};
use crate::implementations::grok_build::device_use::{
    BatchHalt, DeviceActionResult, PHONE_HALT_TEXT, capped_result_text, checked_duration,
    format_seconds, one_line, truncate_chars,
};

/// How long a process's claim on the phone outlives its last action.
pub const CLAIM_IDLE: Duration = Duration::from_secs(120);
const MAX_WAIT_SECS: f64 = 60.0;
const MAX_PRESS_SECS: f64 = 10.0;

/// The phone as a session's `Resources` hold it; one per process.
#[derive(Clone)]
pub struct PhoneSessionHandle(pub Arc<PhoneSession>);

static SESSION: LazyLock<Arc<PhoneSession>> = LazyLock::new(Arc::default);

impl PhoneSessionHandle {
    pub fn shared() -> Self {
        Self(Arc::clone(&SESSION))
    }
}

#[derive(Default)]
pub struct PhoneSession {
    halt: BatchHalt,
    state: tokio::sync::Mutex<State>,
}

#[derive(Default)]
struct State {
    /// The phone this process last used, which a call with no `device` keeps using.
    device: Option<PhoneDevice>,
    /// The latest look, which every point the model sends refers to.
    look: Option<Look>,
    android: AndroidState,
    iphone: IphoneState,
}

#[derive(Debug, Clone, Copy)]
struct Look {
    device: PhoneDevice,
    scale: Scale,
}

impl PhoneSession {
    /// Run one call. `batch` identifies the model response it came from.
    pub async fn run(&self, batch: Option<u64>, input: PhoneInput) -> DeviceActionResult {
        let name = input.action.name();
        if self.halt.is_halted(batch) {
            return DeviceActionResult::error(name, PHONE_HALT_TEXT);
        }
        let mut state = self.state.lock().await;
        let claimed = match input.action {
            PhoneAction::Status | PhoneAction::Wait => Ok(()),
            _ => claim(),
        };
        let result = match claimed {
            Err(refusal) => DeviceActionResult::error(name, refusal),
            Ok(()) => match act(&mut state, &input).await {
                Ok(result) => result,
                Err(error) => DeviceActionResult::error(name, error_text(&error)),
            },
        };
        self.halt.record(batch, result.is_error);
        result
    }
}

fn claim() -> Result<(), String> {
    crate::implementations::grok_build::device_use::claim("phone-use.lock", CLAIM_IDLE, |holder| {
        format!(
            "The phone is in use by another Crok session (process {holder}). It is free once that session has been idle for {} seconds, or has quit.",
            CLAIM_IDLE.as_secs()
        )
    })
}

fn error_text(error: &str) -> String {
    let error = error.trim();
    if error.starts_with("Error") {
        error.to_owned()
    } else {
        format!("Error: {error}")
    }
}

/// The phone a call drives: the one it names, the one this process last used, an Android phone
/// adb can already reach, else the iPhone where there can be one.
async fn choose(state: &mut State, wanted: Option<PhoneDevice>) -> PhoneDevice {
    if let Some(device) = wanted.or(state.device) {
        return device;
    }
    if state.android.ready_without_setup().await {
        return PhoneDevice::Android;
    }
    if cfg!(target_os = "macos") {
        PhoneDevice::Iphone
    } else {
        PhoneDevice::Android
    }
}

/// How a look of a screen `width`×`height` (in the phone's units) is sized for the model: an
/// Android screenshot keeps its pixels within the model limits; an iPhone window in points is
/// shown at the Retina resolution it is captured at.
fn scale_for(device: PhoneDevice, width: f64, height: f64) -> Scale {
    match device {
        PhoneDevice::Android => Scale::for_source(width, height),
        PhoneDevice::Iphone => {
            let (image_width, image_height) = screenshot::fit_size(
                (width * 2.0).round().max(1.0) as u32,
                (height * 2.0).round().max(1.0) as u32,
            );
            Scale {
                source_width: width.max(1.0),
                source_height: height.max(1.0),
                image_width,
                image_height,
            }
        }
    }
}

fn label(device: PhoneDevice) -> &'static str {
    device.label()
}

async fn act(state: &mut State, input: &PhoneInput) -> Result<DeviceActionResult, String> {
    let name = input.action.name();
    match input.action {
        PhoneAction::Status => {
            let iphone = state.iphone.status().await;
            let android = state.android.status().await;
            let using = match state.device {
                Some(device) => format!(
                    "\nThis session uses the {} unless a call names another `device`.",
                    label(device)
                ),
                None => String::new(),
            };
            return Ok(DeviceActionResult::ok(
                name,
                format!("{iphone}\n{android}{using}"),
            ));
        }
        PhoneAction::Wait => {
            let seconds = checked_duration("wait", input.duration, MAX_WAIT_SECS)?;
            tokio::time::sleep(Duration::from_secs_f64(seconds)).await;
            return Ok(DeviceActionResult::ok(
                name,
                format!("Waited {}s.", format_seconds(seconds)),
            ));
        }
        PhoneAction::PairAndroid => {
            let code = input
                .text
                .as_deref()
                .ok_or("pair_android needs `text`: the six-digit pairing code")?;
            let text = state.android.pair(code, input.address.as_deref()).await?;
            state.device = Some(PhoneDevice::Android);
            state.look = None;
            return Ok(DeviceActionResult::ok(name, text));
        }
        _ => {}
    }
    let device = choose(state, input.device).await;
    let result = act_on(state, device, input).await;
    if result.is_ok() || input.device.is_some() {
        state.device = Some(device);
    }
    result
}

/// A point the model sent, as a fraction of the screen of `device`'s latest look.
fn fraction(state: &State, device: PhoneDevice, point: [f64; 2]) -> Result<(f64, f64), String> {
    let look = state
        .look
        .filter(|look| look.device == device)
        .ok_or_else(|| {
            format!(
                "There is no screenshot or read_screen of the {} yet, and coordinates are pixels of the latest one. Take one first, or tap by `text`.",
                label(device)
            )
        })?;
    let (x, y) = look.scale.to_source(point[0], point[1])?;
    Ok((x / look.scale.source_width, y / look.scale.source_height))
}

fn amount(input: &PhoneInput, default: f64) -> Result<f64, String> {
    let amount = input.amount.unwrap_or(default);
    if !amount.is_finite() || !(0.05..=1.0).contains(&amount) {
        return Err(format!(
            "`amount` is a fraction of the screen from 0.05 to 1, not {amount}"
        ));
    }
    Ok(amount)
}

fn seconds(input: &PhoneInput, default: f64, action: &str) -> Result<f64, String> {
    match input.duration {
        None => Ok(default),
        Some(_) => checked_duration(action, input.duration, MAX_PRESS_SECS),
    }
}

/// Where the model's target is: a coordinate, or visible text that is read fresh.
async fn target(
    state: &mut State,
    device: PhoneDevice,
    input: &PhoneInput,
) -> Result<((f64, f64), String), String> {
    if let Some(point) = input.coordinate {
        let at = fraction(state, device, point)?;
        return Ok((
            at,
            format!("({}, {})", point[0].round() as i64, point[1].round() as i64),
        ));
    }
    let Some(query) = input.text.as_deref().filter(|q| !q.trim().is_empty()) else {
        return Err(format!(
            "{} needs `coordinate` [x, y] or `text`, the visible text to touch",
            input.action.name()
        ));
    };
    let (boxes, (width, height), _) = texts(state, device).await?;
    let hits = text::find(&boxes, query, input.exact.unwrap_or(false));
    if hits.is_empty() {
        return Err(text::no_match(query, &boxes));
    }
    let index = usize::try_from(input.index.unwrap_or(0)).unwrap_or(usize::MAX);
    let hit = hits.get(index).ok_or_else(|| {
        format!(
            "\"{}\" matches {} visible text{}; `index` counts from 0, so it must be below {}.",
            one_line(query),
            hits.len(),
            if hits.len() == 1 { "" } else { "s" },
            hits.len()
        )
    })?;
    let scale = scale_for(device, width, height);
    let (x, y) = scale.to_image(hit.x, hit.y);
    let named = if hit.text.is_empty() {
        hit.id.clone().unwrap_or_default()
    } else {
        truncate_chars(&one_line(&hit.text), 60)
    };
    Ok((
        (hit.x / width, hit.y / height),
        format!("\"{named}\" at ({x}, {y})"),
    ))
}

/// Read the screen's text and make it the latest look.
async fn texts(
    state: &mut State,
    device: PhoneDevice,
) -> Result<(Vec<TextBox>, (f64, f64), String), String> {
    let found = match device {
        PhoneDevice::Iphone => state.iphone.texts().await?,
        PhoneDevice::Android => state.android.texts().await?,
    };
    let (width, height) = found.1;
    state.look = Some(Look {
        device,
        scale: scale_for(device, width, height),
    });
    Ok(found)
}

/// The gesture of a swipe: a flick from one side of `at` to the other, in finger motion.
fn swipe_path(
    direction: ScrollDirection,
    distance: f64,
    at: (f64, f64),
) -> ((f64, f64), (f64, f64)) {
    let (dx, dy) = match direction {
        ScrollDirection::Left => (-distance, 0.0),
        ScrollDirection::Right => (distance, 0.0),
        ScrollDirection::Up => (0.0, -distance),
        ScrollDirection::Down => (0.0, distance),
    };
    let keep = |v: f64| v.clamp(0.02, 0.98);
    (
        (keep(at.0 - dx / 2.0), keep(at.1 - dy / 2.0)),
        (keep(at.0 + dx / 2.0), keep(at.1 + dy / 2.0)),
    )
}

/// A scroll's content-space delta: what to reveal, as a fraction of the screen; a negative `dy`
/// reveals what is further down.
fn scroll_delta(direction: ScrollDirection, amount: f64) -> (f64, f64) {
    match direction {
        ScrollDirection::Down => (0.0, -amount),
        ScrollDirection::Up => (0.0, amount),
        ScrollDirection::Right => (-amount, 0.0),
        ScrollDirection::Left => (amount, 0.0),
    }
}

async fn act_on(
    state: &mut State,
    device: PhoneDevice,
    input: &PhoneInput,
) -> Result<DeviceActionResult, String> {
    let name = input.action.name();
    let phone = label(device);
    let text = match input.action {
        PhoneAction::Connect => {
            state.look = None;
            match device {
                PhoneDevice::Iphone => state.iphone.connect().await?,
                PhoneDevice::Android => state.android.connect().await?,
            }
        }
        PhoneAction::Screenshot => {
            let (png, (width, height)) = match device {
                PhoneDevice::Iphone => state.iphone.capture().await?,
                PhoneDevice::Android => state.android.capture().await?,
            };
            let scale = scale_for(device, width, height);
            let fitted = tokio::task::spawn_blocking(move || {
                let image = screenshot::decode(&png)?;
                screenshot::encode_resized(&image, scale.image_width, scale.image_height)
            })
            .await
            .map_err(|e| e.to_string())??;
            state.look = Some(Look { device, scale });
            let text = format!(
                "Screenshot of the {phone} as a {}x{} image. Coordinates in tap and the other actions are pixels of this image.",
                fitted.width, fitted.height
            );
            return Ok(DeviceActionResult::ok(name, text).with_image(fitted));
        }
        PhoneAction::ReadScreen => {
            let (boxes, (width, height), note) = texts(state, device).await?;
            let scale = scale_for(device, width, height);
            let listed = text::describe(&boxes, &scale);
            let body = if listed.is_empty() {
                "(no text on the screen; take a screenshot to see it)".to_owned()
            } else {
                listed
            };
            let text = format!(
                "Text on the {phone}'s screen with tap-ready centres, as pixels of a {}x{} screenshot. {note}\n{body}",
                scale.image_width, scale.image_height
            );
            return Ok(DeviceActionResult::ok(
                name,
                capped_result_text(text, "Scroll or zoom in on part of the screen."),
            ));
        }
        PhoneAction::Tap => {
            let ((fx, fy), what) = target(state, device, input).await?;
            match device {
                PhoneDevice::Iphone => state.iphone.tap(fx, fy).await?,
                PhoneDevice::Android => state.android.tap(fx, fy).await?,
            }
            format!("Tapped {what}.")
        }
        PhoneAction::LongPress => {
            let hold = seconds(input, 0.8, "long_press")?;
            let ((fx, fy), what) = target(state, device, input).await?;
            match device {
                PhoneDevice::Iphone => state.iphone.long_press(fx, fy, hold).await?,
                PhoneDevice::Android => state.android.long_press(fx, fy, hold).await?,
            }
            format!("Long-pressed {what} for {}s.", format_seconds(hold))
        }
        PhoneAction::Swipe => {
            let direction = input
                .direction
                .ok_or("swipe needs `direction`, the finger's motion: up, down, left or right")?;
            let distance = amount(input, 0.4)?;
            let at = match input.coordinate {
                Some(point) => fraction(state, device, point)?,
                None => (0.5, 0.5),
            };
            let (from, to) = swipe_path(direction, distance, at);
            match device {
                PhoneDevice::Iphone => state.iphone.drag(from, to, 0.12).await?,
                PhoneDevice::Android => state.android.drag(from, to, 0.12).await?,
            }
            format!("Swiped {}.", direction.as_str())
        }
        PhoneAction::Scroll => {
            let direction = input.direction.ok_or(
                "scroll needs `direction`, the content to reveal: down, up, left or right",
            )?;
            let amount = amount(input, 0.5)?;
            let at = match input.coordinate {
                Some(point) => fraction(state, device, point)?,
                None => (0.5, 0.5),
            };
            let (dx, dy) = scroll_delta(direction, amount);
            match device {
                PhoneDevice::Iphone => state.iphone.scroll(at.0, at.1, dx, dy).await?,
                PhoneDevice::Android => state.android.scroll(at.0, at.1, dx, dy).await?,
            }
            format!("Scrolled {}.", direction.as_str())
        }
        PhoneAction::Drag => {
            let (Some(start), Some(end)) = (input.start_coordinate, input.coordinate) else {
                return Err(
                    "drag needs `start_coordinate` [x, y] and `coordinate` [x, y], where it ends"
                        .to_owned(),
                );
            };
            let from = fraction(state, device, start)?;
            let to = fraction(state, device, end)?;
            let hold = seconds(input, 0.6, "drag")?.max(0.05);
            match device {
                PhoneDevice::Iphone => state.iphone.drag(from, to, hold).await?,
                PhoneDevice::Android => state.android.drag(from, to, hold).await?,
            }
            "Dragged.".to_owned()
        }
        PhoneAction::Type => {
            let typed = input
                .text
                .as_deref()
                .filter(|t| !t.is_empty())
                .ok_or("type needs `text`, the text to type")?;
            match device {
                PhoneDevice::Iphone => state.iphone.type_text(typed).await?,
                PhoneDevice::Android => state.android.type_text(typed).await?,
            }
            "Typed. Check with read_screen that it went into the field you meant.".to_owned()
        }
        PhoneAction::Key => {
            let key = input
                .text
                .as_deref()
                .filter(|t| !t.trim().is_empty())
                .ok_or("key needs `text`: a key such as \"enter\" or \"delete\"")?;
            match device {
                PhoneDevice::Iphone => state.iphone.key(key).await?,
                PhoneDevice::Android => state.android.key(key).await?,
            };
            format!("Pressed {}.", one_line(key))
        }
        PhoneAction::Home => {
            match device {
                PhoneDevice::Iphone => state.iphone.home().await?,
                PhoneDevice::Android => state.android.home().await?,
            }
            "Went to the Home Screen.".to_owned()
        }
        PhoneAction::Back => match device {
            PhoneDevice::Iphone => {
                return Err("iOS has no Back button. Tap the app's own back control (usually at the top left), or swipe right from the left edge.".to_owned());
            }
            PhoneDevice::Android => {
                state.android.back().await?;
                "Went back.".to_owned()
            }
        },
        PhoneAction::AppSwitcher => {
            match device {
                PhoneDevice::Iphone => state.iphone.app_switcher().await?,
                PhoneDevice::Android => state.android.app_switcher().await?,
            }
            "Opened the app switcher.".to_owned()
        }
        PhoneAction::OpenApp => {
            let app = input
                .text
                .as_deref()
                .filter(|t| !t.trim().is_empty())
                .ok_or("open_app needs `text`, the app's name")?;
            match device {
                PhoneDevice::Iphone => {
                    state.iphone.open_app(app).await?;
                    format!(
                        "Searched for \"{}\" in Spotlight and opened the top result. Check with read_screen that the right app is open.",
                        one_line(app)
                    )
                }
                PhoneDevice::Android => {
                    let package = state.android.open_app(app).await?;
                    format!("Opened {package}.")
                }
            }
        }
        PhoneAction::ListApps => match device {
            PhoneDevice::Iphone => {
                return Err("iPhone Mirroring does not list the iPhone's apps. Use open_app with the app's name; Spotlight finds it.".to_owned());
            }
            PhoneDevice::Android => {
                let apps = state.android.list_apps(false).await?;
                if apps.is_empty() {
                    "No apps besides the system's are installed.".to_owned()
                } else {
                    format!("Installed apps (package ids):\n{}", apps.join("\n"))
                }
            }
        },
        PhoneAction::Status | PhoneAction::Wait | PhoneAction::PairAndroid => {
            unreachable!("handled before a phone is chosen")
        }
    };
    Ok(DeviceActionResult::ok(name, text))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn iphone_looks_are_shown_at_retina_size() {
        let scale = scale_for(PhoneDevice::Iphone, 330.0, 715.0);
        assert_eq!((scale.image_width, scale.image_height), (660, 1430));
        let android = scale_for(PhoneDevice::Android, 1080.0, 2400.0);
        assert!(android.image_height <= screenshot::MAX_EDGE);
    }

    #[test]
    fn points_need_a_look_of_the_same_phone() {
        let mut state = State::default();
        assert!(fraction(&state, PhoneDevice::Android, [10.0, 10.0]).is_err());
        state.look = Some(Look {
            device: PhoneDevice::Iphone,
            scale: scale_for(PhoneDevice::Iphone, 300.0, 600.0),
        });
        assert!(fraction(&state, PhoneDevice::Android, [10.0, 10.0]).is_err());
        let (fx, fy) = fraction(&state, PhoneDevice::Iphone, [300.0, 600.0]).unwrap();
        assert!((fx - 0.5).abs() < 1e-9 && (fy - 0.5).abs() < 1e-9);
        assert!(fraction(&state, PhoneDevice::Iphone, [601.0, 10.0]).is_err());
    }

    #[test]
    fn swipes_are_finger_motion_and_scrolls_are_content() {
        let (from, to) = swipe_path(ScrollDirection::Up, 0.4, (0.5, 0.5));
        assert!(to.1 < from.1, "a swipe up moves the finger up");
        assert_eq!(scroll_delta(ScrollDirection::Down, 0.5), (0.0, -0.5));
        assert_eq!(scroll_delta(ScrollDirection::Left, 0.3), (0.3, 0.0));
        let (from, to) = swipe_path(ScrollDirection::Left, 1.0, (0.1, 0.5));
        assert!(from.0 <= 0.98 && to.0 >= 0.02);
    }

    #[test]
    fn amounts_and_holds_are_refused_out_of_range() {
        let mut input = PhoneInput::new(PhoneAction::Scroll);
        assert_eq!(amount(&input, 0.5), Ok(0.5));
        input.amount = Some(2.0);
        assert!(amount(&input, 0.5).is_err());
        input.duration = Some(11.0);
        assert!(seconds(&input, 0.8, "long_press").is_err());
    }

    #[tokio::test]
    async fn status_and_wait_run_without_a_phone() {
        let session = PhoneSession::default();
        let mut wait = PhoneInput::new(PhoneAction::Wait);
        wait.duration = Some(0.0);
        let result = session.run(None, wait).await;
        assert!(!result.is_error, "{}", result.text);
        assert_eq!(result.text, "Waited 0s.");
        let result = session
            .run(None, PhoneInput::new(PhoneAction::Status))
            .await;
        assert!(!result.is_error);
        assert!(
            result.text.contains("iPhone:") && result.text.contains("Android:"),
            "{}",
            result.text
        );
    }

    #[tokio::test]
    async fn a_failed_call_halts_the_rest_of_its_batch() {
        let session = PhoneSession::default();
        let mut too_long = PhoneInput::new(PhoneAction::Wait);
        too_long.duration = Some(61.0);
        let first = session.run(Some(7), too_long).await;
        assert!(first.is_error, "{}", first.text);
        assert!(first.text.starts_with("Error: "), "{}", first.text);
        let second = session
            .run(Some(7), PhoneInput::new(PhoneAction::Status))
            .await;
        assert_eq!(second.text, PHONE_HALT_TEXT);
        let later = session
            .run(Some(8), PhoneInput::new(PhoneAction::Status))
            .await;
        assert_ne!(later.text, PHONE_HALT_TEXT);
    }
}
