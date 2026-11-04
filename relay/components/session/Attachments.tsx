"use client";

/**
 * Photos and files in prompts (relay/DESIGN.md §5 "Photos and files in prompts", Telegram Web's attach button, media
 * bubbles and media viewer): the composer's paperclip and strip, the drop overlay, what a prompt's attachments look
 * like in its bubble, and the full-screen viewer.
 */
import { useCallback, useEffect, useRef, useState } from "react";
import type { CSSProperties, DragEvent, PointerEvent as ReactPointerEvent, ReactNode } from "react";
import { createPortal } from "react-dom";
import type { AttachmentView } from "@/lib/attachments";
import { fileDetail, formatSize, gridRows, middleTruncate, singleImageBox } from "@/lib/attachments";
import type { AttachController, DraftAttachment } from "@/lib/upload";
import { useI18n } from "../I18nProvider";
import {
  ChevronLeftIcon,
  ChevronRightIcon,
  DownloadIcon,
  ExternalIcon,
  FileIcon,
  PaperclipIcon,
  PhotoIcon,
  SpinnerIcon,
  XIcon,
} from "../icons";
import { useToast } from "../Toast";

/** Media bubbles are at most this wide (and a single image this tall). */
export const MEDIA_MAX = 320;

/** Toasts for files that were not added: over 10 in the strip, or over 20 MB. */
export function useAttachNotices() {
  const { t } = useI18n();
  const toast = useToast();
  return useCallback(
    (result: { tooMany: boolean; tooBig: boolean }) => {
      if (result.tooBig) toast.show(t("attach_too_big"), "error");
      if (result.tooMany) toast.show(t("attach_too_many"), "error");
    },
    [t, toast],
  );
}

/** The paperclip after the Menu pill: the browser's file dialog, several files of any type. */
export function AttachButton({ onFiles, first = false }: { onFiles: (files: File[]) => void; first?: boolean }) {
  const { t } = useI18n();
  const input = useRef<HTMLInputElement>(null);
  return (
    <>
      <button
        type="button"
        onMouseDown={(e) => e.preventDefault()}
        onClick={() => input.current?.click()}
        aria-label={t("attach")}
        title={t("attach")}
        className={`mb-[7px] flex h-8 w-8 shrink-0 items-center justify-center rounded-full text-muted transition-colors hover:bg-hover hover:text-fg ${
          first ? "ml-[7px]" : "ml-0.5"
        }`}
      >
        <PaperclipIcon size={21} />
      </button>
      <input
        ref={input}
        type="file"
        multiple
        hidden
        tabIndex={-1}
        onChange={(e) => {
          const files = Array.from(e.target.files ?? []);
          e.target.value = "";
          if (files.length) onFiles(files);
        }}
      />
    </>
  );
}

/** A ring that fills with the upload, or spins while the file is still being prepared. */
function ProgressRing({ progress, size = 30 }: { progress: number | null; size?: number }) {
  const r = (size - 4) / 2;
  const length = 2 * Math.PI * r;
  return (
    <svg width={size} height={size} viewBox={`0 0 ${size} ${size}`} aria-hidden="true" className={progress === null ? "animate-spin" : ""}>
      <circle cx={size / 2} cy={size / 2} r={r} fill="none" stroke="currentColor" strokeOpacity={0.3} strokeWidth={2.5} />
      <circle
        cx={size / 2}
        cy={size / 2}
        r={r}
        fill="none"
        stroke="currentColor"
        strokeWidth={2.5}
        strokeLinecap="round"
        strokeDasharray={length}
        strokeDashoffset={length * (1 - (progress === null ? 0.25 : Math.max(0.03, progress)))}
        transform={`rotate(-90 ${size / 2} ${size / 2})`}
        style={{ transition: "stroke-dashoffset 0.2s linear" }}
      />
    </svg>
  );
}

