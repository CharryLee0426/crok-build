/**
 * Photos and files in prompts (relay/DESIGN.md §5 "Photos and files in prompts"): the rules the composer and the
 * transcript share — limits, which files are images, how big an upload is drawn, what it is called, how sizes read —
 * without the browser APIs, so `scripts/attachments-check.mjs` checks them in node.
 */
import type { Lang } from "./i18n";

export const MAX_ATTACHMENTS = 10;
export const MAX_FILE_BYTES = 20 * 1024 * 1024;
/** A GIF up to this size goes as it is (animation kept); a larger one is its first frame, re-encoded. */
export const MAX_GIF_BYTES = 10 * 1024 * 1024;
/** Longer side of an uploaded image, and of its thumbnail. */
export const MAX_IMAGE_SIDE = 2048;
export const THUMB_SIDE = 480;
export const JPEG_QUALITY = 0.85;
export const THUMB_QUALITY = 0.7;

/** What an item's attachment looks like on screen: the relay's shape with its URLs (null once the upload is gone). */
export type AttachmentView = {
  storageId?: string;
  thumbId?: string;
  name: string;
  mimeType: string;
  size: number;
  kind: "image" | "file";
  width?: number;
  height?: number;
  url: string | null;
  thumbUrl: string | null;
};

/** An uploaded attachment on its way with a prompt: what `commands:sendPrompt` takes, plus what the bubble shows. */
export type OutgoingAttachment = AttachmentView & { storageId: string };

/** `commands:sendPrompt`'s `attachments` entry. */
export function attachmentInput(item: OutgoingAttachment): {
  storageId: string;
  thumbId?: string;
  name: string;
  width?: number;
  height?: number;
} {
  const input: { storageId: string; thumbId?: string; name: string; width?: number; height?: number } = {
    storageId: item.storageId,
    name: item.name,
  };
  if (item.thumbId) input.thumbId = item.thumbId;
  if (item.width) input.width = item.width;
  if (item.height) input.height = item.height;
  return input;
}

/** Items from the relay (stored attachments, with or without URLs) in the shape the transcript draws. */
export function attachmentViews(list: readonly unknown[] | undefined | null): AttachmentView[] {
  if (!list) return [];
  return list.map((raw) => {
    const item = raw as Partial<AttachmentView> & { name?: string };
    return {
      storageId: item.storageId,
      thumbId: item.thumbId,
      name: item.name ?? "file",
      mimeType: item.mimeType ?? "application/octet-stream",
      size: item.size ?? 0,
      kind: item.kind === "image" ? "image" : "file",
      width: item.width,
      height: item.height,
      url: item.url ?? null,
      thumbUrl: item.thumbUrl ?? null,
    };
  });
}

/** Types the relay passes to models as images. */
export const UPLOAD_IMAGE_TYPES = ["image/png", "image/jpeg", "image/gif", "image/webp"] as const;

const EXTENSION_TYPES: Record<string, string> = {
  png: "image/png",
  jpg: "image/jpeg",
  jpeg: "image/jpeg",
  jpe: "image/jpeg",
  gif: "image/gif",
  webp: "image/webp",
  heic: "image/heic",
  heif: "image/heif",
  avif: "image/avif",
  bmp: "image/bmp",
  tif: "image/tiff",
  tiff: "image/tiff",
  svg: "image/svg+xml",
  pdf: "application/pdf",
  txt: "text/plain",
  md: "text/markdown",
  csv: "text/csv",
  json: "application/json",
  html: "text/html",
  xml: "application/xml",
  zip: "application/zip",
  gz: "application/gzip",
  tar: "application/x-tar",
  doc: "application/msword",
  docx: "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
  xls: "application/vnd.ms-excel",
  xlsx: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
  ppt: "application/vnd.ms-powerpoint",
  pptx: "application/vnd.openxmlformats-officedocument.presentationml.presentation",
  mp4: "video/mp4",
  mov: "video/quicktime",
  mp3: "audio/mpeg",
  wav: "audio/wav",
};

/** `report.PDF` → `pdf`; "" without one. */
export function extensionOf(name: string): string {
  const dot = name.lastIndexOf(".");
  if (dot <= 0 || dot === name.length - 1) return "";
  return name.slice(dot + 1).toLowerCase();
}

/** The system's type for a file, else one by its extension, else `application/octet-stream`. */
export function fileType(name: string, type: string | undefined): string {
  const given = (type ?? "").split(";", 1)[0].trim().toLowerCase();
  if (given === "image/jpg" || given === "image/pjpeg") return "image/jpeg";
  if (given) return given;
  return EXTENSION_TYPES[extensionOf(name)] ?? "application/octet-stream";
}

/**
 * Whether a picked file is prepared as an image (re-encoded, with a thumbnail): any raster image type the browser may
 * decode. SVG stays a file (it is text, and models do not read it as an image).
 */
export function isImageType(type: string): boolean {
  return type.startsWith("image/") && type !== "image/svg+xml";
}

/** Fits `width`×`height` into `max` on its longer side (never upscaled), in whole pixels. */
export function fitSize(width: number, height: number, max: number): { width: number; height: number } {
  const w = Math.max(1, Math.round(width));
  const h = Math.max(1, Math.round(height));
  const longer = Math.max(w, h);
  if (longer <= max) return { width: w, height: h };
  const scale = max / longer;
  return { width: Math.max(1, Math.round(w * scale)), height: Math.max(1, Math.round(h * scale)) };
}

/**
 * How an image is uploaded: a GIF of at most 10 MB as it is; anything else re-encoded, as PNG when it is a PNG or has
 * transparency, JPEG otherwise.
 */
