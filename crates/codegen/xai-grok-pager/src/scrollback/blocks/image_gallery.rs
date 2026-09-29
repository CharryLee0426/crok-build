//! Images shown inline under a block's text: prompt attachments, image reads, MCP and other tool results, and images an
//! agent reply links.
//!
//! Laid out the way pi lays out tool images: a spacer row, then the image, left-aligned under the block's text and at
//! most [`GALLERY_MAX_COLS`] wide. The rows are blank lines at the end of the block's `output()`, so the block's band
//! and accent span them and heights stay exact; the draw loop paints the pixels into them. On terminals without
//! scrollback graphics each image is one `[Image: path [mime] W×H]` line instead.

use ratatui::style::{Color, Style};
use ratatui::text::{Line, Span};

use crate::prompt_images::{InlineMediaInfo, ScrollbackImageRef};
use crate::scrollback::block::AnchoredMedia;
use crate::scrollback::types::{BlockLine, Selectable};
use crate::theme::Theme;

/// Widest an inline image gets, in cells (pi's default `imageWidthCells`).
pub const GALLERY_MAX_COLS: u16 = 60;

/// Size and placement of a block's inline images.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct GallerySpec {
    /// Tallest an image gets, in rows.
    pub max_rows: u16,
    /// Columns between the block's left edge and the images, so they line up with the text above them.
    pub indent: u16,
    /// Band color the block paints behind its text, carried onto the image rows.
    pub background: Option<Color>,
}

impl GallerySpec {
    /// Tool results and images in replies.
    pub const fn tool(indent: u16) -> Self {
        Self {
            max_rows: 16,
            indent,
            background: None,
        }
    }

    /// Prompt attachments: smaller, since the prompt text is what the reader scans for.
    pub const fn prompt(indent: u16, background: Option<Color>) -> Self {
        Self {
            max_rows: 10,
            indent,
            background,
        }
    }
}

/// Whether images are drawn as pixels in the scrollback (Kitty-family terminals outside minimal mode).
pub fn graphics_active() -> bool {
    crate::terminal::image::scrollback_inline_overlay_active()
}

/// `(cols, rows)` an image occupies in a block `width` cells wide.
pub fn image_cells(image: &ScrollbackImageRef, width: u16, spec: GallerySpec) -> (u16, u16) {
    let max_cols = width
        .saturating_sub(spec.indent)
        .saturating_sub(2)
        .clamp(1, GALLERY_MAX_COLS);
    // Unknown size: pi's 800×600 fallback
    let (w, h) = image.dimensions.unwrap_or((800, 600));
    crate::terminal::image::fit_image_to_cells(w, h, max_cols, spec.max_rows.max(1))
}

/// Trailing lines a block appends for its images.
pub fn gallery_lines(
    images: &[ScrollbackImageRef],
    width: u16,
    spec: GallerySpec,
) -> Vec<BlockLine> {
    if images.is_empty() {
        return Vec::new();
    }
    let with_band = |line: BlockLine| match spec.background {
        Some(color) => line.with_background(color),
        None => line,
    };
    let blank = || {
        with_band(BlockLine {
            content: Line::default(),
            selectable: Selectable::None,
            ..Default::default()
        })
    };
    let mut lines = Vec::new();
    if graphics_active() {
        for image in images {
            let (_, rows) = image_cells(image, width, spec);
            lines.extend((0..=rows).map(|_| blank()));
        }
    } else {
        for image in images {
            lines.push(with_band(fallback_line(image, spec.indent)));
        }
    }
    lines
}

