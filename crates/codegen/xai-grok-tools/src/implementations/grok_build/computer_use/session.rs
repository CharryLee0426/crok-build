//! The desktop as Crok uses it: one action at a time, and one Crok process at a time.
//!
//! A process claims the desktop with its first action and keeps the claim while it acts; another
//! Crok process (another task in Crok Desktop, another terminal) is refused until the claim has
//! been idle for [`CLAIM_IDLE`], so two agents never take turns moving one pointer.

use std::sync::{Arc, LazyLock};
use std::time::Duration;

use super::{ComputerAction, ComputerInput};
use crate::implementations::grok_build::device_use::screenshot::Scale;
use crate::implementations::grok_build::device_use::{
    BatchHalt, COMPUTER_HALT_TEXT, ConfirmationFields, DeviceActionResult, fill_confirmation,
};

/// How long a process's claim on the desktop outlives its last action.
pub const CLAIM_IDLE: Duration = Duration::from_secs(120);
const MAX_HOLD_SECS: f64 = 60.0;
const MAX_SCROLL: u32 = 30;

/// The desktop as a session's `Resources` hold it; one per process.
#[derive(Clone)]
pub struct ComputerSessionHandle(pub Arc<ComputerSession>);

static SESSION: LazyLock<Arc<ComputerSession>> = LazyLock::new(Arc::default);

impl ComputerSessionHandle {
    pub fn shared() -> Self {
        Self(Arc::clone(&SESSION))
    }
}

#[derive(Default)]
pub struct ComputerSession {
    halt: BatchHalt,
    state: tokio::sync::Mutex<State>,
}

#[derive(Default)]
struct State {
    /// The scale of the last screenshot; every point the model sends is in its pixels.
    scale: Option<Scale>,
    button_down: bool,
}

impl ComputerSession {
    /// Run one call. `batch` identifies the model response it came from.
    pub async fn run(&self, batch: Option<u64>, input: ComputerInput) -> DeviceActionResult {
        let name = input.action.name();
        if self.halt.is_halted(batch) {
            return DeviceActionResult::error(name, COMPUTER_HALT_TEXT);
        }
        let mut state = self.state.lock().await;
        let result = match claim() {
            Err(refusal) => DeviceActionResult::error(name, refusal),
            Ok(()) => match platform::act(&mut state, &input).await {
                Ok(result) => result,
                Err(error) => DeviceActionResult::error(name, error_text(&error)),
            },
        };
        self.halt.record(batch, result.is_error);
        result
    }
}

/// The acknowledgment for a pure action, filled from its input.
pub(crate) fn confirmation(input: &ComputerInput) -> String {
    let Some(template) = input.action.confirmation() else {
        return "Done.".to_owned();
    };
    fill_confirmation(
        template,
        ConfirmationFields {
            scroll_direction: input.scroll_direction.map(|d| d.as_str()),
            text: input.text.as_deref(),
            duration: input.duration,
            element_ref: None,
        },
    )
}

fn error_text(error: &str) -> String {
    let error = error.trim();
    if error.starts_with("Error") || error.starts_with("macOS") || error.starts_with("Computer use")
    {
        error.to_owned()
    } else {
        format!("Error: {error}")
    }
}

fn claim_path() -> std::path::PathBuf {
    crate::util::grok_home::grok_home().join("computer-use.lock")
}

/// Claim the desktop for this process, or say which process holds it.
fn claim() -> Result<(), String> {
    let path = claim_path();
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let ours = std::process::id();
    if let Ok(contents) = std::fs::read_to_string(&path) {
        let mut fields = contents.split_whitespace();
        let holder = fields.next().and_then(|pid| pid.parse::<u32>().ok());
        let stamp = fields
            .next()
            .and_then(|at| at.parse::<u64>().ok())
            .unwrap_or(0);
        if let Some(holder) = holder
            && holder != ours
            && process_alive(holder)
            && now.saturating_sub(stamp) < CLAIM_IDLE.as_secs()
        {
            return Err(format!(
                "Computer use is in use by another Crok session (process {holder}). It is free once that session has been idle for {} seconds, or has quit.",
                CLAIM_IDLE.as_secs()
            ));
        }
    }
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    std::fs::write(&path, format!("{ours} {now}\n"))
        .map_err(|e| format!("could not claim the desktop: {e}"))
}