function StripItem({ item, onRemove, onRetry }: { item: DraftAttachment; onRemove: () => void; onRetry: () => void }) {
  const { t, lang } = useI18n();
  const working = item.state === "preparing" || item.state === "uploading";
  const failed = item.state === "failed";
  const status = working ? (
    <span className="absolute inset-0 flex items-center justify-center rounded-[inherit] bg-black/35 text-white">
      <ProgressRing progress={item.state === "uploading" ? item.progress : null} />
    </span>
  ) : failed ? (
    <button
      type="button"
      onClick={onRetry}
      aria-label={t("attach_failed")}
      title={item.error ? `${t("attach_failed")} (${item.error})` : t("attach_failed")}
      className={`absolute inset-0 flex items-center justify-center rounded-[inherit] text-white ${
        item.kind === "image" ? "bg-black/40" : "bg-danger"
      }`}
    >
      <span className="flex h-7 w-7 items-center justify-center rounded-full bg-danger text-[17px] font-bold leading-none">!</span>
    </button>
  ) : null;
  const remove = (
    <button
      type="button"
      onClick={onRemove}
      aria-label={t("attach_remove")}
      title={t("attach_remove")}
      className="absolute -right-1.5 -top-1.5 z-10 flex h-5 w-5 items-center justify-center rounded-full bg-fg/75 text-canvas shadow ring-2 ring-surface hover:bg-fg"
    >
      <XIcon size={12} strokeWidth={2.6} />
    </button>
  );
  const label = working ? t("attach_uploading") : failed ? t("attach_failed") : item.name;
  if (item.kind === "image") {
    return (
      <li className="relative h-16 w-16 shrink-0 rounded-xl" title={label}>
        <span className="block h-full w-full overflow-hidden rounded-xl bg-surface-2">
          {item.thumbUrl ? (
            // eslint-disable-next-line @next/next/no-img-element -- a local object URL
            <img src={item.thumbUrl} alt={item.name} className="h-full w-full object-cover" />
          ) : (
            <span className="flex h-full w-full items-center justify-center text-faint">
              <PhotoIcon size={22} />
            </span>
          )}
        </span>
        {status}
        {remove}
      </li>
    );
  }
  return (
    <li className="relative flex h-16 min-w-[170px] max-w-[250px] shrink-0 items-center gap-2.5 rounded-xl bg-surface-2 px-2.5 pr-4" title={label}>
      <span className="relative flex h-10 w-10 shrink-0 items-center justify-center rounded-full bg-accent text-accent-fg">
        <FileIcon size={19} />
        {status}
      </span>
      <span className="min-w-0 flex-1">
        <span className="block truncate text-[13.5px] font-medium text-fg">{middleTruncate(item.name, 22)}</span>
        <span className={`block truncate text-[12px] ${failed ? "text-danger" : "text-muted"}`}>
          {failed ? t("attach_failed") : working ? t("attach_uploading") : formatSize(item.size, lang)}
        </span>
      </span>
      {remove}
    </li>
  );
}

/** The attachments waiting in the composer, above the field, scrolling sideways. */
export function AttachmentStrip({ controller }: { controller: AttachController }) {
  const { t } = useI18n();
  if (!controller.items.length) return null;
  return (
    <ul
      aria-label={t("attach")}
      className="scroll-quiet mb-2 flex gap-2.5 overflow-x-auto rounded-2xl bg-surface p-2.5 pt-3 shadow-[0_1px_2px_rgb(0_0_0/0.12),0_2px_10px_rgb(0_0_0/0.06)] ring-1 ring-line"
    >
      {controller.items.map((item) => (
        <StripItem
          key={item.id}
          item={item}
          onRemove={() => controller.remove(item.id)}
          onRetry={() => controller.retry(item.id)}
        />
      ))}
    </ul>
  );
}

/** Dragging files over the session screen shows the overlay; dropping them attaches them. */
export function useFileDrop(onFiles: ((files: File[]) => void) | null) {
  const [dragging, setDragging] = useState(false);
  const depth = useRef(0);
  const carriesFiles = (e: DragEvent) => Array.from(e.dataTransfer.types).includes("Files");
  if (!onFiles) return { dragging: false, handlers: {} };
  return {
    dragging,
    handlers: {
      onDragEnter: (e: DragEvent) => {
        if (!carriesFiles(e)) return;
        e.preventDefault();
        depth.current += 1;
        setDragging(true);
      },
      onDragOver: (e: DragEvent) => {
        if (!carriesFiles(e)) return;
        e.preventDefault();
        e.dataTransfer.dropEffect = "copy";
      },
      onDragLeave: (e: DragEvent) => {
        if (!carriesFiles(e)) return;
        depth.current = Math.max(0, depth.current - 1);
        if (depth.current === 0) setDragging(false);
      },
      onDrop: (e: DragEvent) => {
        if (!carriesFiles(e)) return;
        e.preventDefault();
        depth.current = 0;
        setDragging(false);
        const files = Array.from(e.dataTransfer.files);
        if (files.length) onFiles(files);
      },
    },
  };
}

