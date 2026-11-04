/**
 * The composer's photos and files in the browser (relay/DESIGN.md §5 "Photos and files in prompts"): each draft's
 * attachment strip, kept per draft for as long as the page runs, and the work behind it — an image is decoded, drawn
 * upright at most 2048 px on a canvas and re-encoded without its metadata, with a 480 px thumbnail; then everything is
 * uploaded to the relay's file storage (`files:uploadUrl`, then a POST with its type) one at a time, with progress.
 */
import { useCallback, useMemo, useSyncExternalStore } from "react";
import type { OutgoingAttachment } from "./attachments";
import {
  admit,
  fileType,
  fitSize,
  imagePlan,
  isImageType,
  isPlaceholderName,
  JPEG_QUALITY,
  MAX_IMAGE_SIDE,
  photoName,
  renameForType,
  THUMB_QUALITY,
  THUMB_SIDE,
} from "./attachments";
import { newClientId } from "./browser";

/** One attachment in a draft's strip. */
export type DraftAttachment = {
  id: string;
  kind: "image" | "file";
  name: string;
  /** The uploaded type and bytes (after re-encoding, for an image). */
  type: string;
  size: number;
  width?: number;
  height?: number;
  /** Object URLs of the prepared image and its thumbnail (what the strip and the sent bubble show). */
  fullUrl: string | null;
  thumbUrl: string | null;
  state: "preparing" | "uploading" | "done" | "failed";
  /** Upload progress, 0…1. */
  progress: number;
  storageId?: string;
  thumbId?: string;
  error?: string;
};

/** Uploads one blob with its type and answers its storage id; `onProgress` gets 0…1. */
export type Uploader = (blob: Blob, type: string, onProgress: (fraction: number) => void) => Promise<string>;

/** POSTs the bytes to a `files:uploadUrl` URL (XMLHttpRequest, for upload progress); Convex answers `{storageId}`. */
export function postFile(url: string, blob: Blob, type: string, onProgress: (fraction: number) => void): Promise<string> {
  return new Promise((resolve, reject) => {
    const xhr = new XMLHttpRequest();
    xhr.open("POST", url);
    xhr.setRequestHeader("Content-Type", type);
    xhr.upload.onprogress = (event) => {
      if (event.lengthComputable && event.total > 0) onProgress(event.loaded / event.total);
    };
    xhr.onload = () => {
      if (xhr.status < 200 || xhr.status >= 300) {
        reject(new Error(`Upload failed (HTTP ${xhr.status})`));
        return;
      }
      try {
        const storageId = (JSON.parse(xhr.responseText) as { storageId?: unknown }).storageId;
        if (typeof storageId === "string") resolve(storageId);
        else reject(new Error("Upload failed (no storage id)"));
      } catch (error) {
        reject(error instanceof Error ? error : new Error(String(error)));
      }
    };
    xhr.onerror = () => reject(new Error("Upload failed (network)"));
    xhr.onabort = () => reject(new Error("Upload cancelled"));
    xhr.send(blob);
  });
}

/** The live uploader: a fresh upload URL for each file and each thumbnail. */
export function relayUploader(uploadUrl: () => Promise<{ url: string }>): Uploader {
  return async (blob, type, onProgress) => {
    const { url } = await uploadUrl();
    return await postFile(url, blob, type, onProgress);
  };
}

type Prepared = {
  kind: "image" | "file";
  blob: Blob;
  type: string;
  name: string;
  width?: number;
  height?: number;
  thumb?: Blob;
};

function canvas(width: number, height: number): HTMLCanvasElement {
  const el = document.createElement("canvas");
  el.width = width;
  el.height = height;
  return el;
}

function encode(el: HTMLCanvasElement, type: string, quality?: number): Promise<Blob | null> {
  return new Promise((resolve) => el.toBlob(resolve, type, quality));
}

/** Whether any pixel of the image is not fully opaque (checked on a 64 px copy). */
function hasAlpha(bitmap: ImageBitmap): boolean {
  const size = fitSize(bitmap.width, bitmap.height, 64);
  const probe = canvas(size.width, size.height);
  const ctx = probe.getContext("2d", { willReadFrequently: true });
  if (!ctx) return false;
  ctx.drawImage(bitmap, 0, 0, size.width, size.height);
  const { data } = ctx.getImageData(0, 0, size.width, size.height);
  for (let i = 3; i < data.length; i += 4) if (data[i] < 255) return true;
  return false;
}