#[cfg(unix)]
fn process_alive(pid: u32) -> bool {
    let Ok(pid) = i32::try_from(pid) else {
        return false;
    };
    match nix::sys::signal::kill(nix::unistd::Pid::from_raw(pid), None) {
        Ok(()) => true,
        Err(nix::errno::Errno::EPERM) => true,
        Err(_) => false,
    }
}

#[cfg(not(unix))]
fn process_alive(_pid: u32) -> bool {
    true
}

#[cfg(not(target_os = "macos"))]
mod platform {
    use super::{ComputerInput, State};
    use crate::implementations::grok_build::device_use::DeviceActionResult;

    pub(super) async fn act(
        _state: &mut State,
        _input: &ComputerInput,
    ) -> Result<DeviceActionResult, String> {
        Err("Computer use is available on macOS only.".to_owned())
    }
}

#[cfg(target_os = "macos")]
mod platform {
    use std::time::Duration;

    use super::super::keys::{self, Chord};
    use super::super::macos;
    use super::{ComputerAction, ComputerInput, MAX_HOLD_SECS, MAX_SCROLL, State, confirmation};
    use crate::implementations::grok_build::browser_use::ScrollDirection;
    use crate::implementations::grok_build::device_use::screenshot::{self, Scale};
    use crate::implementations::grok_build::device_use::{
        DeviceActionResult, Modifiers, checked_duration,
    };

    /// Modifier keys pressed for the length of an action, released even if it is cancelled.
    struct Held {
        codes: Vec<(u16, u64)>,
    }

    impl Held {
        fn press(modifiers: Modifiers) -> Result<Self, String> {
            let mut held = Self { codes: Vec::new() };
            let mut cumulative = Modifiers::default();
            for (on, code, name) in [
                (modifiers.ctrl, keys::CONTROL, "ctrl"),
                (modifiers.alt, keys::OPTION, "alt"),
                (modifiers.meta, keys::COMMAND, "cmd"),
                (modifiers.shift, keys::SHIFT, "shift"),
            ] {
                if !on {
                    continue;
                }
                cumulative.set(name);
                let flags = keys::flags(cumulative, false);
                macos::key(code, true, flags)?;
                held.codes.push((code, flags));
            }
            Ok(held)
        }
    }

    impl Drop for Held {
        fn drop(&mut self) {
            for (code, flags) in self.codes.drain(..).rev() {
                let _ = macos::key(code, false, flags);
            }
        }
    }

    /// A key held by `hold_key`, released even if the call is cancelled.
    struct HeldKey {
        code: u16,
        flags: u64,
    }

    impl Drop for HeldKey {
        fn drop(&mut self) {
            let _ = macos::key(self.code, false, self.flags);
        }
    }

    fn scale(state: &mut State) -> Scale {
        *state.scale.get_or_insert_with(|| {
            let (width, height) = macos::display_size();
            Scale::for_source(width, height)
        })
    }

    /// The point a call names, in display points; the pointer's position when it names none.
    fn point(state: &mut State, coordinate: Option<[f64; 2]>) -> Result<(f64, f64), String> {
        match coordinate {
            Some([x, y]) => scale(state).to_source(x, y),
            None => Ok(macos::cursor()),
        }
    }

    async fn pause(ms: u64) {
        tokio::time::sleep(Duration::from_millis(ms)).await;
    }