export function DropOverlay() {
  const { t } = useI18n();
  return (
    <div className="pointer-events-none absolute inset-0 z-40 flex items-center justify-center bg-canvas/70 p-6 backdrop-blur-sm">
      <div className="flex h-full max-h-80 w-full max-w-xl flex-col items-center justify-center gap-3 rounded-3xl border-2 border-dashed border-accent bg-surface/90 text-accent-text">
        <PaperclipIcon size={34} />
        <span className="text-[17px] font-semibold">{t("drop_to_attach")}</span>
      </div>
    </div>
  );
}

/** An image tile: the thumbnail (else the image) on a tinted placeholder of the same shape; a tap opens the viewer. */
function ImageTile({
  item,
  className,
  style,
  fit,
  onOpen,
  children,
}: {
  item: AttachmentView;
  className: string;
  style?: CSSProperties;
  fit: "cover" | "contain";
  onOpen?: () => void;
  children?: ReactNode;
}) {
  const src = item.thumbUrl ?? item.url ?? undefined;
  const [loaded, setLoaded] = useState(false);
  return (
    <button
      type="button"
      onClick={onOpen}
      aria-label={item.name}
      title={item.name}
      className={`relative block overflow-hidden bg-black/[0.06] dark:bg-white/[0.08] ${className}`}
      style={style}
    >
      {/* eslint-disable-next-line @next/next/no-img-element -- the relay's own storage URL */}
      <img
        src={src}
        alt={item.name}
        loading="lazy"
        decoding="async"
        draggable={false}
        onLoad={() => setLoaded(true)}
        className={`h-full w-full transition-opacity duration-200 ${fit === "cover" ? "object-cover" : "object-contain"} ${
          loaded ? "opacity-100" : "opacity-0"
        }`}
      />
      {children}
    </button>
  );
}

function FileRow({ item, computer }: { item: AttachmentView; computer: string }) {
  const { t, lang } = useI18n();
  const content = (
    <>
      <span className="flex h-10 w-10 shrink-0 items-center justify-center rounded-full bg-accent text-accent-fg">
        {item.kind === "image" ? <PhotoIcon size={19} /> : <FileIcon size={19} />}
      </span>
      <span className="min-w-0 flex-1 text-left">
        <span className="block truncate text-[14px] font-medium leading-snug">{middleTruncate(item.name, 28)}</span>
        <span className="block truncate text-[12.5px] leading-snug text-bubble-user-meta">
          {item.url
            ? fileDetail(item.name, item.size, lang)
            : item.storageId
              ? t("attachment_gone")
              : t("attachment_on_computer", { computer })}
        </span>
      </span>
    </>
  );
  if (!item.url) {
    return (
      <div className="flex items-center gap-3 rounded-xl px-1 py-1 opacity-60" title={item.name}>
        {content}
      </div>
    );
  }
  return (
    <a
      href={item.url}
      target="_blank"
      rel="noopener noreferrer"
      title={item.name}
      className="flex items-center gap-3 rounded-xl px-1 py-1 hover:bg-black/[0.04] dark:hover:bg-white/[0.06]"
    >
      {content}
    </a>
  );
}

/**
 * A prompt's attachments inside its bubble: its images whole (one) or as a grid (several), then a row per file.
 * `overlay` sits on the last image's bottom-right corner (the time and ticks of a bubble with only images).
 */
