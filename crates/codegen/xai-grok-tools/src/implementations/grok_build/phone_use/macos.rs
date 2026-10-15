//! macOS plumbing for iPhone Mirroring: processes, the window list, Accessibility, and events.
//!
//! CoreFoundation values are owned by [`Cf`], which releases them; Accessibility elements are
//! `Cf`s too. Nothing here is sent between threads: the iPhone backend runs it on one blocking
//! thread per call.

use std::ffi::{c_char, c_void};

type CFTypeRef = *const c_void;

#[repr(C)]
#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub struct Point {
    pub x: f64,
    pub y: f64,
}

#[repr(C)]
#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub struct Size {
    pub width: f64,
    pub height: f64,
}

#[repr(C)]
#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub struct Rect {
    pub origin: Point,
    pub size: Size,
}

impl Rect {
    pub fn contains(&self, x: f64, y: f64) -> bool {
        x >= self.origin.x
            && y >= self.origin.y
            && x <= self.origin.x + self.size.width
            && y <= self.origin.y + self.size.height
    }
}

#[link(name = "CoreFoundation", kind = "framework")]
unsafe extern "C" {
    fn CFRelease(cf: CFTypeRef);
    fn CFRetain(cf: CFTypeRef) -> CFTypeRef;
    fn CFGetTypeID(cf: CFTypeRef) -> usize;
    fn CFStringGetTypeID() -> usize;
    fn CFNumberGetTypeID() -> usize;
    fn CFBooleanGetTypeID() -> usize;
    fn CFArrayGetTypeID() -> usize;
    fn CFArrayGetCount(array: CFTypeRef) -> isize;
    fn CFArrayGetValueAtIndex(array: CFTypeRef, index: isize) -> CFTypeRef;
    fn CFDictionaryGetValue(dictionary: CFTypeRef, key: CFTypeRef) -> CFTypeRef;
    fn CFNumberGetValue(number: CFTypeRef, kind: isize, out: *mut c_void) -> bool;
    fn CFBooleanGetValue(boolean: CFTypeRef) -> bool;
    fn CFStringCreateWithBytes(
        allocator: CFTypeRef,
        bytes: *const u8,
        length: isize,
        encoding: u32,
        external: bool,
    ) -> CFTypeRef;
    fn CFStringGetLength(string: CFTypeRef) -> isize;
    fn CFStringGetMaximumSizeForEncoding(length: isize, encoding: u32) -> isize;
    fn CFStringGetCString(
        string: CFTypeRef,
        buffer: *mut c_char,
        size: isize,
        encoding: u32,
    ) -> bool;
    static kCFBooleanTrue: CFTypeRef;
    static kCFBooleanFalse: CFTypeRef;
}

#[link(name = "CoreGraphics", kind = "framework")]
unsafe extern "C" {
    fn CGWindowListCopyWindowInfo(option: u32, relative_to: u32) -> CFTypeRef;
    fn CGRectMakeWithDictionaryRepresentation(dictionary: CFTypeRef, rect: *mut Rect) -> bool;
    static kCGWindowOwnerPID: CFTypeRef;
    static kCGWindowLayer: CFTypeRef;
    static kCGWindowBounds: CFTypeRef;
    static kCGWindowNumber: CFTypeRef;
    static kCGWindowName: CFTypeRef;
    static kCGWindowOwnerName: CFTypeRef;
    fn CGEventSourceCreate(state: i32) -> *mut c_void;
    fn CGEventCreateScrollWheelEvent2(
        source: *mut c_void,
        units: u32,
        wheel_count: u32,
        wheel1: i32,
        wheel2: i32,
        wheel3: i32,
    ) -> *mut c_void;
    fn CGEventCreateKeyboardEvent(source: *mut c_void, keycode: u16, down: bool) -> *mut c_void;
    fn CGEventSetFlags(event: *mut c_void, flags: u64);
    fn CGEventSetLocation(event: *mut c_void, location: Point);
    fn CGEventPost(tap: u32, event: *mut c_void);
}

