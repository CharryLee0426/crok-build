"use client";

/**
 * The session background (mobile/DESIGN.md "Session themes", "Web"): Crok's plain canvas, a theme's gradient and doodle
 * pattern drawn on a canvas, or the chosen photo (blurred when asked, under black at 40 % in the dark). The middle
 * column, the new-session screen and Appearance's preview and cards all draw it.
 */
import { useEffect, useRef } from "react";
import type { CSSProperties } from "react";
import { paintTheme, themeById, THEME_PHOTO, themeVars } from "@/lib/themes";
import type { SessionTheme } from "@/lib/themes";
import { useResolvedDark, useSettings } from "./Settings";

function PatternCanvas({ theme, dark, patternScale }: { theme: SessionTheme; dark: boolean; patternScale: number }) {
  const boxRef = useRef<HTMLDivElement>(null);
  const canvasRef = useRef<HTMLCanvasElement>(null);
  useEffect(() => {
    const box = boxRef.current;
    const canvas = canvasRef.current;
    if (!box || !canvas) return;
    let frame = 0;
    let last = "";
    const paint = () => {
      frame = 0;
      const { width, height } = box.getBoundingClientRect();
      const ratio = Math.min(2, window.devicePixelRatio || 1);
      const key = `${Math.round(width)}x${Math.round(height)}@${ratio}`;
      if (key === last || width < 1 || height < 1) return;
      last = key;
      paintTheme(canvas, theme, dark, width, height, ratio, patternScale);
    };
    paint();
    const observer = new ResizeObserver(() => {
      if (!frame) frame = requestAnimationFrame(paint);
    });
    observer.observe(box);
    return () => {
      observer.disconnect();
      if (frame) cancelAnimationFrame(frame);
    };
  }, [theme, dark, patternScale]);
  const variant = dark ? theme.dark : theme.light;
  return (
    <div
      ref={boxRef}
      className="absolute inset-0 overflow-hidden"
      // The first colour until the canvas is drawn.
      style={{ background: dark ? "#0b0d10" : variant?.colors[0] }}
      aria-hidden="true"
    >
      <canvas ref={canvasRef} className="absolute inset-0 h-full w-full" />
    </div>
  );
}

/** Fills its (positioned) parent with the background of `themeId`, else of the setting. */
export function SessionBackground({ themeId, patternScale = 1 }: { themeId?: string; patternScale?: number }) {
  const settings = useSettings();
  const dark = useResolvedDark();
  const theme = themeById(themeId ?? settings.sessionTheme);
  if (theme.kind === "pattern") return <PatternCanvas theme={theme} dark={dark} patternScale={patternScale} />;
  if (theme.kind === "photo" && settings.photoUrl) {
    return (
      <div className="absolute inset-0 overflow-hidden bg-canvas" aria-hidden="true">
        {/* eslint-disable-next-line @next/next/no-img-element */}
        <img
          src={settings.photoUrl}
          alt=""
          className="absolute inset-0 h-full w-full object-cover"
          style={settings.blur ? { filter: "blur(24px)", transform: "scale(1.12)" } : undefined}
        />
        {dark ? <div className="absolute inset-0 bg-black/40" /> : null}
      </div>
    );
  }
  return <div className="absolute inset-0 bg-canvas" aria-hidden="true" />;
}

/**
 * The CSS variables and attribute a theme puts on the column it fills: the person's bubbles, the service capsules,
 * and `data-wallpaper` (loose text such as times gets a capsule of its own over a pattern or photo).
 */
export function useThemeStyle(themeId?: string): { style: CSSProperties; wallpaper: boolean } {
  const settings = useSettings();
  const dark = useResolvedDark();
  const theme = themeById(themeId ?? settings.sessionTheme);
  const wallpaper = theme.kind === "pattern" || (theme.id === THEME_PHOTO && Boolean(settings.photoUrl));
  const vars = themeVars(wallpaper || theme.kind !== "photo" ? theme : themeById("none"), dark);
  return { style: vars as CSSProperties, wallpaper };
}