/** Draws the image at `width`×`height`, on white when `background` is set (a JPEG has no transparency). */
function drawn(bitmap: ImageBitmap, width: number, height: number, background: boolean): HTMLCanvasElement | null {
  const el = canvas(width, height);
  const ctx = el.getContext("2d");
  if (!ctx) return null;
  if (background) {
    ctx.fillStyle = "#ffffff";
    ctx.fillRect(0, 0, width, height);
  }
  ctx.imageSmoothingQuality = "high";
  ctx.drawImage(bitmap, 0, 0, width, height);
  return el;
}

/**
 * Prepares one picked file. An image the browser can decode is re-encoded upright, at most 2048 px, without metadata
 * (a GIF of at most 10 MB goes as it is), named after its uploaded type, with a 480 px JPEG thumbnail. Anything else,
 * an image the browser cannot decode among them (HEIC outside Safari), goes as a file, as it is.
 */
async function prepare(file: File, name: string): Promise<Prepared> {
  const type = fileType(file.name, file.type);
  const asFile: Prepared = { kind: "file", blob: file, type, name };
  if (!isImageType(type)) return asFile;
  let bitmap: ImageBitmap;
  try {
    bitmap = await createImageBitmap(file, { imageOrientation: "from-image" });
  } catch {
    return asFile;
  }
  try {
    const plan = imagePlan(type, file.size, type === "image/png" || type === "image/gif" ? false : hasAlpha(bitmap));
    let blob: Blob = file;
    let size = { width: bitmap.width, height: bitmap.height };
    if (!plan.keep) {
      size = fitSize(bitmap.width, bitmap.height, MAX_IMAGE_SIDE);
      const el = drawn(bitmap, size.width, size.height, plan.type === "image/jpeg");
      const encoded = el ? await encode(el, plan.type, plan.type === "image/jpeg" ? JPEG_QUALITY : undefined) : null;
      if (!encoded) return asFile;
      blob = encoded;
    }
    const thumbSize = fitSize(bitmap.width, bitmap.height, THUMB_SIDE);
    const thumbCanvas = drawn(bitmap, thumbSize.width, thumbSize.height, true);
    const thumb = (thumbCanvas && (await encode(thumbCanvas, "image/jpeg", THUMB_QUALITY))) ?? undefined;
    return {
      kind: "image",
      blob,
      type: plan.type,
      name: renameForType(name, plan.type),
      width: size.width,
      height: size.height,
      thumb,
    };
  } finally {
    bitmap.close();
  }
}

// ---- The drafts' strips: module state, so a strip outlives its composer while the page runs ----

const EMPTY: DraftAttachment[] = [];
const strips = new Map<string, DraftAttachment[]>();
const listeners = new Map<string, Set<() => void>>();
/** What each attachment needs for a retry: the picked file, and once prepared, the upload. */
const sources = new Map<string, { file: File; name: string; prepared?: Prepared }>();
/** Uploads run one at a time, in the order things were attached. */
let queue: Promise<void> = Promise.resolve();

function strip(key: string): DraftAttachment[] {
  return strips.get(key) ?? EMPTY;
}

function setStrip(key: string, next: DraftAttachment[]) {
  if (next.length) strips.set(key, next);
  else strips.delete(key);
  listeners.get(key)?.forEach((listener) => listener());
}

function patch(key: string, id: string, change: Partial<DraftAttachment>) {
  const list = strip(key);
  if (!list.some((item) => item.id === id)) return;
  setStrip(
    key,
    list.map((item) => (item.id === id ? { ...item, ...change } : item)),
  );
}

function revoke(item: DraftAttachment) {
  if (item.fullUrl) URL.revokeObjectURL(item.fullUrl);
  if (item.thumbUrl && item.thumbUrl !== item.fullUrl) URL.revokeObjectURL(item.thumbUrl);
}

async function process(key: string, id: string, uploader: Uploader) {
  const source = sources.get(id);
  if (!source || !strip(key).some((item) => item.id === id)) return;
  try {
    if (!source.prepared) {
      source.prepared = await prepare(source.file, source.name);
      const prepared = source.prepared;
      const fullUrl = prepared.kind === "image" ? URL.createObjectURL(prepared.blob) : null;
      const thumbUrl = prepared.thumb ? URL.createObjectURL(prepared.thumb) : fullUrl;
      patch(key, id, {
        kind: prepared.kind,
        name: prepared.name,
        type: prepared.type,
        size: prepared.blob.size,
        width: prepared.width,
        height: prepared.height,
        fullUrl,
        thumbUrl,
      });
    }
    const prepared = source.prepared;
    if (!strip(key).some((item) => item.id === id)) return;
    patch(key, id, { state: "uploading", progress: 0, error: undefined });
    // The thumbnail is a few percent of the work; the progress ring follows the image itself.
    const storageId = await uploader(prepared.blob, prepared.type, (fraction) =>
      patch(key, id, { progress: Math.min(0.97, fraction) }),
    );
    let thumbId: string | undefined;
    if (prepared.thumb) {
      // Without its thumbnail the image still goes (viewers load the image itself).
      thumbId = await uploader(prepared.thumb, "image/jpeg", () => {}).catch(() => undefined);
    }
    patch(key, id, { state: "done", progress: 1, storageId, thumbId });
  } catch (error) {
    patch(key, id, { state: "failed", error: error instanceof Error ? error.message : String(error) });
  }
}