#[link(name = "ApplicationServices", kind = "framework")]
unsafe extern "C" {
    fn AXUIElementCreateApplication(pid: i32) -> CFTypeRef;
    fn AXUIElementCopyAttributeValue(
        element: CFTypeRef,
        attribute: CFTypeRef,
        value: *mut CFTypeRef,
    ) -> i32;
    fn AXUIElementSetAttributeValue(
        element: CFTypeRef,
        attribute: CFTypeRef,
        value: CFTypeRef,
    ) -> i32;
    fn AXUIElementPerformAction(element: CFTypeRef, action: CFTypeRef) -> i32;
    fn AXUIElementSetMessagingTimeout(element: CFTypeRef, seconds: f32) -> i32;
    fn AXValueGetValue(value: CFTypeRef, kind: u32, out: *mut c_void) -> bool;
}

unsafe extern "C" {
    fn proc_listallpids(buffer: *mut c_void, size: i32) -> i32;
    fn proc_pidpath(pid: i32, buffer: *mut c_void, size: u32) -> i32;
}

const UTF8: u32 = 0x0800_0100;
const NUMBER_FLOAT64: isize = 6;
const AX_POINT: u32 = 1;
const AX_SIZE: u32 = 2;
const HID_EVENT_TAP: u32 = 0;
const HID_SYSTEM_STATE: i32 = 1;
const SCROLL_UNIT_PIXEL: u32 = 0;
const ON_SCREEN_ONLY: u32 = 1;
const EXCLUDE_DESKTOP: u32 = 16;

/// An owned CoreFoundation value, released when dropped.
pub struct Cf(CFTypeRef);

impl Cf {
    /// Take a value returned by a Create or Copy function; `None` for null.
    fn created(value: CFTypeRef) -> Option<Self> {
        (!value.is_null()).then_some(Self(value))
    }

    /// Keep a value borrowed from a container.
    fn retained(value: CFTypeRef) -> Option<Self> {
        if value.is_null() {
            return None;
        }
        // SAFETY: a live CF value; the retain is balanced by Drop
        Some(Self(unsafe { CFRetain(value) }))
    }

    fn raw(&self) -> CFTypeRef {
        self.0
    }

    fn is(&self, type_id: usize) -> bool {
        // SAFETY: a live CF value
        unsafe { CFGetTypeID(self.0) == type_id }
    }
}

impl Drop for Cf {
    fn drop(&mut self) {
        // SAFETY: owned since `created` or `retained`
        unsafe { CFRelease(self.0) }
    }
}

/// A CFString for `text`.
fn cf_string(text: &str) -> Cf {
    // SAFETY: the bytes are valid UTF-8 for the length given
    let value = unsafe {
        CFStringCreateWithBytes(
            std::ptr::null(),
            text.as_ptr(),
            text.len() as isize,
            UTF8,
            false,
        )
    };
    Cf::created(value).expect("CFString from UTF-8")
}

fn string_of(value: CFTypeRef) -> Option<String> {
    // SAFETY: the type is checked before the string is read
    unsafe {
        if value.is_null() || CFGetTypeID(value) != CFStringGetTypeID() {
            return None;
        }
        let length = CFStringGetLength(value);
        let size = CFStringGetMaximumSizeForEncoding(length, UTF8) + 1;
        let mut buffer = vec![0u8; usize::try_from(size).ok()?];
        if !CFStringGetCString(value, buffer.as_mut_ptr().cast(), size, UTF8) {
            return None;
        }
        let end = buffer.iter().position(|&b| b == 0).unwrap_or(buffer.len());
        buffer.truncate(end);
        String::from_utf8(buffer).ok()
    }
}

fn number_of(value: CFTypeRef) -> Option<f64> {
    // SAFETY: the type is checked before the number is read
    unsafe {
        if value.is_null() || CFGetTypeID(value) != CFNumberGetTypeID() {
            return None;
        }
        let mut out = 0f64;
        CFNumberGetValue(value, NUMBER_FLOAT64, (&raw mut out).cast());
        Some(out)
    }
}