export function MessageMedia({
  attachments,
  computer,
  overlay,
  onOpenImage,
}: {
  attachments: AttachmentView[];
  computer: string;
  overlay?: ReactNode;
  onOpenImage: (images: AttachmentView[], index: number) => void;
}) {
  // An image with nothing to show (gone, or only on the computer) is listed by name with the files.
  const images = attachments.filter((a) => a.kind === "image" && (a.url || a.thumbUrl));
  const files = attachments.filter((a) => !images.includes(a));
  const open = (item: AttachmentView) => onOpenImage(images, Math.max(0, images.indexOf(item)));
  const pill = overlay ? (
    <span className="pointer-events-none absolute bottom-1.5 right-1.5 flex items-center gap-1 rounded-full bg-black/45 px-1.5 py-0.5 text-[11px] text-white tabular-nums">
      {overlay}
    </span>
  ) : null;
  let media: ReactNode = null;
  if (images.length === 1) {
    const item = images[0];
    const box = singleImageBox(item.width, item.height, MEDIA_MAX, MEDIA_MAX);
    media = (
      <ImageTile
        item={item}
        fit="contain"
        className="w-full"
        style={{ width: box.width, maxWidth: "100%", aspectRatio: `${box.width} / ${box.height}` }}
        onOpen={() => open(item)}
      >
        {pill}
      </ImageTile>
    );
  } else if (images.length > 1) {
    const rows = gridRows(images.length);
    media = (
      <div className="grid w-[320px] max-w-full grid-cols-2 gap-[2px]">
        {rows.flatMap((row, r) =>
          row.map((index) => {
            const item = images[index];
            const last = r === rows.length - 1 && index === row[row.length - 1];
            return (
              <ImageTile
                key={`${index}:${item.storageId ?? item.name}`}
                item={item}
                fit="cover"
                className={row.length === 1 ? "col-span-2 aspect-[2/1]" : "aspect-square"}
                onOpen={() => open(item)}
              >
                {last ? pill : null}
              </ImageTile>
            );
          }),
        )}
      </div>
    );
  }
  return (
    <>
      {media}
      {files.length ? (
        <div className={`flex w-[320px] max-w-full flex-col gap-0.5 ${media ? "px-2 pt-2" : "px-1.5 pt-1.5"}`}>
          {files.map((item, i) => (
            <FileRow key={`${i}:${item.storageId ?? item.name}`} item={item} computer={computer} />
          ))}
        </div>
      ) : null}
    </>
  );
}

const MIN_ZOOM = 1;
const MAX_ZOOM = 5;

/** Saves the original: fetched and saved under its name; opened in a new tab when the fetch is refused. */
async function download(item: AttachmentView) {
  if (!item.url) return;
  try {
    const response = await fetch(item.url);
    if (!response.ok) throw new Error(String(response.status));
    const url = URL.createObjectURL(await response.blob());
    const a = document.createElement("a");
    a.href = url;
    a.download = item.name;
    document.body.append(a);
    a.click();
    a.remove();
    window.setTimeout(() => URL.revokeObjectURL(url), 10_000);
  } catch {
    window.open(item.url, "_blank", "noopener,noreferrer");
  }
}

/**
 * Telegram Web's media viewer: the item's images on black, ←/→ (and a swipe) between them, zoom by click, wheel or
 * pinch (drag to pan once zoomed), Esc or ✕ to close (a swipe down too); Open original and Download.
 */
