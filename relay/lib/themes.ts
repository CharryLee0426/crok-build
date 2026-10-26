/**
 * Session themes (mobile/DESIGN.md "Session themes"): Telegram's chat themes drawn by Crok, each with a light and a
 * dark variant. A theme sets the session background and the person's bubbles; agent bubbles, cards and the accent stay.
 * The background is a four-colour gradient rendered small and scaled up, under a doodle pattern from `doodles.ts`.
 */
import { fnv1a } from "./computers";
import { DOODLES } from "./doodles";
import type { DoodleName } from "./doodles";
import type { MessageKey } from "./i18n";

export type ThemeVariant = {
  /** The gradient's four colours, at `GRADIENT_POINTS`. */
  colors: readonly [string, string, string, string];
  /** The person's bubble, its text, its time and ticks. */
  out: string;
  outText: string;
  outMeta: string;
};

export type SessionTheme = {
  id: string;
  name: MessageKey;
  emoji: string;
  kind: "plain" | "pattern" | "photo";
  light?: ThemeVariant;
  dark?: ThemeVariant;
  glyphs: readonly DoodleName[];
};

export const THEME_NONE = "none";
export const THEME_PHOTO = "photo";

function v(colors: [string, string, string, string], out: string, outText: string, outMeta: string): ThemeVariant {
  return { colors, out, outText, outMeta };
}