    pub(super) async fn act(
        state: &mut State,
        input: &ComputerInput,
    ) -> Result<DeviceActionResult, String> {
        let name = input.action.name();
        match input.action {
            ComputerAction::Screenshot => {
                let (width, height) = macos::display_size();
                let target = Scale::for_source(width, height);
                let png = macos::capture(None).await?;
                let fitted = tokio::task::spawn_blocking(move || {
                    let image = screenshot::decode(&png)?;
                    screenshot::encode_resized(&image, target.image_width, target.image_height)
                })
                .await
                .map_err(|e| e.to_string())??;
                state.scale = Some(target);
                let text = format!(
                    "Captured the screen as a {}x{} image.",
                    fitted.width, fitted.height
                );
                return Ok(DeviceActionResult::ok(name, text).with_image(fitted));
            }
            ComputerAction::Zoom => {
                let region = input
                    .region
                    .ok_or("zoom needs `region` [x0, y0, x1, y1] in screenshot pixels")?;
                let current = scale(state);
                let (x0, y0, x1, y1) = current.region_to_source(region)?;
                let png = macos::capture(Some((x0, y0, x1 - x0, y1 - y0))).await?;
                let fitted = tokio::task::spawn_blocking(move || {
                    let image = screenshot::decode(&png)?;
                    let whole = (0, 0, image.width(), image.height());
                    screenshot::zoom(&image, whole, current.image_width, current.image_height)
                })
                .await
                .map_err(|e| e.to_string())??;
                let [a, b, c, d] = region.map(|v| v.round() as i64);
                let text = format!("Zoomed into [{a}, {b}, {c}, {d}] of the screen.");
                return Ok(DeviceActionResult::ok(name, text).with_image(fitted));
            }
            ComputerAction::CursorPosition => {
                let (x, y) = macos::cursor();
                let (x, y) = scale(state).to_image(x, y);
                return Ok(DeviceActionResult::ok(name, format!("X={x},Y={y}")));
            }
            ComputerAction::Wait => {
                let duration = checked_duration("wait", input.duration, MAX_HOLD_SECS)?;
                tokio::time::sleep(Duration::from_secs_f64(duration)).await;
                return Ok(DeviceActionResult::ok(name, confirmation(input)));
            }
            _ => {}
        }

        macos::check_accessibility()?;
        let modifiers = Modifiers::parse(input.click_modifiers())?;
        match input.action {
            ComputerAction::LeftClick
            | ComputerAction::RightClick
            | ComputerAction::MiddleClick
            | ComputerAction::DoubleClick
            | ComputerAction::TripleClick => {
                let (x, y) = point(state, input.coordinate)?;
                let (down, up, button, count) = match input.action {
                    ComputerAction::RightClick => {
                        (macos::RIGHT_DOWN, macos::RIGHT_UP, macos::BUTTON_RIGHT, 1)
                    }
                    ComputerAction::MiddleClick => {
                        (macos::OTHER_DOWN, macos::OTHER_UP, macos::BUTTON_CENTER, 1)
                    }
                    ComputerAction::DoubleClick => {
                        (macos::LEFT_DOWN, macos::LEFT_UP, macos::BUTTON_LEFT, 2)
                    }
                    ComputerAction::TripleClick => {
                        (macos::LEFT_DOWN, macos::LEFT_UP, macos::BUTTON_LEFT, 3)
                    }
                    _ => (macos::LEFT_DOWN, macos::LEFT_UP, macos::BUTTON_LEFT, 1),
                };
                let flags = keys::flags(modifiers, false);
                macos::mouse(macos::MOVED, x, y, macos::BUTTON_LEFT, 0, flags)?;
                pause(40).await;
                let held = Held::press(modifiers)?;
                for clicks in 1..=count {
                    macos::mouse(down, x, y, button, clicks, flags)?;
                    pause(25).await;
                    macos::mouse(up, x, y, button, clicks, flags)?;
                    pause(40).await;
                }
                drop(held);
                state.button_down = false;
            }
            ComputerAction::MouseMove => {
                let coordinate = input
                    .coordinate
                    .ok_or("mouse_move needs `coordinate` [x, y]")?;
                let (x, y) = point(state, Some(coordinate))?;
                let kind = if state.button_down {
                    macos::LEFT_DRAGGED
                } else {
                    macos::MOVED
                };
                macos::mouse(kind, x, y, macos::BUTTON_LEFT, 0, 0)?;
            }
            ComputerAction::LeftClickDrag => {
                let start = input.start_coordinate.ok_or(
                    "left_click_drag needs `start_coordinate` [x, y] and `coordinate` [x, y]",
                )?;
                let end = input
                    .coordinate
                    .ok_or("left_click_drag needs `coordinate` [x, y], where the drag ends")?;
                let (fx, fy) = point(state, Some(start))?;
                let (tx, ty) = point(state, Some(end))?;
                let flags = keys::flags(modifiers, false);
                let held = Held::press(modifiers)?;
                macos::mouse(macos::MOVED, fx, fy, macos::BUTTON_LEFT, 0, flags)?;
                pause(40).await;
                macos::mouse(macos::LEFT_DOWN, fx, fy, macos::BUTTON_LEFT, 1, flags)?;
                const STEPS: u32 = 15;
                for step in 1..=STEPS {
                    let t = f64::from(step) / f64::from(STEPS);
                    macos::mouse(
                        macos::LEFT_DRAGGED,
                        fx + (tx - fx) * t,
                        fy + (ty - fy) * t,
                        macos::BUTTON_LEFT,
                        0,
                        flags,
                    )?;
                    pause(15).await;
                }
                macos::mouse(macos::LEFT_UP, tx, ty, macos::BUTTON_LEFT, 1, flags)?;
                drop(held);
                state.button_down = false;
            }
            ComputerAction::LeftMouseDown | ComputerAction::LeftMouseUp => {
                let (x, y) = point(state, input.coordinate)?;
                let down = input.action == ComputerAction::LeftMouseDown;
                let kind = if down {
                    macos::LEFT_DOWN
                } else {
                    macos::LEFT_UP
                };
                macos::mouse(
                    kind,
                    x,
                    y,
                    macos::BUTTON_LEFT,
                    1,
                    keys::flags(modifiers, false),
                )?;
                state.button_down = down;
            }
            ComputerAction::Scroll => {
                let direction = input
                    .scroll_direction
                    .ok_or("scroll needs `scroll_direction`: up, down, left or right")?;
                let amount = input.scroll_amount.unwrap_or(3);
                if !(1..=MAX_SCROLL).contains(&amount) {
                    return Err(format!(
                        "`scroll_amount` must be 1 to {MAX_SCROLL}, not {amount}"
                    ));
                }
                if let Some(coordinate) = input.coordinate {
                    let (x, y) = point(state, Some(coordinate))?;
                    macos::mouse(macos::MOVED, x, y, macos::BUTTON_LEFT, 0, 0)?;
                    pause(40).await;
                }
                let amount = i32::try_from(amount).unwrap_or(3);
                let (vertical, horizontal) = match direction {
                    ScrollDirection::Up => (amount, 0),
                    ScrollDirection::Down => (-amount, 0),
                    ScrollDirection::Left => (0, amount),
                    ScrollDirection::Right => (0, -amount),
                };
                let held = Held::press(modifiers)?;
                macos::scroll(vertical, horizontal, keys::flags(modifiers, false))?;
                pause(60).await;
                drop(held);
            }
            ComputerAction::Type => {
                let text = input
                    .text
                    .clone()
                    .ok_or("type needs `text`, the text to type")?;
                tokio::task::spawn_blocking(move || type_text(&text))
                    .await
                    .map_err(|e| e.to_string())??;
            }
            ComputerAction::Key => {
                let text = input
                    .text
                    .as_deref()
                    .ok_or("key needs `text`: a key or chord such as \"Return\" or \"cmd+s\"")?;
                let chords = keys::parse_sequence(text)?;
                let repeat = input.repeat.unwrap_or(1);
                if !(1..=100).contains(&repeat) {
                    return Err(format!("`repeat` must be 1 to 100, not {repeat}"));
                }
                tokio::task::spawn_blocking(move || {
                    for _ in 0..repeat {
                        for chord in &chords {
                            press(*chord)?;
                        }
                    }
                    Ok::<(), String>(())
                })
                .await
                .map_err(|e| e.to_string())??;
            }
            ComputerAction::HoldKey => {
                let text = input
                    .text
                    .as_deref()
                    .ok_or("hold_key needs `text`, a key or chord")?;
                let chord = keys::parse_chord(text.trim())?;
                let duration = checked_duration("hold_key", input.duration, MAX_HOLD_SECS)?;
                let held = Held::press(chord.modifiers)?;
                let flags = keys::flags(chord.modifiers, chord.key.shifted);
                macos::key(chord.key.code, true, flags)?;
                let key = HeldKey {
                    code: chord.key.code,
                    flags,
                };
                tokio::time::sleep(Duration::from_secs_f64(duration)).await;
                drop(key);
                drop(held);
            }
            ComputerAction::Screenshot
            | ComputerAction::Zoom
            | ComputerAction::CursorPosition
            | ComputerAction::Wait => unreachable!("handled above"),
        }
        Ok(DeviceActionResult::ok(name, confirmation(input)))
    }

