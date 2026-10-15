//! Text recognition with Apple's Vision framework, reached through the Objective-C runtime.
//!
//! Vision is loaded with `dlopen` at the first read, so processes that never use a phone never
//! load it (the same rule the clipboard keeps for AppKit). Every visible string comes back with
//! its box, which becomes a tap target.

use std::ffi::{CStr, c_char, c_void};
use std::sync::OnceLock;

use objc2::encode::{Encode, Encoding};
use objc2::rc::Retained;
use objc2::runtime::{AnyClass, AnyObject, Bool};
use objc2::{msg_send, sel};

use super::text::TextBox;

#[repr(C)]
#[derive(Debug, Clone, Copy, Default)]
struct CGPoint {
    x: f64,
    y: f64,
}

// SAFETY: the layout is CoreGraphics' `CGPoint`, two doubles
unsafe impl Encode for CGPoint {
    const ENCODING: Encoding = Encoding::Struct("CGPoint", &[f64::ENCODING, f64::ENCODING]);
}

#[repr(C)]
#[derive(Debug, Clone, Copy, Default)]
struct CGSize {
    width: f64,
    height: f64,
}

// SAFETY: the layout is CoreGraphics' `CGSize`, two doubles
unsafe impl Encode for CGSize {
    const ENCODING: Encoding = Encoding::Struct("CGSize", &[f64::ENCODING, f64::ENCODING]);
}

#[repr(C)]
#[derive(Debug, Clone, Copy, Default)]
struct CGRect {
    origin: CGPoint,
    size: CGSize,
}

// SAFETY: the layout is CoreGraphics' `CGRect`, a point then a size
unsafe impl Encode for CGRect {
    const ENCODING: Encoding = Encoding::Struct("CGRect", &[CGPoint::ENCODING, CGSize::ENCODING]);
}

/// One recognized string.
#[derive(Debug, Clone, PartialEq)]
pub struct Recognized {
    pub text: String,
    pub confidence: f32,
    /// The box as fractions of the image, origin at the top left: x, y, width, height.
    pub rect: [f64; 4],
}

impl Recognized {
    /// The string as a box on a surface `width`×`height` in its own units.
    pub fn into_box(self, width: f64, height: f64) -> TextBox {
        let [x, y, w, h] = self.rect;
        TextBox::pixels(
            self.text,
            self.confidence,
            (x + w / 2.0) * width,
            (y + h / 2.0) * height,
            w * width,
            h * height,
        )
    }
}

fn vision_loaded() -> bool {
    static LOADED: OnceLock<bool> = OnceLock::new();
    *LOADED.get_or_init(|| {
        let path = c"/System/Library/Frameworks/Vision.framework/Vision";
        // SAFETY: dlopen with a constant NUL-terminated path; the handle is kept for the process
        let handle = unsafe { libc::dlopen(path.as_ptr(), libc::RTLD_LAZY) };
        !handle.is_null()
    })
}

fn class(name: &CStr) -> Result<&'static AnyClass, String> {
    AnyClass::get(name).ok_or_else(|| {
        format!(
            "macOS text recognition is not available here ({} is missing).",
            name.to_string_lossy()
        )
    })
}