/** No Theme, Classic, the nine emoji themes, Photo (shown in the strip only once a photo was chosen). */
export const THEMES: readonly SessionTheme[] = [
  { id: THEME_NONE, name: "theme_none", emoji: "", kind: "plain", glyphs: [] },
  {
    id: "classic",
    name: "theme_classic",
    emoji: "🌿",
    kind: "pattern",
    light: v(["#DBDDBB", "#6BA587", "#D5D88D", "#88B884"], "#EFFDDE", "#000000", "#4FAE4E"),
    dark: v(["#2E5B46", "#14322A", "#3F6A3A", "#1D4236"], "#2F5D50", "#FFFFFF", "#A5E0C9"),
    glyphs: [
      "terminal", "code", "braces", "chip", "ladybug", "hammer", "hash", "function", "keyboard", "server", "bolt",
      "plane", "cloud", "sparkles", "laptop", "cup",
    ],
  },
  {
    id: "home",
    name: "theme_home",
    emoji: "🏠",
    kind: "pattern",
    light: v(["#F9D9A9", "#F2B880", "#FCE8C8", "#E9A877"], "#FFE3C2", "#000000", "#C4772F"),
    dark: v(["#6B4220", "#3A2412", "#7D5026", "#4C2E17"], "#7A4A22", "#FFFFFF", "#F5C99A"),
    glyphs: ["house", "sofa", "lamp", "cup", "key", "leaf", "bed", "forkKnife", "pan", "fireplace", "sun", "heart"],
  },
  {
    id: "duck",
    name: "theme_duck",
    emoji: "🐥",
    kind: "pattern",
    light: v(["#FFF3A3", "#D9F29B", "#FFE07A", "#BFE59A"], "#FFF4B8", "#000000", "#B89A00"),
    dark: v(["#5E5A1A", "#33461F", "#6E5E14", "#2C3F1D"], "#6B5E12", "#FFFFFF", "#F2E38A"),
    glyphs: ["bird", "leaf", "sun", "cloud", "drop", "carrot", "ladybug", "tortoise", "hare", "flower", "star"],
  },
  {
    id: "snowman",
    name: "theme_snowman",
    emoji: "⛄",
    kind: "pattern",
    light: v(["#E3F2FF", "#B8DCFB", "#F2F8FF", "#A8CDF2"], "#D8EEFF", "#000000", "#3390EC"),
    dark: v(["#1E3D63", "#11233B", "#2A4B78", "#173052"], "#24507E", "#FFFFFF", "#A8CCF7"),
    glyphs: ["snowflake", "snowCloud", "mountains", "wind", "star", "moonStars", "thermometer", "sparkles", "cup", "skier"],
  },
  {
    id: "diamond",
    name: "theme_diamond",
    emoji: "💎",
    kind: "pattern",
    light: v(["#A8E6E2", "#9AC7F5", "#C9F0E4", "#B6B4F2"], "#D4F4EE", "#000000", "#1F9C8F"),
    dark: v(["#16595C", "#153562", "#1F5E57", "#353070"], "#1E6B6B", "#FFFFFF", "#9FEDE2"),
    glyphs: ["diamond", "sparkle", "crown", "seal", "star", "rhombus", "hexagon", "octagon", "sparkles", "suitDiamond"],
  },
  {
    id: "teacher",
    name: "theme_teacher",
    emoji: "👨‍🏫",
    kind: "pattern",
    light: v(["#CFE8C9", "#9FD3C7", "#E7F0C3", "#B4D9A6"], "#E3F4D9", "#000000", "#4C9A4A"),
    dark: v(["#2B4D35", "#1A3628", "#3E5832", "#22473F"], "#2E5A38", "#FFFFFF", "#B4E3A8"),
    glyphs: ["book", "pencil", "gradCap", "ruler", "function", "atom", "globe", "backpack", "paperclip", "bulb", "books"],
  },
  {
    id: "tulip",
    name: "theme_tulip",
    emoji: "🌷",
    kind: "pattern",
    light: v(["#FFD1DC", "#F7A8C4", "#FFE4EC", "#F2B6D0"], "#FFDDE7", "#000000", "#D9467A"),
    dark: v(["#6E2447", "#43162D", "#852E55", "#561D38"], "#7A2A4E", "#FFFFFF", "#FFB3CE"),
    glyphs: ["flower", "leaf", "heart", "sun", "ladybug", "drop", "sparkles", "pollen", "cloud", "star"],
  },
  {
    id: "purple",
    name: "theme_purple",
    emoji: "💜",
    kind: "pattern",
    light: v(["#E2D4FA", "#C7B2F2", "#F0E6FF", "#D5B8EE"], "#EADFFF", "#000000", "#8A5CD8"),
    dark: v(["#45276F", "#29184B", "#5A318C", "#371F60"], "#563590", "#FFFFFF", "#D3BCFF"),
    glyphs: ["heart", "sparkles", "star", "moon", "music", "suitHeart", "balloon", "gift", "envelope", "smile"],
  },
  {
    id: "christmas",
    name: "theme_christmas",
    emoji: "🎄",
    kind: "pattern",
    light: v(["#D7EBD3", "#F3D8C5", "#C3E0C9", "#F1E3B3"], "#E2F2DC", "#000000", "#3D8E48"),
    dark: v(["#1D472D", "#572222", "#173A24", "#4C3A15"], "#2D5C3A", "#FFFFFF", "#B5E6BE"),
    glyphs: ["gift", "snowflake", "star", "bell", "tree", "flame", "sparkles", "moonStars", "cup", "music"],
  },
  {
    id: "game",
    name: "theme_game",
    emoji: "🎮",
    kind: "pattern",
    light: v(["#C9D6FF", "#E2C9FF", "#B8F0FF", "#D6E4FF"], "#DDE4FF", "#000000", "#5B6CF0"),
    dark: v(["#272E73", "#451E77", "#17456F", "#33216F"], "#3B3F9E", "#FFFFFF", "#C3C8FF"),
    glyphs: [
      "gamepad", "arcadeStick", "dpad", "trophy", "bolt", "star", "flag", "heart", "puzzle", "die", "crown", "keyboard",
    ],
  },
  { id: THEME_PHOTO, name: "theme_photo", emoji: "", kind: "photo", glyphs: [] },
];

export function themeById(id: string | null | undefined): SessionTheme {
  return THEMES.find((t) => t.id === id) ?? THEMES[0];
}

/**
 * The CSS variables a theme sets on the session column: the person's bubbles (`--bubble-user*`, which the Tailwind
 * colours read) and the service capsules (day headers, notices: dark glass with white text on a pattern or photo).
 */
