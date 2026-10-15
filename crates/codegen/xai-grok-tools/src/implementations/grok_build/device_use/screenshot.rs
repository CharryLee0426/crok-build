//! Screenshots sized for models, and the mapping between their pixels and the screen's.
//!
//! The toolsets send no display size: the model works in the pixel space of the images it is
//! shown, and every point it sends back is a pixel in the latest full screenshot. So each
//! screenshot of one surface keeps one size, derived from the surface's own size alone, and
//! [`Scale`] converts the model's points to the surface's units (CSS pixels for a page, points
//! for a display) before an action uses them.

use std::io::Cursor;

use base64::Engine as _;
use image::DynamicImage;
use image::codecs::jpeg::JpegEncoder;
use image::imageops::FilterType;

use crate::types::output::ImageContent;

/// The longest edge an image may have: within the limits of every vision model the harness
/// talks to, the stricter Claude tier included (1568 px on the long edge, about 1.15 megapixels).
pub const MAX_EDGE: u32 = 1568;
/// The most pixels an image may have.
pub const MAX_PIXELS: u64 = 1_150_000;
/// The most bytes one encoded image may take before JPEG is tried at a lower quality.
const MAX_BYTES: usize = 900 * 1024;
const JPEG_QUALITIES: &[u8] = &[85, 75, 60, 45];

/// An encoded image, already within the limits.
#[derive(Debug, Clone)]
pub struct FittedImage {
    /// Base64 bytes, without a `data:` prefix.
    pub data: String,
    pub mime_type: &'static str,
    pub width: u32,
    pub height: u32,
}

impl FittedImage {
    pub fn into_content(self) -> ImageContent {
        ImageContent {
            data: self.data,
            mime_type: self.mime_type.to_owned(),
            annotations: None,
            uri: None,
            meta: Some(serde_json::json!({ "width": self.width, "height": self.height })),
        }
    }
}

/// `width`×`height` scaled down, aspect kept, to fit [`MAX_EDGE`] and [`MAX_PIXELS`]; never up.
pub fn fit_size(width: u32, height: u32) -> (u32, u32) {
    let (w, h) = (f64::from(width.max(1)), f64::from(height.max(1)));
    let edge = (f64::from(MAX_EDGE) / w.max(h)).min(1.0);
    let area = (MAX_PIXELS as f64 / (w * h)).sqrt().min(1.0);
    let factor = edge.min(area);
    let fit = |side: f64| ((side * factor).floor() as u32).max(1);
    (fit(w), fit(h))
}

/// How the model's image pixels relate to a surface's own units.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Scale {
    pub source_width: f64,
    pub source_height: f64,
    pub image_width: u32,
    pub image_height: u32,
}

impl Scale {
    /// The scale every screenshot of a surface this size uses.
    pub fn for_source(source_width: f64, source_height: f64) -> Self {
        let width = source_width.max(1.0).round() as u32;
        let height = source_height.max(1.0).round() as u32;
        let (image_width, image_height) = fit_size(width, height);
        Self {
            source_width: source_width.max(1.0),
            source_height: source_height.max(1.0),
            image_width,
            image_height,
        }
    }

    /// A point in the screenshot, in surface units. A point outside the screenshot is refused:
    /// moving it into range would act where the model did not choose.
    pub fn to_source(&self, x: f64, y: f64) -> Result<(f64, f64), String> {
        let (w, h) = (f64::from(self.image_width), f64::from(self.image_height));
        if !x.is_finite() || !y.is_finite() || x < 0.0 || y < 0.0 || x >= w || y >= h {
            return Err(format!(
                "[{}, {}] is outside the {}x{} screenshot",
                format_number(x),
                format_number(y),
                self.image_width,
                self.image_height
            ));
        }
        Ok((x * self.source_width / w, y * self.source_height / h))
    }

    /// A `zoom` region `[x0, y0, x1, y1]` in screenshot pixels, in surface units. The far corner
    /// may lie on the screenshot's edge.
    pub fn region_to_source(&self, region: [f64; 4]) -> Result<(f64, f64, f64, f64), String> {
        let [x0, y0, x1, y1] = region;
        let (w, h) = (f64::from(self.image_width), f64::from(self.image_height));
        let finite = region.iter().all(|v| v.is_finite());
        if !finite || x0 < 0.0 || y0 < 0.0 || x1 > w || y1 > h || x1 <= x0 || y1 <= y0 {
            return Err(format!(
                "`region` must be [x0, y0, x1, y1] with x0 < x1 and y0 < y1 inside the {}x{} screenshot",
                self.image_width, self.image_height
            ));
        }
        let sx = self.source_width / w;
        let sy = self.source_height / h;
        Ok((x0 * sx, y0 * sy, x1 * sx, y1 * sy))
    }

    /// A surface point in screenshot pixels, as `cursor_position` reports it.
    pub fn to_image(&self, x: f64, y: f64) -> (i64, i64) {
        let px = x * f64::from(self.image_width) / self.source_width;
        let py = y * f64::from(self.image_height) / self.source_height;
        (px.round() as i64, py.round() as i64)
    }
}

fn format_number(value: f64) -> String {
    if value.fract() == 0.0 && value.abs() < 1e15 {
        format!("{}", value as i64)
    } else {
        format!("{value}")
    }
}

/// Decode an encoded screenshot.
pub fn decode(bytes: &[u8]) -> Result<DynamicImage, String> {
    image::load_from_memory(bytes).map_err(|e| format!("the screenshot could not be decoded: {e}"))
}

