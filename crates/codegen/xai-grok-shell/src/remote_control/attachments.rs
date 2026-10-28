//! Photos and files of prompts (relay/DESIGN.md §2 and §4, "Photos and files"). A prompt from another device names
//! uploads on the relay: they are downloaded into image blocks and files on disk before it runs. The images of a
//! prompt typed here, or read back from disk, go the other way, into the relay's storage, so every device's
//! transcript shows them.

use std::collections::HashMap;
use std::io::Cursor;

use agent_client_protocol as acp;
use base64::Engine;
use base64::engine::general_purpose::STANDARD as BASE64;
use crok_remote::files;
use crok_remote::link::{CallKind, ToRelay};
use crok_remote::types::{Attachment, AttachmentKind};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use tokio::sync::{mpsc, oneshot};

use super::transcript::{PendingImage, Uploaded, photo_name};

/// Thumbnails for the transcript's previews: at most this many pixels on the longer side.
const THUMB_SIDE: u32 = 480;
const THUMB_QUALITY: u8 = 70;

/// The prompt crok runs for a command from another device: its text, then each attachment, downloaded. An image
/// becomes image content; any other file is saved under `remote/attachments/<session>/<command>/` and linked, the way
/// Crok Desktop attaches files (crok lists it for the model and reads a small text file inline).
pub(crate) async fn prompt_blocks(
    text: &str,
    attachments: &[Attachment],
    session_id: &str,
    command_id: &str,
) -> Result<Vec<acp::ContentBlock>, String> {
    let mut blocks = Vec::new();
    if !text.is_empty() || attachments.is_empty() {
        blocks.push(acp::ContentBlock::Text(acp::TextContent::new(text)));
    }
    let dir = files::attachments_dir(session_id, command_id);
    let mut taken: Vec<String> = Vec::new();
    for attachment in attachments {
        let Some(url) = attachment.url.as_deref() else {
            return Err(format!("{} is no longer on the relay.", attachment.name));
        };
        let bytes = files::download(url, files::MAX_FILE_BYTES)
            .await
            .map_err(|error| {
                format!(
                    "Could not download {} from the relay: {error}",
                    attachment.name
                )
            })?;
        if attachment.kind == AttachmentKind::Image {
            blocks.push(acp::ContentBlock::Image(acp::ImageContent::new(
                BASE64.encode(&bytes),
                attachment.mime_type.clone(),
            )));
            continue;
        }
        let name = unique_name(&files::safe_name(&attachment.name), &taken);
        taken.push(name.clone());
        let path = dir.join(&name);
        let size = bytes.len();
        let saved = async {
            tokio::fs::create_dir_all(&dir).await?;
            tokio::fs::write(&path, bytes).await
        };
        saved
            .await
            .map_err(|error| format!("Could not save {}: {error}", attachment.name))?;
        blocks.push(acp::ContentBlock::ResourceLink(
            acp::ResourceLink::new(name, format!("file://{}", path.display()))
                .mime_type(attachment.mime_type.clone())
                .size(i64::try_from(size).ok()),
        ));
    }
    Ok(blocks)
}

/// `name`, or `name-2.ext`, `name-3.ext`, … when an earlier file of the same prompt took it.
fn unique_name(name: &str, taken: &[String]) -> String {
    if !taken.iter().any(|t| t == name) {
        return name.to_string();
    }
    let (stem, ext) = match name.rfind('.') {
        Some(dot) if dot > 0 => name.split_at(dot),
        _ => (name, ""),
    };
    (2..)
        .map(|n| format!("{stem}-{n}{ext}"))
        .find(|candidate| !taken.contains(candidate))
        .unwrap_or_else(|| name.to_string())
}

/// An image's bytes as they go to the relay, with what the transcript shows of it.
struct Prepared {
    bytes: Vec<u8>,
    sha256: String,
    width: Option<u32>,
    height: Option<u32>,
    thumb: Option<Vec<u8>>,
}

/// Decodes the image (base64) for its size and a small JPEG thumbnail on white. Bytes that do not decode still go,
/// without either.
fn prepare(data: &str) -> Option<Prepared> {
    let bytes = BASE64.decode(data.trim()).ok()?;
    let sha256 = BASE64.encode(Sha256::digest(&bytes));
    let decoded = image::load_from_memory(&bytes).ok();
    let (width, height) = decoded.as_ref().map_or((None, None), |image| {
        (Some(image.width()), Some(image.height()))
    });
    let thumb = decoded.and_then(|image| thumbnail(&image));
    Some(Prepared {
        bytes,
        sha256,
        width,
        height,
        thumb,
    })
}

fn thumbnail(source: &image::DynamicImage) -> Option<Vec<u8>> {
    let small = source.thumbnail(THUMB_SIDE, THUMB_SIDE).to_rgba8();
    let mut flat = image::RgbImage::new(small.width(), small.height());
    for (x, y, pixel) in small.enumerate_pixels() {
        let [r, g, b, a] = pixel.0;
        let alpha = u16::from(a);
        let over = |c: u8| ((u16::from(c) * alpha + 255 * (255 - alpha)) / 255) as u8;
        flat.put_pixel(x, y, image::Rgb([over(r), over(g), over(b)]));
    }
    let mut out = Cursor::new(Vec::new());
    image::codecs::jpeg::JpegEncoder::new_with_quality(&mut out, THUMB_QUALITY)
        .encode_image(&flat)
        .ok()?;
    Some(out.into_inner())
}