export function themeVars(theme: SessionTheme, dark: boolean): Record<string, string> {
  const vars: Record<string, string> = {};
  if (theme.kind !== "plain") {
    vars["--service-bg"] = `rgb(0 0 0 / ${dark ? 0.4 : 0.22})`;
    vars["--service-fg"] = "#ffffff";
  }
  const variant = dark ? theme.dark : theme.light;
  if (variant) {
    vars["--bubble-user"] = variant.out;
    vars["--bubble-user-fg"] = variant.outText;
    vars["--bubble-user-meta"] = variant.outMeta;
  }
  return vars;
}

/** Where the gradient's four colours sit in the unit square (x right, y down). */
export const GRADIENT_POINTS: readonly (readonly [number, number])[] = [
  [0.8, 0.1],
  [0.2, 0.3],
  [0.75, 0.65],
  [0.25, 0.9],
];
const DARK_BASE = "#0B0D10";

function rgb(hex: string): [number, number, number] {
  const n = parseInt(hex.slice(1), 16);
  return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
}

/** The gradient at a small size: each pixel mixes the colours with weights `max(0, 0.9 − distance)⁴`, normalised. */
export function gradientCanvas(colors: readonly string[], width = 48, height = 64): HTMLCanvasElement {
  const canvas = document.createElement("canvas");
  canvas.width = width;
  canvas.height = height;
  const ctx = canvas.getContext("2d");
  if (!ctx) return canvas;
  const image = ctx.createImageData(width, height);
  const cs = colors.map(rgb);
  for (let row = 0; row < height; row++) {
    for (let col = 0; col < width; col++) {
      const x = col / (width - 1);
      const y = row / (height - 1);
      let sum = 0;
      const w = GRADIENT_POINTS.map(([px, py]) => {
        const d = Math.hypot(x - px, y - py);
        const value = Math.max(0, 0.9 - d) ** 4;
        sum += value;
        return value;
      });
      let r = 0;
      let g = 0;
      let b = 0;
      for (let i = 0; i < 4; i++) {
        const weight = sum > 0 ? w[i] / sum : 0.25;
        r += cs[i][0] * weight;
        g += cs[i][1] * weight;
        b += cs[i][2] * weight;
      }
      const at = (row * width + col) * 4;
      image.data[at] = Math.round(r);
      image.data[at + 1] = Math.round(g);
      image.data[at + 2] = Math.round(b);
      image.data[at + 3] = 255;
    }
  }
  ctx.putImageData(image, 0, 0);
  return canvas;
}

/** SplitMix64: the same doodles for the same seed, on every load. */
class SeededRandom {
  private state: bigint;
  constructor(seed: number) {
    this.state = (BigInt(seed) + 0x9e3779b97f4a7c15n) & 0xffffffffffffffffn;
  }
  next(): bigint {
    this.state = (this.state + 0x9e3779b97f4a7c15n) & 0xffffffffffffffffn;
    let z = this.state;
    z = ((z ^ (z >> 30n)) * 0xbf58476d1ce4e5b9n) & 0xffffffffffffffffn;
    z = ((z ^ (z >> 27n)) * 0x94d049bb133111ebn) & 0xffffffffffffffffn;
    return z ^ (z >> 31n);
  }
  /** 0 ≤ value < 1. */
  unit(): number {
    return Number(this.next() >> 11n) / 2 ** 53;
  }
}

export type Glyph = { name: DoodleName; x: number; y: number; size: number; angle: number };

/**
 * Where the doodles go: a jittered grid of 62 px cells (every other row shifted half a cell), sizes 22–30 px, turned
 * −25…25°, jitter ±12 px, from a generator seeded with the theme id. `scale` shrinks it all (theme cards).
 */