    fn press(chord: Chord) -> Result<(), String> {
        let held = Held::press(chord.modifiers)?;
        let flags = keys::flags(chord.modifiers, chord.key.shifted);
        if chord.key.shifted && !chord.modifiers.shift {
            macos::key(keys::SHIFT, true, flags)?;
        }
        macos::key(chord.key.code, true, flags)?;
        std::thread::sleep(Duration::from_millis(12));
        macos::key(chord.key.code, false, flags)?;
        if chord.key.shifted && !chord.modifiers.shift {
            macos::key(keys::SHIFT, false, keys::flags(chord.modifiers, false))?;
        }
        drop(held);
        std::thread::sleep(Duration::from_millis(12));
        Ok(())
    }

    /// Type `text`: Return and Tab as keys, everything else as Unicode text whatever the layout.
    fn type_text(text: &str) -> Result<(), String> {
        let mut run = String::new();
        let flush = |run: &mut String| -> Result<(), String> {
            if run.is_empty() {
                return Ok(());
            }
            for chunk in run.chars().collect::<Vec<_>>().chunks(16) {
                macos::type_unicode(&chunk.iter().collect::<String>())?;
                std::thread::sleep(Duration::from_millis(8));
            }
            run.clear();
            Ok(())
        };
        for ch in text.chars() {
            match ch {
                '\n' | '\r' | '\t' => {
                    flush(&mut run)?;
                    let code = if ch == '\t' { keys::TAB } else { keys::RETURN };
                    macos::key(code, true, 0)?;
                    std::thread::sleep(Duration::from_millis(12));
                    macos::key(code, false, 0)?;
                    std::thread::sleep(Duration::from_millis(12));
                }
                _ => run.push(ch),
            }
        }
        flush(&mut run)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::implementations::grok_build::browser_use::ScrollDirection;

    #[test]
    fn confirmations_follow_the_registry() {
        let mut input = ComputerInput::new(ComputerAction::Scroll);
        input.scroll_direction = Some(ScrollDirection::Up);
        assert_eq!(confirmation(&input), "Scrolled up.");
        let mut input = ComputerInput::new(ComputerAction::HoldKey);
        input.text = Some("shift".into());
        input.duration = Some(1.5);
        assert_eq!(confirmation(&input), "Held shift for 1.5s.");
        assert_eq!(
            confirmation(&ComputerInput::new(ComputerAction::LeftMouseDown)),
            "Left mouse button pressed."
        );
    }

    #[test]
    fn errors_read_as_errors() {
        assert_eq!(error_text("bad input"), "Error: bad input");
        assert!(error_text("macOS has not allowed Crok").starts_with("macOS"));
    }

    #[test]
    fn a_dead_process_holds_no_claim() {
        assert!(process_alive(std::process::id()));
        assert!(!process_alive(u32::MAX - 7));
    }
}