fn bool_of(value: CFTypeRef) -> Option<bool> {
    // SAFETY: the type is checked before the value is read
    unsafe {
        if value.is_null() || CFGetTypeID(value) != CFBooleanGetTypeID() {
            return None;
        }
        Some(CFBooleanGetValue(value))
    }
}

/// The pid of a running process whose executable lies under `prefix`.
pub fn pid_under(prefix: &str) -> Option<i32> {
    // SAFETY: the first call sizes the list; the buffer is larger than the count it returned
    unsafe {
        let count = proc_listallpids(std::ptr::null_mut(), 0);
        if count <= 0 {
            return None;
        }
        let mut pids = vec![0i32; usize::try_from(count).ok()? + 64];
        let bytes = i32::try_from(pids.len() * std::mem::size_of::<i32>()).ok()?;
        let filled = proc_listallpids(pids.as_mut_ptr().cast(), bytes);
        let filled = usize::try_from(filled).ok()?.min(pids.len());
        let mut path = vec![0u8; 4 * 1024];
        for &pid in pids.get(..filled)? {
            if pid <= 0 {
                continue;
            }
            let length = proc_pidpath(pid, path.as_mut_ptr().cast(), path.len() as u32);
            let Ok(length) = usize::try_from(length) else {
                continue;
            };
            if let Some(bytes) = path.get(..length)
                && let Ok(text) = std::str::from_utf8(bytes)
                && text.starts_with(prefix)
            {
                return Some(pid);
            }
        }
        None
    }
}

/// One window of the window list.
#[derive(Debug, Clone, PartialEq)]
pub struct WindowInfo {
    pub id: u32,
    pub pid: i32,
    pub layer: i64,
    pub bounds: Rect,
    pub name: Option<String>,
    pub owner: Option<String>,
}

/// The windows, front to back: those on screen, or every window including other Spaces' and
/// minimized ones.
pub fn windows(on_screen_only: bool) -> Vec<WindowInfo> {
    let option = if on_screen_only {
        ON_SCREEN_ONLY | EXCLUDE_DESKTOP
    } else {
        0
    };
    // SAFETY: the copied array is owned by `list`; its dictionaries are read while it lives
    unsafe {
        let Some(list) = Cf::created(CGWindowListCopyWindowInfo(option, 0)) else {
            return Vec::new();
        };
        if !list.is(CFArrayGetTypeID()) {
            return Vec::new();
        }
        let count = CFArrayGetCount(list.raw());
        let mut out = Vec::with_capacity(usize::try_from(count).unwrap_or(0));
        for i in 0..count {
            let entry = CFArrayGetValueAtIndex(list.raw(), i);
            if entry.is_null() {
                continue;
            }
            let get = |key: CFTypeRef| CFDictionaryGetValue(entry, key);
            let (Some(id), Some(pid)) = (
                number_of(get(kCGWindowNumber)),
                number_of(get(kCGWindowOwnerPID)),
            ) else {
                continue;
            };
            let mut bounds = Rect::default();
            let bounds_dictionary = get(kCGWindowBounds);
            if bounds_dictionary.is_null()
                || !CGRectMakeWithDictionaryRepresentation(bounds_dictionary, &raw mut bounds)
            {
                continue;
            }
            out.push(WindowInfo {
                id: id as u32,
                pid: pid as i32,
                layer: number_of(get(kCGWindowLayer)).unwrap_or(0.0) as i64,
                bounds,
                name: string_of(get(kCGWindowName)),
                owner: string_of(get(kCGWindowOwnerName)),
            });
        }
        out
    }
}

/// An Accessibility element.
pub struct Ax(Cf);

impl Ax {
    pub fn application(pid: i32) -> Option<Self> {
        // SAFETY: creates a new element for the pid
        let element = Cf::created(unsafe { AXUIElementCreateApplication(pid) })?;
        // A hung app must not hang the agent: give up on any one request after two seconds
        // SAFETY: a live element
        unsafe { AXUIElementSetMessagingTimeout(element.raw(), 2.0) };
        Some(Self(element))
    }