export function layoutGlyphs(theme: SessionTheme, width: number, height: number, scale = 1): Glyph[] {
  if (!theme.glyphs.length) return [];
  const random = new SeededRandom(fnv1a(theme.id) % 2147483647);
  const cell = 62 * scale;
  const columns = Math.ceil(width / cell) + 1;
  const rows = Math.ceil(height / cell) + 1;
  const glyphs: Glyph[] = [];
  for (let row = 0; row < rows; row++) {
    for (let column = 0; column < columns; column++) {
      const name = theme.glyphs[Number(random.next() % BigInt(theme.glyphs.length))];
      const shift = row % 2 === 0 ? 0 : cell / 2;
      const jitterX = (random.unit() * 24 - 12) * scale;
      const jitterY = (random.unit() * 24 - 12) * scale;
      glyphs.push({
        name,
        x: column * cell + shift + jitterX,
        y: row * cell + cell / 2 + jitterY,
        size: (22 + random.unit() * 8) * scale,
        angle: ((random.unit() * 50 - 25) * Math.PI) / 180,
      });
    }
  }
  return glyphs;
}

const paths = new Map<DoodleName, Path2D>();
function doodlePath(name: DoodleName): Path2D {
  let path = paths.get(name);
  if (!path) {
    path = new Path2D(DOODLES[name]);
    paths.set(name, path);
  }
  return path;
}

function drawGlyphs(ctx: CanvasRenderingContext2D, glyphs: Glyph[], color: string) {
  ctx.strokeStyle = color;
  ctx.lineCap = "round";
  ctx.lineJoin = "round";
  for (const glyph of glyphs) {
    const k = glyph.size / 24;
    ctx.save();
    ctx.translate(glyph.x, glyph.y);
    ctx.rotate(glyph.angle);
    ctx.scale(k, k);
    ctx.translate(-12, -12);
    ctx.lineWidth = 1.7;
    ctx.stroke(doodlePath(glyph.name));
    ctx.restore();
  }
}

/**
 * Paints a pattern theme into `canvas` (sized `width` × `height` CSS pixels at `ratio` device pixels each). Light: the
 * gradient, then the doodles in black at 12 %. Dark (Telegram's night patterns): near black, the gradient at 18 %, then
 * the doodles filled with the gradient itself at 55 %, so the pattern glows in the theme's colours.
 */
export function paintTheme(
  canvas: HTMLCanvasElement,
  theme: SessionTheme,
  dark: boolean,
  width: number,
  height: number,
  ratio: number,
  patternScale = 1,
): void {
  const variant = dark ? theme.dark : theme.light;
  const ctx = canvas.getContext("2d");
  if (!ctx || !variant || width < 1 || height < 1) return;
  const w = Math.max(1, Math.round(width * ratio));
  const h = Math.max(1, Math.round(height * ratio));
  if (canvas.width !== w) canvas.width = w;
  if (canvas.height !== h) canvas.height = h;
  const gradient = gradientCanvas(variant.colors);
  const glyphs = layoutGlyphs(theme, width, height, patternScale);
  ctx.setTransform(1, 0, 0, 1, 0, 0);
  ctx.globalAlpha = 1;
  ctx.globalCompositeOperation = "source-over";
  ctx.imageSmoothingEnabled = true;
  ctx.imageSmoothingQuality = "high";
  if (!dark) {
    ctx.drawImage(gradient, 0, 0, w, h);
    ctx.setTransform(ratio, 0, 0, ratio, 0, 0);
    drawGlyphs(ctx, glyphs, "rgb(0 0 0 / 0.12)");
    return;
  }
  ctx.fillStyle = DARK_BASE;
  ctx.fillRect(0, 0, w, h);
  ctx.globalAlpha = 0.18;
  ctx.drawImage(gradient, 0, 0, w, h);
  ctx.globalAlpha = 1;
  // The doodles as a mask, filled with the gradient, laid over at 55 %.
  const glow = document.createElement("canvas");
  glow.width = w;
  glow.height = h;
  const g = glow.getContext("2d");
  if (!g) return;
  g.setTransform(ratio, 0, 0, ratio, 0, 0);
  drawGlyphs(g, glyphs, "#ffffff");
  g.setTransform(1, 0, 0, 1, 0, 0);
  g.globalCompositeOperation = "source-in";
  g.imageSmoothingEnabled = true;
  g.imageSmoothingQuality = "high";
  g.drawImage(gradient, 0, 0, w, h);
  ctx.globalAlpha = 0.55;
  ctx.drawImage(glow, 0, 0);
  ctx.globalAlpha = 1;
}
