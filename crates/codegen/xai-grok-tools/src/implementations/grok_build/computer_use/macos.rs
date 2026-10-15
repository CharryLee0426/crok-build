//! The macOS desktop: screenshots with `screencapture`, input with CoreGraphics events.
//!
//! Everything here acts on the main display, in points (the units of `CGDisplayBounds`, which
//! CoreGraphics events also use). macOS attributes Screen Recording and Accessibility to the app
//! responsible for this process: the terminal running `crok`, or Crok Desktop.

use std::ffi::c_void;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

type CGEventRef = *mut c_void;
type CGEventSourceRef = *mut c_void;
type CFTypeRef = *const c_void;

#[repr(C)]
#[derive(Debug, Clone, Copy)]
struct CGPoint {
    x: f64,
    y: f64,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
struct CGSize {
    width: f64,
    height: f64,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
struct CGRect {
    origin: CGPoint,
    size: CGSize,
}

#[link(name = "CoreGraphics", kind = "framework")]
unsafe extern "C" {
    fn CGMainDisplayID() -> u32;
    fn CGDisplayBounds(display: u32) -> CGRect;
    fn CGEventCreate(source: CGEventSourceRef) -> CGEventRef;
    fn CGEventGetLocation(event: CGEventRef) -> CGPoint;
    fn CGEventCreateMouseEvent(
        source: CGEventSourceRef,
        kind: u32,
        position: CGPoint,
        button: u32,
    ) -> CGEventRef;
    fn CGEventCreateKeyboardEvent(source: CGEventSourceRef, keycode: u16, down: bool)
    -> CGEventRef;
    fn CGEventKeyboardSetUnicodeString(event: CGEventRef, length: usize, string: *const u16);
    fn CGEventSetFlags(event: CGEventRef, flags: u64);
    fn CGEventSetIntegerValueField(event: CGEventRef, field: u32, value: i64);
    fn CGEventCreateScrollWheelEvent2(
        source: CGEventSourceRef,
        units: u32,
        wheel_count: u32,
        wheel1: i32,
        wheel2: i32,
        wheel3: i32,
    ) -> CGEventRef;
    fn CGEventPost(tap: u32, event: CGEventRef);
    fn CGEventSourceCreate(state: i32) -> CGEventSourceRef;
    fn CGPreflightScreenCaptureAccess() -> bool;
    fn CGRequestScreenCaptureAccess() -> bool;
}

#[link(name = "ApplicationServices", kind = "framework")]
unsafe extern "C" {
    fn AXIsProcessTrusted() -> bool;
    fn AXIsProcessTrustedWithOptions(options: CFTypeRef) -> bool;
    static kAXTrustedCheckOptionPrompt: CFTypeRef;
}

#[link(name = "CoreFoundation", kind = "framework")]
unsafe extern "C" {
    fn CFRelease(cf: CFTypeRef);
    fn CFDictionaryCreate(
        allocator: CFTypeRef,
        keys: *const CFTypeRef,
        values: *const CFTypeRef,
        count: isize,
        key_callbacks: *const c_void,
        value_callbacks: *const c_void,
    ) -> CFTypeRef;
    static kCFBooleanTrue: CFTypeRef;
    static kCFTypeDictionaryKeyCallBacks: c_void;
    static kCFTypeDictionaryValueCallBacks: c_void;
}

const HID_EVENT_TAP: u32 = 0;
const HID_SYSTEM_STATE: i32 = 1;
const MOUSE_CLICK_STATE: u32 = 1;
const SCROLL_UNIT_LINE: u32 = 1;

pub const LEFT_DOWN: u32 = 1;
pub const LEFT_UP: u32 = 2;
pub const RIGHT_DOWN: u32 = 3;
pub const RIGHT_UP: u32 = 4;
pub const MOVED: u32 = 5;
pub const LEFT_DRAGGED: u32 = 6;
pub const OTHER_DOWN: u32 = 25;
pub const OTHER_UP: u32 = 26;

pub const BUTTON_LEFT: u32 = 0;
pub const BUTTON_RIGHT: u32 = 1;
pub const BUTTON_CENTER: u32 = 2;

pub const SCREEN_RECORDING_REFUSED: &str = "macOS has not allowed Crok to record the screen, so it cannot take screenshots. Ask the user to turn on the app that runs Crok (Crok Desktop, or the terminal running crok) in System Settings › Privacy & Security › Screen & System Audio Recording, then restart that app.";
pub const ACCESSIBILITY_REFUSED: &str = "macOS has not allowed Crok to control the mouse and keyboard. Ask the user to turn on the app that runs Crok (Crok Desktop, or the terminal running crok) in System Settings › Privacy & Security › Accessibility, then try again.";

static ASKED_SCREEN: AtomicBool = AtomicBool::new(false);
static ASKED_ACCESSIBILITY: AtomicBool = AtomicBool::new(false);

/// The main display's size in points.
pub fn display_size() -> (f64, f64) {
    // SAFETY: plain value functions with no preconditions
    let bounds = unsafe { CGDisplayBounds(CGMainDisplayID()) };
    (bounds.size.width.max(1.0), bounds.size.height.max(1.0))
}

/// Screen Recording granted; asks macOS once per process when it is not.
pub fn check_screen_recording() -> Result<(), String> {
    // SAFETY: no preconditions; the request shows the system prompt at most once per app
    if unsafe { CGPreflightScreenCaptureAccess() } {
        return Ok(());
    }
    if !ASKED_SCREEN.swap(true, Ordering::SeqCst) {
        unsafe { CGRequestScreenCaptureAccess() };
    }
    Err(SCREEN_RECORDING_REFUSED.to_owned())
}

/// Accessibility granted; asks macOS once per process when it is not.
pub fn check_accessibility() -> Result<(), String> {
    // SAFETY: no preconditions
    if unsafe { AXIsProcessTrusted() } {
        return Ok(());
    }
    if !ASKED_ACCESSIBILITY.swap(true, Ordering::SeqCst) {
        // SAFETY: a one-entry dictionary of CoreFoundation constants, released after use
        unsafe {
            let keys = [kAXTrustedCheckOptionPrompt];
            let values = [kCFBooleanTrue];
            let options = CFDictionaryCreate(
                std::ptr::null(),
                keys.as_ptr(),
                values.as_ptr(),
                1,
                &raw const kCFTypeDictionaryKeyCallBacks,
                &raw const kCFTypeDictionaryValueCallBacks,
            );
            if !options.is_null() {
                AXIsProcessTrustedWithOptions(options);
                CFRelease(options);
            }
        }
    }
    Err(ACCESSIBILITY_REFUSED.to_owned())
}

/// Whether each permission is granted, without asking.
pub fn permissions() -> (bool, bool) {
    // SAFETY: no preconditions
    unsafe { (CGPreflightScreenCaptureAccess(), AXIsProcessTrusted()) }
}

/// The whole main display, or the rectangle `region` (x, y, width, height in points), as PNG.
pub async fn capture(region: Option<(f64, f64, f64, f64)>) -> Result<Vec<u8>, String> {
    check_screen_recording()?;
    let file = tempfile::Builder::new()
        .prefix("crok-screen-")
        .suffix(".png")
        .tempfile()
        .map_err(|e| format!("could not make a file for the screenshot: {e}"))?;
    let path = file.path().to_path_buf();
    let mut command = tokio::process::Command::new("/usr/sbin/screencapture");
    command.args(["-x", "-t", "png"]);
    match region {
        Some((x, y, width, height)) => {
            command.arg(format!(
                "-R{},{},{},{}",
                x.floor(),
                y.floor(),
                width.ceil().max(1.0),
                height.ceil().max(1.0)
            ));
        }
        None => {
            command.arg("-D1");
        }
    }
    command.arg(&path);
    let status = tokio::time::timeout(Duration::from_secs(15), command.status())
        .await
        .map_err(|_| "screencapture did not finish within 15 s".to_owned())?
        .map_err(|e| format!("could not run screencapture: {e}"))?;
    if !status.success() {
        return Err(format!("screencapture failed ({status})"));
    }
    let bytes = tokio::fs::read(&path)
        .await
        .map_err(|e| format!("could not read the screenshot: {e}"))?;
    if bytes.is_empty() {
        return Err(SCREEN_RECORDING_REFUSED.to_owned());
    }
    Ok(bytes)
}

/// The cursor's position in points.
pub fn cursor() -> (f64, f64) {
    // SAFETY: a null-source event is created only to read the location, then released
    unsafe {
        let event = CGEventCreate(std::ptr::null_mut());
        if event.is_null() {
            return (0.0, 0.0);
        }
        let point = CGEventGetLocation(event);
        CFRelease(event);
        (point.x, point.y)
    }
}

fn post(event: CGEventRef, source: CGEventSourceRef) -> Result<(), String> {
    if event.is_null() {
        if !source.is_null() {
            // SAFETY: created by CGEventSourceCreate
            unsafe { CFRelease(source) };
        }
        return Err("macOS refused to create the input event".to_owned());
    }
    // SAFETY: `event` is a live event this function owns; posting copies it
    unsafe {
        CGEventPost(HID_EVENT_TAP, event);
        CFRelease(event);
        if !source.is_null() {
            CFRelease(source);
        }
    }
    Ok(())
}

/// Post one mouse event at `(x, y)` points.
pub fn mouse(
    kind: u32,
    x: f64,
    y: f64,
    button: u32,
    clicks: i64,
    flags: u64,
) -> Result<(), String> {
    // SAFETY: the event and source are released by `post`
    unsafe {
        let source = CGEventSourceCreate(HID_SYSTEM_STATE);
        let event = CGEventCreateMouseEvent(source, kind, CGPoint { x, y }, button);
        if !event.is_null() {
            if clicks > 0 {
                CGEventSetIntegerValueField(event, MOUSE_CLICK_STATE, clicks);
            }
            if flags != 0 {
                CGEventSetFlags(event, flags);
            }
        }
        post(event, source)
    }
}

/// Post one key event.
pub fn key(code: u16, down: bool, flags: u64) -> Result<(), String> {
    // SAFETY: the event and source are released by `post`
    unsafe {
        let source = CGEventSourceCreate(HID_SYSTEM_STATE);
        let event = CGEventCreateKeyboardEvent(source, code, down);
        if !event.is_null() {
            CGEventSetFlags(event, flags);
        }
        post(event, source)
    }
}

/// Type text whatever the keyboard layout: each chunk travels as the event's Unicode string.
pub fn type_unicode(text: &str) -> Result<(), String> {
    let units: Vec<u16> = text.encode_utf16().collect();
    for chunk in units.chunks(20) {
        for down in [true, false] {
            // SAFETY: `chunk` outlives the call; the event and source are released by `post`
            unsafe {
                let source = CGEventSourceCreate(HID_SYSTEM_STATE);
                let event = CGEventCreateKeyboardEvent(source, 0, down);
                if !event.is_null() {
                    CGEventKeyboardSetUnicodeString(event, chunk.len(), chunk.as_ptr());
                    CGEventSetFlags(event, 0);
                }
                post(event, source)?;
            }
        }
    }
    Ok(())
}

/// Scroll by `vertical` and `horizontal` lines: positive is up and left.
pub fn scroll(vertical: i32, horizontal: i32, flags: u64) -> Result<(), String> {
    // SAFETY: the event and source are released by `post`
    unsafe {
        let source = CGEventSourceCreate(HID_SYSTEM_STATE);
        let event =
            CGEventCreateScrollWheelEvent2(source, SCROLL_UNIT_LINE, 2, vertical, horizontal, 0);
        if !event.is_null() && flags != 0 {
            CGEventSetFlags(event, flags);
        }
        post(event, source)
    }
}