export function MediaViewer({
  images,
  index: initialIndex,
  onClose,
}: {
  images: AttachmentView[];
  index: number;
  onClose: () => void;
}) {
  const { t, lang } = useI18n();
  const [index, setIndex] = useState(() => Math.min(Math.max(0, initialIndex), Math.max(0, images.length - 1)));
  const [zoom, setZoom] = useState({ scale: 1, x: 0, y: 0 });
  const [fullLoaded, setFullLoaded] = useState(false);
  const [dragging, setDragging] = useState(false);
  const stage = useRef<HTMLDivElement>(null);
  const pointers = useRef(new Map<number, { x: number; y: number }>());
  const gesture = useRef<{
    startX: number;
    startY: number;
    pinch: number | null;
    base: { scale: number; x: number; y: number };
    moved: boolean;
  } | null>(null);
  const item = images[index];
  const count = images.length;

  const go = useCallback(
    (step: number) => {
      if (count < 2) return;
      setIndex((i) => (i + step + count) % count);
      setZoom({ scale: 1, x: 0, y: 0 });
      setFullLoaded(false);
    },
    [count],
  );

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") {
        e.preventDefault();
        e.stopPropagation();
        onClose();
      } else if (e.key === "ArrowRight") go(1);
      else if (e.key === "ArrowLeft") go(-1);
    };
    window.addEventListener("keydown", onKey, true);
    const overflow = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    return () => {
      window.removeEventListener("keydown", onKey, true);
      document.body.style.overflow = overflow;
    };
  }, [go, onClose]);

  /** Zooms to `scale(current)` keeping the point (clientX, clientY) where it is. */
  const zoomAt = useCallback((scale: (current: number) => number, clientX: number, clientY: number) => {
    const el = stage.current;
    setZoom((z) => {
      const next = Math.min(MAX_ZOOM, Math.max(MIN_ZOOM, scale(z.scale)));
      if (!el || next === MIN_ZOOM) return { scale: MIN_ZOOM, x: 0, y: 0 };
      const rect = el.getBoundingClientRect();
      const px = clientX - rect.left - rect.width / 2;
      const py = clientY - rect.top - rect.height / 2;
      const ratio = next / z.scale;
      return { scale: next, x: px - (px - z.x) * ratio, y: py - (py - z.y) * ratio };
    });
  }, []);

  // Wheel zoom needs a non-passive listener to keep the page from scrolling.
  useEffect(() => {
    const el = stage.current;
    if (!el) return;
    const onWheel = (e: WheelEvent) => {
      e.preventDefault();
      zoomAt((scale) => scale * Math.exp(-e.deltaY / 300), e.clientX, e.clientY);
    };
    el.addEventListener("wheel", onWheel, { passive: false });
    return () => el.removeEventListener("wheel", onWheel);
  }, [zoomAt]);

  const distance = () => {
    const [a, b] = Array.from(pointers.current.values());
    return a && b ? Math.hypot(a.x - b.x, a.y - b.y) : null;
  };

  const onPointerDown = (e: ReactPointerEvent) => {
    (e.target as Element).setPointerCapture?.(e.pointerId);
    pointers.current.set(e.pointerId, { x: e.clientX, y: e.clientY });
    gesture.current = { startX: e.clientX, startY: e.clientY, pinch: distance(), base: zoom, moved: false };
    setDragging(true);
  };
  const onPointerMove = (e: ReactPointerEvent) => {
    if (!pointers.current.has(e.pointerId) || !gesture.current) return;
    pointers.current.set(e.pointerId, { x: e.clientX, y: e.clientY });
    const g = gesture.current;
    const dx = e.clientX - g.startX;
    const dy = e.clientY - g.startY;
    if (Math.abs(dx) > 4 || Math.abs(dy) > 4) g.moved = true;
    const d = distance();
    if (d && g.pinch) {
      const scale = Math.min(MAX_ZOOM, Math.max(MIN_ZOOM, g.base.scale * (d / g.pinch)));
      setZoom(scale === MIN_ZOOM ? { scale, x: 0, y: 0 } : { ...g.base, scale });
    } else if (g.base.scale > MIN_ZOOM) {
      setZoom({ ...g.base, x: g.base.x + dx, y: g.base.y + dy });
    } else {
      setZoom({ scale: 1, x: dx, y: Math.max(0, dy) * 0.6 });
    }
  };
  const onPointerUp = (e: ReactPointerEvent) => {
    const g = gesture.current;
    const wasPinch = pointers.current.size > 1;
    pointers.current.delete(e.pointerId);
    if (!g || pointers.current.size > 0) return;
    gesture.current = null;
    setDragging(false);
    const dx = e.clientX - g.startX;
    const dy = e.clientY - g.startY;
    if (wasPinch) return;
    if (!g.moved) {
      // A click zooms in at that point, and a second one out again.
      zoomAt((scale) => (scale > MIN_ZOOM ? MIN_ZOOM : 2.5), e.clientX, e.clientY);
      return;
    }
    if (g.base.scale > MIN_ZOOM) return;
    setZoom({ scale: 1, x: 0, y: 0 });
    if (Math.abs(dx) > 60 && Math.abs(dx) > Math.abs(dy)) go(dx < 0 ? 1 : -1);
    else if (dy > 110) onClose();
  };

  if (!item) return null;
  const zoomed = zoom.scale > MIN_ZOOM;
  const transform = `translate(${zoom.x}px, ${zoom.y}px) scale(${zoom.scale})`;
  const button =
    "flex h-10 shrink-0 items-center justify-center gap-1.5 rounded-full px-3 text-[14px] text-white/90 hover:bg-white/10 hover:text-white";

  return createPortal(
    <div
      role="dialog"
      aria-modal="true"
      aria-label={item.name}
      className="fixed inset-0 z-[60] flex flex-col bg-black text-white"
    >
      <div className="relative z-10 flex h-14 shrink-0 items-center gap-1 bg-gradient-to-b from-black/70 to-transparent px-2 sm:px-4">
        <div className="min-w-0 flex-1 px-2">
          <span className="block truncate text-[14.5px] font-medium">{item.name}</span>
          <span className="block truncate text-[12.5px] text-white/60">
            {count > 1 ? `${t("viewer_counter", { index: index + 1, count })} · ` : ""}
            {item.width && item.height ? `${item.width} × ${item.height} · ` : ""}
            {formatSize(item.size, lang)}
          </span>
        </div>
        {item.url ? (
          <>
            <a href={item.url} target="_blank" rel="noopener noreferrer" className={button} title={t("open_original")}>
              <ExternalIcon size={19} />
              <span className="hidden sm:inline">{t("open_original")}</span>
            </a>
            <button type="button" onClick={() => void download(item)} className={button} title={t("download")}>
              <DownloadIcon size={19} />
              <span className="hidden sm:inline">{t("download")}</span>
            </button>
          </>
        ) : null}
        <button type="button" onClick={onClose} className={`${button} w-10 px-0`} aria-label={t("close")} title={t("close")}>
          <XIcon size={22} />
        </button>
      </div>
      <div
        ref={stage}
        className={`relative min-h-0 flex-1 touch-none select-none overflow-hidden ${zoomed ? "cursor-grab" : "cursor-zoom-in"}`}
        onPointerDown={onPointerDown}
        onPointerMove={onPointerMove}
        onPointerUp={onPointerUp}
        onPointerCancel={onPointerUp}
      >
        <div
          className="absolute inset-0 p-2 sm:p-6"
          style={{ transform, transition: dragging ? "none" : "transform 0.18s ease-out" }}
        >
          <div className="relative flex h-full w-full items-center justify-center">
            {/* The thumbnail at once, the image over it once it has loaded; both fit the same box. */}
            {item.thumbUrl && !fullLoaded ? (
              // eslint-disable-next-line @next/next/no-img-element -- the relay's storage URL
              <img src={item.thumbUrl} alt="" draggable={false} className="absolute inset-0 h-full w-full object-contain" />
            ) : null}
            {item.url ? (
              // eslint-disable-next-line @next/next/no-img-element -- the relay's storage URL
              <img
                key={item.url}
                src={item.url}
                alt={item.name}
                draggable={false}
                onLoad={() => setFullLoaded(true)}
                className={`absolute inset-0 h-full w-full object-contain transition-opacity ${fullLoaded ? "opacity-100" : "opacity-0"}`}
              />
            ) : null}
            {!fullLoaded && item.url ? <SpinnerIcon size={26} className="relative text-white/70" /> : null}
          </div>
        </div>
      </div>
      {count > 1 ? (
        <>
          <button
            type="button"
            onClick={() => go(-1)}
            aria-label={t("viewer_previous")}
            title={t("viewer_previous")}
            className="absolute left-2 top-1/2 z-10 hidden h-12 w-12 -translate-y-1/2 items-center justify-center rounded-full bg-white/10 text-white hover:bg-white/20 sm:flex"
          >
            <ChevronLeftIcon size={26} />
          </button>
          <button
            type="button"
            onClick={() => go(1)}
            aria-label={t("viewer_next")}
            title={t("viewer_next")}
            className="absolute right-2 top-1/2 z-10 hidden h-12 w-12 -translate-y-1/2 items-center justify-center rounded-full bg-white/10 text-white hover:bg-white/20 sm:flex"
          >
            <ChevronRightIcon size={26} />
          </button>
          <div className="pointer-events-none absolute inset-x-0 bottom-[max(1rem,env(safe-area-inset-bottom))] z-10 flex justify-center gap-1.5">
            {images.map((_, i) => (
              <span key={i} className={`h-1.5 w-1.5 rounded-full ${i === index ? "bg-white" : "bg-white/35"}`} />
            ))}
          </div>
        </>
      ) : null}
    </div>,
    document.body,
  );
}