async fn call(
    link: &mpsc::UnboundedSender<ToRelay>,
    kind: CallKind,
    path: &str,
    args: Value,
) -> Option<Value> {
    let (reply, answer) = oneshot::channel();
    link.send(ToRelay::Call {
        kind,
        path: path.into(),
        args,
        reply,
    })
    .ok()?;
    tokio::time::timeout(std::time::Duration::from_secs(30), answer)
        .await
        .ok()?
        .ok()?
        .ok()
}

/// Puts a session's images into the relay's storage, each with a thumbnail. With `look_up` (a transcript read from
/// disk), images the relay already holds for the session are linked again instead (`files:known`). An image that
/// cannot go is left out: its item keeps the name without a preview.
pub(crate) async fn upload_images(
    link: mpsc::UnboundedSender<ToRelay>,
    session_id: String,
    images: Vec<PendingImage>,
    look_up: bool,
) -> Vec<Uploaded> {
    let mut prepared = Vec::new();
    for image in images {
        let data = image.data.clone();
        let Ok(Some(ready)) = tokio::task::spawn_blocking(move || prepare(&data)).await else {
            continue;
        };
        prepared.push((image, ready));
    }
    let mut known: HashMap<String, (String, Option<String>)> = HashMap::new();
    if look_up && !prepared.is_empty() {
        let hashes: Vec<&str> = prepared.iter().map(|(_, p)| p.sha256.as_str()).collect();
        let args = json!({ "sessionId": session_id, "sha256": hashes });
        if let Some(Value::Object(found)) = call(&link, CallKind::Query, "files:known", args).await
        {
            for (hash, file) in found {
                if let Some(storage) = file.get("storageId").and_then(Value::as_str) {
                    let thumb = file
                        .get("thumbId")
                        .and_then(Value::as_str)
                        .map(str::to_owned);
                    known.insert(hash, (storage.to_owned(), thumb));
                }
            }
        }
    }
    let mut uploaded = Vec::new();
    for (image, ready) in prepared {
        let size = ready.bytes.len() as f64;
        let (storage_id, thumb_id) = match known.remove(&ready.sha256) {
            Some(found) => found,
            None => {
                let Ok(storage) = files::upload(&link, ready.bytes, &image.mime_type).await else {
                    continue;
                };
                let thumb = match ready.thumb {
                    Some(thumb) => files::upload(&link, thumb, "image/jpeg").await.ok(),
                    None => None,
                };
                (storage, thumb)
            }
        };
        uploaded.push(Uploaded {
            key: image.key,
            index: image.index,
            storage_id,
            thumb_id,
            size,
            width: ready.width.map(f64::from),
            height: ready.height.map(f64::from),
        });
    }
    uploaded
}

