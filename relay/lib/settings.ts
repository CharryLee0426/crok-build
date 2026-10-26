/**
 * The keys of what the web remembers in this browser (mobile/DESIGN.md "Web"), shared by the settings provider
 * (components/Settings.tsx) and the root layout's color-mode script. A plain module so server components can import it.
 */

export type ColorMode = "system" | "light" | "dark";

export const STORAGE = {
  selectedComputer: "crok.selectedComputer",
  sessionTheme: "crok.sessionTheme",
  sessionThemeBlur: "crok.sessionThemeBlur",
  colorMode: "crok.colorMode",
} as const;

export function isColorMode(value: unknown): value is ColorMode {
  return value === "system" || value === "light" || value === "dark";
}

/** Runs in <head> before the page paints, so a stored Light or Dark never flashes the other scheme. */
export const COLOR_MODE_SCRIPT = `try{var m=localStorage.getItem(${JSON.stringify(STORAGE.colorMode)});if(m==="light"||m==="dark")document.documentElement.dataset.theme=m}catch(e){}`;