export function imagePlan(type: string, size: number, hasAlpha: boolean): { keep: boolean; type: "image/png" | "image/jpeg" | "image/gif" } {
  if (type === "image/gif" && size <= MAX_GIF_BYTES) return { keep: true, type: "image/gif" };
  if (type === "image/png" || hasAlpha) return { keep: false, type: "image/png" };
  return { keep: false, type: "image/jpeg" };
}

const TYPE_EXTENSIONS: Record<string, string> = {
  "image/jpeg": "jpg",
  "image/png": "png",
  "image/gif": "gif",
  "image/webp": "webp",
};

/** The name with its extension changed to the uploaded type's (`IMG_1.HEIC` → `IMG_1.jpg`). */
export function renameForType(name: string, type: string): string {
  const ext = TYPE_EXTENSIONS[type];
  if (!ext) return name;
  const current = extensionOf(name);
  if (current === ext || (ext === "jpg" && current === "jpeg")) return name;
  const base = current ? name.slice(0, name.length - current.length - 1) : name;
  return `${base || "photo"}.${ext}`;
}

function pad(n: number): string {
  return String(n).padStart(2, "0");
}

/** `photo-YYYYMMDD-HHMMSS.jpg` (local time) for a photo without a name; the 2nd, 3rd … of one pick get `-2`, `-3`. */
export function photoName(at: Date, index: number, type = "image/jpeg"): string {
  const stamp = `${at.getFullYear()}${pad(at.getMonth() + 1)}${pad(at.getDate())}-${pad(at.getHours())}${pad(
    at.getMinutes(),
  )}${pad(at.getSeconds())}`;
  const suffix = index > 0 ? `-${index + 1}` : "";
  return `photo-${stamp}${suffix}.${TYPE_EXTENSIONS[type] ?? "jpg"}`;
}

/** A clipboard image's name says nothing ("image.png"): it is a photo without a name. */
export function isPlaceholderName(name: string): boolean {
  return !name || /^image\.(png|jpe?g|gif|webp|bmp|tiff?|heic)$/i.test(name);
}

/** "1.2 MB", "840 KB", "12 B" (1024-based, one decimal below 10 units). */
export function formatSize(bytes: number, lang: Lang): string {
  const units = ["B", "KB", "MB", "GB"];
  let value = Math.max(0, bytes);
  let unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit += 1;
  }
  const digits = unit === 0 || value >= 10 ? 0 : 1;
  const number = new Intl.NumberFormat(lang, { maximumFractionDigits: digits, minimumFractionDigits: 0 }).format(value);
  return `${number} ${units[unit]}`;
}

/** A file row's second line: "1.2 MB · PDF" (the extension in capitals; just the size without one). */
export function fileDetail(name: string, bytes: number, lang: Lang): string {
  const ext = extensionOf(name).toUpperCase();
  return ext ? `${formatSize(bytes, lang)} · ${ext}` : formatSize(bytes, lang);
}

/** `a-very-long-file-n….pdf`: at most `max` characters, keeping the end (the extension) in sight. */
export function middleTruncate(name: string, max: number): string {
  const chars = Array.from(name);
  if (chars.length <= max) return name;
  const tail = Math.max(4, Math.min(12, Math.floor((max - 1) / 3)));
  const head = max - 1 - tail;
  return `${chars.slice(0, head).join("")}…${chars.slice(chars.length - tail).join("")}`;
}

/** The media grid: two square tiles per row, the last one full width when the count is odd (indexes per row). */
export function gridRows(count: number): number[][] {
  const rows: number[][] = [];
  for (let i = 0; i < count; i += 2) rows.push(i + 1 < count ? [i, i + 1] : [i]);
  return rows;
}

/**
 * One image shown whole in a bubble: as wide as `maxWidth`, at most `maxHeight` tall, never narrower than `minWidth`
 * (a very tall image is letterboxed then). Square when the size is unknown.
 */
export function singleImageBox(
  width: number | undefined,
  height: number | undefined,
  maxWidth: number,
  maxHeight: number,
  minWidth = 120,
): { width: number; height: number } {
  const aspect = width && height ? width / height : 1;
  let w = maxWidth;
  let h = w / aspect;
  if (h > maxHeight) {
    h = maxHeight;
    w = h * aspect;
  }
  if (w < minWidth) w = minWidth;
  return { width: Math.round(w), height: Math.round(h) };
}

/** What a picked file becomes, or why it is refused: too many in the strip already, or too big. */
export function admit(
  files: readonly { size: number }[],
  already: number,
): { accepted: number[]; tooMany: boolean; tooBig: boolean } {
  const accepted: number[] = [];
  let tooMany = false;
  let tooBig = false;
  files.forEach((file, index) => {
    if (file.size > MAX_FILE_BYTES) {
      tooBig = true;
      return;
    }
    if (already + accepted.length >= MAX_ATTACHMENTS) {
      tooMany = true;
      return;
    }
    accepted.push(index);
  });
  return { accepted, tooMany, tooBig };
}

/**
 * The relay's attachments with this page's local copies in their place (the same uploads, already in memory), so a
 * prompt sent from here does not flash while its relay URLs load.
 */
export function withLocalCopies(views: AttachmentView[], local: readonly AttachmentView[] | undefined): AttachmentView[] {
  if (!local || local.length !== views.length) return views;
  return views.map((view, i) => ({
    ...view,
    url: view.url ? (local[i].url ?? view.url) : view.url,
    thumbUrl: view.url ? (local[i].thumbUrl ?? view.thumbUrl) : view.thumbUrl,
  }));
}