/// What a prompt for a session on another computer sends: the typed text, and its images and files, uploaded to the
/// relay first, as `commands:sendPrompt`'s `attachments`. Folders stay here (they mean nothing there); a file that
/// cannot be read, or is too big, fails the prompt.
pub(crate) async fn outgoing(
    link: &mpsc::UnboundedSender<ToRelay>,
    blocks: &[acp::ContentBlock],
    at: f64,
) -> Result<(String, Vec<Value>), String> {
    enum Part {
        Image(PendingImage, String),
        File(Vec<u8>, String, String),
    }
    let mut text: Vec<&str> = Vec::new();
    let mut parts = Vec::new();
    let mut images = 0;
    for block in blocks {
        match block {
            acp::ContentBlock::Text(t) => text.push(&t.text),
            acp::ContentBlock::Image(image) => {
                let name = image
                    .uri
                    .as_deref()
                    .and_then(|uri| uri.rsplit('/').next())
                    .filter(|name| !name.is_empty())
                    .map_or_else(|| photo_name(at, images, &image.mime_type), str::to_owned);
                images += 1;
                let pending = PendingImage {
                    key: String::new(),
                    index: parts.len(),
                    data: image.data.clone(),
                    mime_type: image.mime_type.clone(),
                };
                parts.push(Part::Image(pending, name));
            }
            acp::ContentBlock::ResourceLink(link) => {
                let folder = link
                    .meta
                    .as_ref()
                    .and_then(|meta| meta.get("x.ai/kind"))
                    .and_then(Value::as_str)
                    == Some("directory");
                let Some(path) = link.uri.strip_prefix("file://") else {
                    continue;
                };
                if folder || std::path::Path::new(path).is_dir() {
                    continue;
                }
                let too_big = || {
                    format!(
                        "{} is larger than {} MB.",
                        link.name,
                        files::MAX_FILE_BYTES / (1024 * 1024)
                    )
                };
                let size = tokio::fs::metadata(path)
                    .await
                    .map_err(|error| format!("Could not read {}: {error}", link.name))?
                    .len();
                if size > files::MAX_FILE_BYTES as u64 {
                    return Err(too_big());
                }
                let bytes = tokio::fs::read(path)
                    .await
                    .map_err(|error| format!("Could not read {}: {error}", link.name))?;
                let mime = link
                    .mime_type
                    .clone()
                    .unwrap_or_else(|| mime_for(&link.name).to_string());
                parts.push(Part::File(bytes, link.name.clone(), mime));
            }
            acp::ContentBlock::Resource(resource) => {
                if let acp::EmbeddedResourceResource::TextResourceContents(contents) =
                    &resource.resource
                {
                    let name = contents
                        .uri
                        .rsplit('/')
                        .next()
                        .unwrap_or("file.txt")
                        .to_string();
                    let mime = contents
                        .mime_type
                        .clone()
                        .unwrap_or_else(|| "text/plain".into());
                    parts.push(Part::File(contents.text.clone().into_bytes(), name, mime));
                }
            }
            _ => {}
        }
    }
    if parts.len() > 10 {
        return Err("Up to 10 photos and files per message.".into());
    }
    let mut attachments = Vec::new();
    for part in parts {
        match part {
            Part::Image(pending, name) => {
                let uploaded =
                    upload_images(link.clone(), String::new(), vec![pending], false).await;
                let Some(image) = uploaded.first() else {
                    return Err(format!("Could not upload {name} to the relay."));
                };
                let mut entry = serde_json::Map::new();
                entry.insert("storageId".into(), json!(image.storage_id));
                entry.insert("name".into(), json!(name));
                if let Some(thumb) = &image.thumb_id {
                    entry.insert("thumbId".into(), json!(thumb));
                }
                if let (Some(width), Some(height)) = (image.width, image.height) {
                    entry.insert("width".into(), json!(width));
                    entry.insert("height".into(), json!(height));
                }
                attachments.push(Value::Object(entry));
            }
            Part::File(bytes, name, mime) => {
                let storage = files::upload(link, bytes, &mime)
                    .await
                    .map_err(|error| format!("Could not upload {name} to the relay: {error}"))?;
                attachments.push(json!({ "storageId": storage, "name": name }));
            }
        }
    }
    Ok((text.join("\n").trim().to_string(), attachments))
}

/// A file's type by its extension, for files attached without one.
fn mime_for(name: &str) -> &'static str {
    let ext = name.rsplit('.').next().unwrap_or("").to_ascii_lowercase();
    match ext.as_str() {
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "gif" => "image/gif",
        "webp" => "image/webp",
        "heic" => "image/heic",
        "pdf" => "application/pdf",
        "json" => "application/json",
        "zip" => "application/zip",
        "csv" => "text/csv",
        "html" | "htm" => "text/html",
        "md" | "markdown" => "text/markdown",
        "txt" | "log" | "rs" | "swift" | "kt" | "ts" | "tsx" | "js" | "py" | "go" | "c" | "h"
        | "toml" | "yaml" | "yml" | "sh" => "text/plain",
        _ => "application/octet-stream",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn png(width: u32, height: u32) -> String {
        let image = image::RgbaImage::from_pixel(width, height, image::Rgba([10, 20, 30, 0]));
        let mut out = Cursor::new(Vec::new());
        image::DynamicImage::ImageRgba8(image)
            .write_to(&mut out, image::ImageFormat::Png)
            .expect("png");
        BASE64.encode(out.into_inner())
    }

    #[test]
    fn an_image_gets_its_size_a_thumbnail_on_white_and_the_storage_hash() {
        let data = png(1200, 600);
        let ready = prepare(&data).expect("prepared");
        assert_eq!((ready.width, ready.height), (Some(1200), Some(600)));
        let expected = BASE64.encode(Sha256::digest(BASE64.decode(&data).expect("b64")));
        assert_eq!(ready.sha256, expected);
        let thumb = image::load_from_memory(&ready.thumb.expect("thumb")).expect("jpeg");
        assert_eq!((thumb.width(), thumb.height()), (480, 240));
        let pixel = thumb.to_rgb8().get_pixel(10, 10).0;
        assert!(
            pixel.iter().all(|&c| c > 240),
            "transparent turns white: {pixel:?}"
        );
    }

    #[test]
    fn bytes_that_are_no_image_still_go_without_a_preview() {
        let ready = prepare(&BASE64.encode(b"not an image")).expect("prepared");
        assert!(ready.thumb.is_none() && ready.width.is_none());
        assert!(prepare("%%%").is_none());
    }

    #[test]
    fn files_without_a_type_get_one_by_extension() {
        assert_eq!(mime_for("Notes.MD"), "text/markdown");
        assert_eq!(mime_for("main.rs"), "text/plain");
        assert_eq!(mime_for("archive"), "application/octet-stream");
    }

    #[test]
    fn a_second_file_of_the_same_name_is_numbered() {
        let taken = vec!["a.pdf".to_string(), "a-2.pdf".to_string()];
        assert_eq!(unique_name("b.pdf", &taken), "b.pdf");
        assert_eq!(unique_name("a.pdf", &taken), "a-3.pdf");
        assert_eq!(unique_name("README", &["README".into()]), "README-2");
    }
}