function enqueue(key: string, id: string, uploader: Uploader) {
  queue = queue.then(() => process(key, id, uploader));
}

/** An attachment as it goes with the prompt: the upload, and the local copies the sent bubble shows at once. */
export function outgoing(item: DraftAttachment): OutgoingAttachment {
  return {
    storageId: item.storageId ?? "",
    thumbId: item.thumbId,
    name: item.name,
    mimeType: item.type,
    size: item.size,
    kind: item.kind,
    width: item.width,
    height: item.height,
    url: item.fullUrl,
    thumbUrl: item.thumbUrl,
  };
}

/** What the composer does with its strip. */
export type AttachController = {
  items: DraftAttachment[];
  /** Adds picked, pasted or dropped files; `unnamed`: photos without a name of their own (a pasted image). */
  add: (files: File[], options?: { unnamed?: boolean }) => { tooMany: boolean; tooBig: boolean };
  remove: (id: string) => void;
  retry: (id: string) => void;
  /** Empties the strip after sending (the sent bubble keeps showing the local copies). */
  clear: () => void;
  /** Everything is uploaded (and something is there). */
  ready: boolean;
  busy: boolean;
};

/**
 * The strip of the draft `key`. Without an `uploader` (the dev preview's fixtures) nothing is uploaded: `initial` is
 * shown as it is.
 */
export function useDraftAttachments(key: string, uploader: Uploader | null, initial?: DraftAttachment[]): AttachController {
  if (initial && !strips.has(key)) strips.set(key, initial);
  const subscribe = useCallback(
    (listener: () => void) => {
      let set = listeners.get(key);
      if (!set) {
        set = new Set();
        listeners.set(key, set);
      }
      set.add(listener);
      return () => {
        set.delete(listener);
      };
    },
    [key],
  );
  const items = useSyncExternalStore(
    subscribe,
    () => strip(key),
    () => initial ?? EMPTY,
  );

  return useMemo<AttachController>(() => {
    const add: AttachController["add"] = (files, options = {}) => {
      const result = admit(files, strip(key).length);
      if (!result.accepted.length) return result;
      const now = new Date();
      let photo = 0;
      const added: DraftAttachment[] = result.accepted.map((index) => {
        const file = files[index];
        const type = fileType(file.name, file.type);
        const image = isImageType(type);
        const name = image && (options.unnamed || isPlaceholderName(file.name)) ? photoName(now, photo++) : file.name || "file";
        const id = newClientId();
        sources.set(id, { file, name });
        return {
          id,
          kind: image ? "image" : "file",
          name,
          type,
          size: file.size,
          fullUrl: null,
          thumbUrl: null,
          state: "preparing",
          progress: 0,
        };
      });
      setStrip(key, [...strip(key), ...added]);
      if (uploader) for (const item of added) enqueue(key, item.id, uploader);
      return result;
    };
    const remove = (id: string) => {
      const item = strip(key).find((i) => i.id === id);
      if (item) revoke(item);
      sources.delete(id);
      setStrip(
        key,
        strip(key).filter((i) => i.id !== id),
      );
    };
    const retry = (id: string) => {
      if (!uploader) return;
      patch(key, id, { state: "preparing", progress: 0, error: undefined });
      enqueue(key, id, uploader);
    };
    const clear = () => {
      for (const item of strip(key)) sources.delete(item.id);
      setStrip(key, []);
    };
    const busy = items.some((i) => i.state === "preparing" || i.state === "uploading");
    const ready = items.length > 0 && items.every((i) => i.state === "done");
    return { items, add, remove, retry, clear, ready, busy };
  }, [key, uploader, items]);
}

/** The local copies of what a prompt sent from this page carried, by its client id (no flash while URLs change). */
const sent = new Map<string, OutgoingAttachment[]>();

export function rememberSent(clientId: string, attachments: OutgoingAttachment[]) {
  if (attachments.length) sent.set(clientId, attachments);
}

export function sentCopies(clientId: string | null | undefined): OutgoingAttachment[] | undefined {
  return clientId ? sent.get(clientId) : undefined;
}