    fn copy(&self, attribute: &str) -> Option<Cf> {
        let name = cf_string(attribute);
        let mut value: CFTypeRef = std::ptr::null();
        // SAFETY: a live element and attribute name; a copied value is owned by the caller
        let error =
            unsafe { AXUIElementCopyAttributeValue(self.0.raw(), name.raw(), &raw mut value) };
        if error != 0 {
            return None;
        }
        Cf::created(value)
    }

    pub fn string(&self, attribute: &str) -> Option<String> {
        self.copy(attribute).and_then(|v| string_of(v.raw()))
    }

    pub fn boolean(&self, attribute: &str) -> Option<bool> {
        self.copy(attribute).and_then(|v| bool_of(v.raw()))
    }

    /// The elements an array attribute (`AXChildren`, `AXWindows`) holds.
    pub fn elements(&self, attribute: &str) -> Vec<Ax> {
        let Some(array) = self.copy(attribute) else {
            return Vec::new();
        };
        if !array.is(unsafe { CFArrayGetTypeID() }) {
            return Vec::new();
        }
        // SAFETY: a live array; every element kept is retained
        unsafe {
            let count = CFArrayGetCount(array.raw());
            (0..count)
                .filter_map(|i| Cf::retained(CFArrayGetValueAtIndex(array.raw(), i)))
                .map(Ax)
                .collect()
        }
    }

    /// The element's frame in screen points.
    pub fn frame(&self) -> Option<Rect> {
        let position = self.copy("AXPosition")?;
        let size = self.copy("AXSize")?;
        let mut origin = Point::default();
        let mut extent = Size::default();
        // SAFETY: AXValues of the point and size kinds, read into matching structs
        let ok = unsafe {
            AXValueGetValue(position.raw(), AX_POINT, (&raw mut origin).cast())
                && AXValueGetValue(size.raw(), AX_SIZE, (&raw mut extent).cast())
        };
        ok.then_some(Rect {
            origin,
            size: extent,
        })
    }

    pub fn perform(&self, action: &str) -> bool {
        let name = cf_string(action);
        // SAFETY: a live element and action name
        unsafe { AXUIElementPerformAction(self.0.raw(), name.raw()) == 0 }
    }

    pub fn set_bool(&self, attribute: &str, value: bool) -> bool {
        let name = cf_string(attribute);
        // SAFETY: a live element; the CFBoolean constants live for the process
        unsafe {
            let value = if value {
                kCFBooleanTrue
            } else {
                kCFBooleanFalse
            };
            AXUIElementSetAttributeValue(self.0.raw(), name.raw(), value) == 0
        }
    }
}

fn post(event: *mut c_void, source: *mut c_void) -> Result<(), String> {
    // SAFETY: both were created by this module and are released here
    unsafe {
        if event.is_null() {
            if !source.is_null() {
                CFRelease(source);
            }
            return Err("macOS refused to create the input event".to_owned());
        }
        CGEventPost(HID_EVENT_TAP, event);
        CFRelease(event);
        if !source.is_null() {
            CFRelease(source);
        }
    }
    Ok(())
}

/// A pixel-precise scroll at `(x, y)` global points: positive `vertical` scrolls up, positive
/// `horizontal` left, as a scroll wheel does.
pub fn scroll_pixels(x: f64, y: f64, vertical: i32, horizontal: i32) -> Result<(), String> {
    // SAFETY: the event and source are released by `post`
    unsafe {
        let source = CGEventSourceCreate(HID_SYSTEM_STATE);
        let event =
            CGEventCreateScrollWheelEvent2(source, SCROLL_UNIT_PIXEL, 2, vertical, horizontal, 0);
        if !event.is_null() {
            CGEventSetLocation(event, Point { x, y });
        }
        post(event, source)
    }
}

/// One key event with exactly `flags`.
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
