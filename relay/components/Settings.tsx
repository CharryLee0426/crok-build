"use client";

/**
 * What the web remembers in this browser, like the phones' settings (mobile/DESIGN.md "Web"): the selected computer,
 * the session theme and its photo blur, and the color mode (`crok.colorMode`: `system` | `light` | `dark`, which sets
 * `data-theme` on <html>; the root layout's head script applies a stored choice before the first paint). The photo
 * itself lives in IndexedDB (lib/photo.ts).
 */
import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState } from "react";
import type { ReactNode } from "react";
import { readStorage, writeStorage } from "@/lib/browser";
import { loadPhoto, savePhoto } from "@/lib/photo";
import { isColorMode, STORAGE } from "@/lib/settings";
import type { ColorMode } from "@/lib/settings";
import { THEME_NONE, THEME_PHOTO, themeById } from "@/lib/themes";

export type { ColorMode };

type Settings = {
  selectedComputer: string | null;
  setSelectedComputer: (id: string) => void;
  sessionTheme: string;
  setSessionTheme: (id: string) => void;
  blur: boolean;
  setBlur: (blur: boolean) => void;
  colorMode: ColorMode;
  setColorMode: (mode: ColorMode) => void;
  /** An object URL of the chosen photo, once loaded. */
  photoUrl: string | null;
  /** Stores a picked image and makes it the theme; false when it could not be used. */
  choosePhoto: (file: Blob) => Promise<boolean>;
};

const SettingsContext = createContext<Settings | null>(null);

/** Sets or clears `data-theme` on <html>. */
export function applyColorMode(mode: ColorMode) {
  if (mode === "system") delete document.documentElement.dataset.theme;
  else document.documentElement.dataset.theme = mode;
}

export function SettingsProvider({
  children,
  persist = true,
  initial,
}: {
  children: ReactNode;
  /** Off in the dev preview: nothing is read from or written to this browser. */
  persist?: boolean;
  initial?: Partial<{
    selectedComputer: string | null;
    sessionTheme: string;
    blur: boolean;
    colorMode: ColorMode;
    photoUrl: string | null;
  }>;
}) {
  const [selectedComputer, setSelected] = useState<string | null>(initial?.selectedComputer ?? null);
  const [sessionTheme, setTheme] = useState(initial?.sessionTheme ?? THEME_NONE);
  const [blur, setBlurState] = useState(initial?.blur ?? false);
  const [colorMode, setMode] = useState<ColorMode>(initial?.colorMode ?? "system");
  const [photoUrl, setPhotoUrl] = useState<string | null>(initial?.photoUrl ?? null);
  const photoUrlRef = useRef<string | null>(null);

  const showPhoto = useCallback((blob: Blob | null) => {
    if (photoUrlRef.current) URL.revokeObjectURL(photoUrlRef.current);
    const url = blob ? URL.createObjectURL(blob) : null;
    photoUrlRef.current = url;
    setPhotoUrl(url);
  }, []);

  useEffect(() => {
    if (!persist) return;
    setSelected(readStorage(STORAGE.selectedComputer));
    const theme = readStorage(STORAGE.sessionTheme);
    if (theme && themeById(theme).id === theme) setTheme(theme);
    setBlurState(readStorage(STORAGE.sessionThemeBlur) === "true");
    const mode = readStorage(STORAGE.colorMode);
    if (isColorMode(mode)) setMode(mode);
    let cancelled = false;
    void loadPhoto().then((blob) => {
      if (!cancelled && blob) showPhoto(blob);
    });
    return () => {
      cancelled = true;
    };
  }, [persist, showPhoto]);

  useEffect(
    () => () => {
      if (photoUrlRef.current) URL.revokeObjectURL(photoUrlRef.current);
    },
    [],
  );

  const setSelectedComputer = useCallback(
    (id: string) => {
      setSelected(id);
      if (persist) writeStorage(STORAGE.selectedComputer, id);
    },
    [persist],
  );
  const setSessionTheme = useCallback(
    (id: string) => {
      setTheme(id);
      if (persist) writeStorage(STORAGE.sessionTheme, id === THEME_NONE ? null : id);
    },
    [persist],
  );
  const setBlur = useCallback(
    (value: boolean) => {
      setBlurState(value);
      if (persist) writeStorage(STORAGE.sessionThemeBlur, value ? "true" : null);
    },
    [persist],
  );
  const setColorMode = useCallback(
    (mode: ColorMode) => {
      setMode(mode);
      applyColorMode(mode);
      if (persist) writeStorage(STORAGE.colorMode, mode === "system" ? null : mode);
    },
    [persist],
  );
  const choosePhoto = useCallback(
    async (file: Blob) => {
      const jpeg = await savePhoto(file);
      if (!jpeg) return false;
      showPhoto(jpeg);
      setSessionTheme(THEME_PHOTO);
      return true;
    },
    [showPhoto, setSessionTheme],
  );

  const value = useMemo<Settings>(
    () => ({
      selectedComputer,
      setSelectedComputer,
      sessionTheme,
      setSessionTheme,
      blur,
      setBlur,
      colorMode,
      setColorMode,
      photoUrl,
      choosePhoto,
    }),
    [selectedComputer, setSelectedComputer, sessionTheme, setSessionTheme, blur, setBlur, colorMode, setColorMode, photoUrl, choosePhoto],
  );
  return <SettingsContext.Provider value={value}>{children}</SettingsContext.Provider>;
}

export function useSettings(): Settings {
  const value = useContext(SettingsContext);
  if (!value) throw new Error("useSettings outside SettingsProvider");
  return value;
}

/** Whether the page shows dark right now: `data-theme` when set, else the system's scheme. */
export function useResolvedDark(): boolean {
  const [dark, setDark] = useState(false);
  useEffect(() => {
    const query = window.matchMedia("(prefers-color-scheme: dark)");
    const update = () => {
      const forced = document.documentElement.dataset.theme;
      setDark(forced === "dark" || forced === "light" ? forced === "dark" : query.matches);
    };
    update();
    query.addEventListener("change", update);
    const observer = new MutationObserver(update);
    observer.observe(document.documentElement, { attributes: true, attributeFilter: ["data-theme"] });
    return () => {
      query.removeEventListener("change", update);
      observer.disconnect();
    };
  }, []);
  return dark;
}