/// pi's placeholder for an image the terminal can't draw: `[Image: ~/shot.png [image/png] 800×600]`.
fn fallback_line(image: &ScrollbackImageRef, indent: u16) -> BlockLine {
    let theme = Theme::current();
    let dim = Style::default().fg(theme.gray_dim);
    // `ScrollbackImageRef` only admits known image extensions, so the name is enough
    let ext = image
        .path
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();
    let mime = match ext.as_str() {
        "jpg" | "jpeg" => "image/jpeg".to_owned(),
        "tif" => "image/tiff".to_owned(),
        other => format!("image/{other}"),
    };
    let mut detail = format!(" [{mime}]");
    if let Some((w, h)) = image.dimensions {
        detail.push_str(&format!(" {w}\u{d7}{h}"));
    }
    detail.push(']');
    let path = crate::recent_dirs::display_path(&image.path);
    BlockLine {
        content: Line::from(vec![
            Span::raw(" ".repeat(indent as usize)),
            Span::styled("[Image: ", dim),
            Span::styled(path, Style::default().fg(theme.path)),
            Span::styled(detail, dim),
        ]),
        selectable: Selectable::Spans(1..4),
        link_target: Some(crate::render::osc8::LinkTarget::File(std::sync::Arc::from(
            image.path.as_path(),
        ))),
        ..Default::default()
    }
}

/// Where each image sits among a block's rows. `content_lines` is the block's full output line count (images included)
/// and `vpad_top` its top padding row, so offsets are measured from the entry's first row.
pub fn gallery_placements(
    images: &[ScrollbackImageRef],
    width: u16,
    spec: GallerySpec,
    content_lines: usize,
    vpad_top: u16,
) -> Vec<AnchoredMedia> {
    if images.is_empty() || !graphics_active() {
        return Vec::new();
    }
    let cells: Vec<(u16, u16)> = images.iter().map(|i| image_cells(i, width, spec)).collect();
    let total: usize = cells.iter().map(|&(_, rows)| rows as usize + 1).sum();
    let Some(start) = content_lines.checked_sub(total) else {
        return Vec::new();
    };
    let mut row = vpad_top as usize + start;
    images
        .iter()
        .zip(cells)
        .filter_map(|(image, (cols, rows))| {
            // Skip the spacer row above each image
            row += 1;
            let offset = u16::try_from(row).ok()?;
            row += rows as usize;
            let (w, h) = image.dimensions?;
            Some(AnchoredMedia {
                info: InlineMediaInfo {
                    path: image.path.clone(),
                    width: w,
                    height: h,
                    is_video: false,
                    alt_text: image.alt_text.clone(),
                },
                row_offset: offset,
                rows,
                gallery: Some(GalleryCell {
                    indent: spec.indent,
                    cols,
                }),
            })
        })
        .collect()
}

/// Rows the off-screen height estimate adds for a block's images (their largest size, so it never under-reserves).
pub fn estimate_rows(images: &[ScrollbackImageRef], spec: GallerySpec) -> u16 {
    let per_image = if graphics_active() {
        spec.max_rows.saturating_add(1)
    } else {
        1
    };
    per_image.saturating_mul(u16::try_from(images.len()).unwrap_or(u16::MAX))
}

/// Horizontal placement of a gallery image inside its block.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct GalleryCell {
    pub indent: u16,
    pub cols: u16,
}

#[cfg(test)]
mod tests {
    use super::*;

    fn image(w: u32, h: u32) -> ScrollbackImageRef {
        ScrollbackImageRef {
            path: std::path::PathBuf::from("/tmp/x.png"),
            dimensions: Some((w, h)),
            alt_text: String::new(),
        }
    }

    #[test]
    fn images_are_capped_at_sixty_columns_and_the_row_budget() {
        let spec = GallerySpec::tool(2);
        let (cols, rows) = image_cells(&image(4000, 1000), 200, spec);
        assert!(cols <= GALLERY_MAX_COLS, "{cols}");
        assert!(rows <= spec.max_rows);
        let (_, rows) = image_cells(&image(1000, 4000), 200, spec);
        assert_eq!(rows, spec.max_rows);
    }

    #[test]
    fn narrow_blocks_shrink_images_to_fit() {
        let (cols, _) = image_cells(&image(800, 600), 20, GallerySpec::tool(2));
        assert!(cols <= 16, "{cols}");
    }
}