/// The text in an encoded image (PNG or JPEG), most legible first as Vision orders it.
pub fn recognize(image: &[u8]) -> Result<Vec<Recognized>, String> {
    if image.is_empty() {
        return Err("There is no picture to read.".to_owned());
    }
    if !vision_loaded() {
        return Err(
            "macOS text recognition (the Vision framework) could not be loaded.".to_owned(),
        );
    }
    objc2::rc::autoreleasepool(|_| {
        let data_class = class(c"NSData")?;
        let dictionary_class = class(c"NSDictionary")?;
        let array_class = class(c"NSArray")?;
        let handler_class = class(c"VNImageRequestHandler")?;
        let request_class = class(c"VNRecognizeTextRequest")?;
        // SAFETY: each message below is sent to an object of the class that declares it, with
        // arguments of the declared types; objects are retained for as long as they are used
        unsafe {
            let data: Option<Retained<AnyObject>> = msg_send![
                data_class,
                dataWithBytes: image.as_ptr().cast::<c_void>(),
                length: image.len()
            ];
            let data = data.ok_or("could not hand the picture to Vision")?;
            let options: Option<Retained<AnyObject>> = msg_send![dictionary_class, dictionary];
            let options = options.ok_or("could not hand the picture to Vision")?;
            let handler: Option<Retained<AnyObject>> = msg_send![
                msg_send![handler_class, alloc],
                initWithData: &*data,
                options: &*options
            ];
            let handler = handler.ok_or("Vision could not open the picture")?;
            let request: Option<Retained<AnyObject>> =
                msg_send![msg_send![request_class, alloc], init];
            let request = request.ok_or("Vision could not start text recognition")?;
            // VNRequestTextRecognitionLevelAccurate
            let _: () = msg_send![&*request, setRecognitionLevel: 0isize];
            let detects: Bool = msg_send![
                &*request,
                respondsToSelector: sel!(setAutomaticallyDetectsLanguage:)
            ];
            if detects.as_bool() {
                let _: () = msg_send![&*request, setAutomaticallyDetectsLanguage: Bool::YES];
            }
            let requests: Option<Retained<AnyObject>> =
                msg_send![array_class, arrayWithObject: &*request];
            let requests = requests.ok_or("could not hand the request to Vision")?;
            let no_error: *mut *mut AnyObject = std::ptr::null_mut();
            let ok: Bool = msg_send![&*handler, performRequests: &*requests, error: no_error];
            if !ok.as_bool() {
                return Err("Vision could not read the screen's picture.".to_owned());
            }
            let results: Option<Retained<AnyObject>> = msg_send![&*request, results];
            let Some(results) = results else {
                return Ok(Vec::new());
            };
            let count: usize = msg_send![&*results, count];
            let mut found = Vec::with_capacity(count);
            for i in 0..count {
                let observation: Option<Retained<AnyObject>> =
                    msg_send![&*results, objectAtIndex: i];
                let Some(observation) = observation else {
                    continue;
                };
                let candidates: Option<Retained<AnyObject>> =
                    msg_send![&*observation, topCandidates: 1usize];
                let Some(candidates) = candidates else {
                    continue;
                };
                let best: Option<Retained<AnyObject>> = msg_send![&*candidates, firstObject];
                let Some(best) = best else {
                    continue;
                };
                let string: Option<Retained<AnyObject>> = msg_send![&*best, string];
                let Some(string) = string else {
                    continue;
                };
                let utf8: *const c_char = msg_send![&*string, UTF8String];
                if utf8.is_null() {
                    continue;
                }
                // SAFETY: UTF8String is NUL-terminated and lives as long as `string`
                let text = CStr::from_ptr(utf8).to_string_lossy().trim().to_owned();
                if text.is_empty() {
                    continue;
                }
                let confidence: f32 = msg_send![&*best, confidence];
                let bounds: CGRect = msg_send![&*observation, boundingBox];
                // Vision's boxes are normalized with the origin at the bottom left
                let rect = [
                    bounds.origin.x.clamp(0.0, 1.0),
                    (1.0 - bounds.origin.y - bounds.size.height).clamp(0.0, 1.0),
                    bounds.size.width.clamp(0.0, 1.0),
                    bounds.size.height.clamp(0.0, 1.0),
                ];
                found.push(Recognized {
                    text,
                    confidence,
                    rect,
                });
            }
            Ok(found)
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn boxes_are_placed_on_the_surface() {
        let r = Recognized {
            text: "Hi".into(),
            confidence: 0.9,
            rect: [0.25, 0.5, 0.5, 0.1],
        };
        let b = r.into_box(200.0, 400.0);
        let close = |a: f64, b: f64| (a - b).abs() < 1e-9;
        assert!(
            close(b.x, 100.0)
                && close(b.y, 220.0)
                && close(b.width, 100.0)
                && close(b.height, 40.0),
            "{b:?}"
        );
    }

    #[test]
    fn reads_text_in_a_rendered_picture() {
        // A black word drawn on white, then read back with Vision
        let mut image = image::RgbImage::from_pixel(240, 80, image::Rgb([255, 255, 255]));
        // A crude "HI" in thick strokes: Vision reads block capitals reliably
        let mut fill = |x0: u32, y0: u32, x1: u32, y1: u32| {
            for x in x0..x1 {
                for y in y0..y1 {
                    image.put_pixel(x, y, image::Rgb([0, 0, 0]));
                }
            }
        };
        fill(60, 15, 72, 65);
        fill(98, 15, 110, 65);
        fill(60, 34, 110, 46);
        fill(140, 15, 152, 65);
        let mut png = Vec::new();
        image::DynamicImage::ImageRgb8(image)
            .write_to(&mut std::io::Cursor::new(&mut png), image::ImageFormat::Png)
            .unwrap();
        let found = recognize(&png).expect("Vision runs");
        let text: String = found.iter().map(|r| r.text.clone()).collect();
        assert!(
            text.to_uppercase().contains("HI") || text.to_uppercase().contains('H'),
            "read {found:?}"
        );
    }
}