/// `image` resized to exactly `width`×`height` and encoded as PNG, or as JPEG when PNG is too big.
pub fn encode_resized(
    image: &DynamicImage,
    width: u32,
    height: u32,
) -> Result<FittedImage, String> {
    let resized = if image.width() == width && image.height() == height {
        std::borrow::Cow::Borrowed(image)
    } else {
        std::borrow::Cow::Owned(image.resize_exact(width, height, FilterType::CatmullRom))
    };
    encode(&resized)
}

/// The region `crop` (`x`, `y`, `width`, `height` in `image` pixels), scaled to fit inside
/// `max_width`×`max_height` with its aspect kept, as `zoom` returns it.
pub fn zoom(
    image: &DynamicImage,
    crop: (u32, u32, u32, u32),
    max_width: u32,
    max_height: u32,
) -> Result<FittedImage, String> {
    let (x, y, w, h) = crop;
    let x = x.min(image.width().saturating_sub(1));
    let y = y.min(image.height().saturating_sub(1));
    let w = w.clamp(1, image.width() - x);
    let h = h.clamp(1, image.height() - y);
    let region = image.crop_imm(x, y, w, h);
    let factor = (f64::from(max_width) / f64::from(w)).min(f64::from(max_height) / f64::from(h));
    let out_w = ((f64::from(w) * factor).floor() as u32).max(1);
    let out_h = ((f64::from(h) * factor).floor() as u32).max(1);
    let (out_w, out_h) = {
        let (fw, fh) = fit_size(out_w, out_h);
        (fw.min(out_w), fh.min(out_h))
    };
    encode_resized(&region, out_w, out_h)
}

fn encode(image: &DynamicImage) -> Result<FittedImage, String> {
    let (width, height) = (image.width(), image.height());
    let mut png = Vec::new();
    image
        .write_to(&mut Cursor::new(&mut png), image::ImageFormat::Png)
        .map_err(|e| format!("the screenshot could not be encoded: {e}"))?;
    if png.len() <= MAX_BYTES {
        return Ok(fitted(png, "image/png", width, height));
    }
    let rgb = image.to_rgb8();
    let mut smallest = None;
    for quality in JPEG_QUALITIES {
        let mut jpeg = Vec::new();
        JpegEncoder::new_with_quality(&mut jpeg, *quality)
            .encode_image(&rgb)
            .map_err(|e| format!("the screenshot could not be encoded: {e}"))?;
        if jpeg.len() <= MAX_BYTES {
            return Ok(fitted(jpeg, "image/jpeg", width, height));
        }
        smallest = Some(jpeg);
    }
    // Over the cap even at the lowest quality: send the smallest anyway, the dimensions already fit
    Ok(fitted(smallest.unwrap_or(png), "image/jpeg", width, height))
}

fn fitted(bytes: Vec<u8>, mime_type: &'static str, width: u32, height: u32) -> FittedImage {
    FittedImage {
        data: base64::engine::general_purpose::STANDARD.encode(bytes),
        mime_type,
        width,
        height,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fit_keeps_small_sizes_and_shrinks_large_ones() {
        assert_eq!(fit_size(1280, 800), (1280, 800));
        let (w, h) = fit_size(3024, 1964);
        assert!(u64::from(w) * u64::from(h) <= MAX_PIXELS);
        assert!(w <= MAX_EDGE && h <= MAX_EDGE);
        let ratio = f64::from(w) / f64::from(h);
        assert!((ratio - 3024.0 / 1964.0).abs() < 0.01);
        let (w, _) = fit_size(4000, 300);
        assert!(w <= MAX_EDGE);
    }

    #[test]
    fn scale_maps_points_both_ways_and_refuses_outside() {
        let scale = Scale::for_source(1512.0, 982.0);
        let (sx, sy) = scale
            .to_source(
                f64::from(scale.image_width) / 2.0,
                f64::from(scale.image_height) / 2.0,
            )
            .unwrap();
        assert!((sx - 756.0).abs() < 1.0 && (sy - 491.0).abs() < 1.0);
        let (ix, iy) = scale.to_image(756.0, 491.0);
        assert!((ix - i64::from(scale.image_width / 2)).abs() <= 1);
        assert!((iy - i64::from(scale.image_height / 2)).abs() <= 1);
        let err = scale
            .to_source(f64::from(scale.image_width), 0.0)
            .unwrap_err();
        assert!(err.contains("outside the"));
        assert!(scale.to_source(-1.0, 3.0).is_err());
    }

    #[test]
    fn regions_must_lie_inside_the_screenshot() {
        let scale = Scale::for_source(1280.0, 800.0);
        assert_eq!(
            scale.region_to_source([0.0, 0.0, 1280.0, 800.0]),
            Ok((0.0, 0.0, 1280.0, 800.0))
        );
        assert!(scale.region_to_source([10.0, 10.0, 5.0, 20.0]).is_err());
        assert!(scale.region_to_source([0.0, 0.0, 1281.0, 10.0]).is_err());
    }

    #[test]
    fn encode_and_zoom_fit_the_requested_box() {
        let image = DynamicImage::new_rgba8(400, 300);
        let fitted = encode_resized(&image, 200, 150).unwrap();
        assert_eq!((fitted.width, fitted.height), (200, 150));
        assert_eq!(fitted.mime_type, "image/png");
        let zoomed = zoom(&image, (10, 10, 100, 50), 200, 150).unwrap();
        assert_eq!((zoomed.width, zoomed.height), (200, 100));
    }
}
