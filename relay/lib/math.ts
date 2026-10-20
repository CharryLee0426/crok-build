/**
 * Finds LaTeX math in a reply before Markdown parsing (relay/DESIGN.md §5 "Replies in Markdown", rules 1–7; the iOS
 * and Android apps implement the same scanner). `$…$` and `\(…\)` are inline, `$$…$$` and `\[…\]` display. Each span
 * becomes a placeholder the Markdown parser reads as an ordinary word, so `\(` keeps its backslash and `_` / `*` in TeX
 * never turn into emphasis; the renderer swaps placeholders back for math.
 */

export type MathSpan = {
  /** The TeX between the delimiters, trimmed. */
  tex: string;
  /** A display block (its own centred line) rather than math inside the text. */
  display: boolean;
  /** The original text with its delimiters, put back wherever math cannot render (code, URLs, raw HTML). */
  source: string;
};

export type ExtractedMath = { text: string; math: MathSpan[] };

export const INLINE_OPEN = "";
export const INLINE_CLOSE = "";
export const DISPLAY_OPEN = "";
export const DISPLAY_CLOSE = "";

/** A placeholder: group 1 is an inline span's index, group 2 a display span's. */
export const PLACEHOLDER = /(\d+)|(\d+)/g;

// A fence: after leading spaces, `>` markers and an optional list marker, 3+ backticks or tildes.
const FENCE_OPEN = /^[ \t]*(?:>[ \t]*)*(?:(?:[-*+]|\d{1,9}[.)])[ \t]+)?(`{3,}|~{3,})(.*)$/;
const FENCE_CLOSE = /^[ \t]*(?:>[ \t]*)*(`{3,}|~{3,})[ \t]*$/;
// What may stand before a display `$$` on its line: spaces, `>` markers, a list marker.
const LINE_PREFIX = /^[ \t]*(?:>[ \t]*)*(?:(?:[-*+]|\d{1,9}[.)])[ \t]+)?$/;
// A line with nothing but spaces and `>` markers ends a paragraph, so no span crosses it.
const BLANK_LINE = /\n[ \t>]*\n/;

type Fence = { char: string; length: number };

function openFence(line: string): Fence | null {
  const match = FENCE_OPEN.exec(line);
  if (!match) return null;
  const run = match[1];
  // A backtick fence's info string has no backticks (```x``` is a code span).
  if (run[0] === "`" && match[2].includes("`")) return null;
  return { char: run[0], length: run.length };
}

function closesFence(line: string, fence: Fence): boolean {
  const match = FENCE_CLOSE.exec(line);
  return !!match && match[1][0] === fence.char && match[1].length >= fence.length;
}

function isSpace(ch: string | undefined): boolean {
  return ch === " " || ch === "\t" || ch === "\n" || ch === "\r";
}

function lineStartOf(text: string, index: number): number {
  return text.lastIndexOf("\n", index - 1) + 1;
}

/** The index of `closer` after `from`, unless a blank line comes first. */
function findCloser(text: string, from: number, closer: string): number {
  const at = text.indexOf(closer, from);
  if (at < 0) return -1;
  if (BLANK_LINE.test(text.slice(from, at))) return -1;
  return at;
}

/** Drops as many leading `>` markers from each continuation line as the opening line had (rule 5). */
function stripQuoteMarkers(tex: string, markers: number): string {
  if (markers === 0) return tex;
  const strip = new RegExp(`^[ \\t]*(?:>[ \\t]?){0,${markers}}`);
  return tex
    .split("\n")
    .map((line, index) => (index === 0 ? line : line.replace(strip, "")))
    .join("\n");
}

function quoteMarkersBefore(text: string, index: number): number {
  const prefix = /^[ \t]*(?:>[ \t]*)*/.exec(text.slice(lineStartOf(text, index), index))![0];
  return (prefix.match(/>/g) ?? []).length;
}

export function extractMath(source: string): ExtractedMath {
  const text = source.replace(/\r\n?/g, "\n");
  const math: MathSpan[] = [];
  let out = "";
  let i = 0;
  let fence: Fence | null = null;
  let atLineStart = true;

  const placeholder = (span: MathSpan) => {
    math.push(span);
    const index = math.length - 1;
    return span.display ? `${DISPLAY_OPEN}${index}${DISPLAY_CLOSE}` : `${INLINE_OPEN}${index}${INLINE_CLOSE}`;
  };

  /** A span from `open` (its delimiter `opener`) to `closer`; true if it was math and has been written out. */
  const trySpan = (open: number, opener: string, closer: string, display: (end: number) => boolean): boolean => {
    const close = findCloser(text, open + opener.length, closer);
    if (close < 0) return false;
    const end = close + closer.length;
    const tex = stripQuoteMarkers(text.slice(open + opener.length, close), quoteMarkersBefore(text, open)).trim();
    if (!tex) return false;
    out += placeholder({ tex, display: display(end), source: text.slice(open, end) });
    i = end;
    return true;
  };

  while (i < text.length) {
    if (atLineStart) {
      atLineStart = false;
      const eol = text.indexOf("\n", i);
      const end = eol < 0 ? text.length : eol;
      const line = text.slice(i, end);
      let verbatim = false;
      if (fence) {
        if (closesFence(line, fence)) fence = null;
        verbatim = true;
      } else {
        const opened = openFence(line);
        if (opened) {
          fence = opened;
          verbatim = true;
        }
      }
      if (verbatim) {
        out += line;
        i = end;
        if (i < text.length) {
          out += "\n";
          i++;
          atLineStart = true;
        }
        continue;
      }
    }

    const ch = text[i];
    if (ch === "\n") {
      out += ch;
      i++;
      atLineStart = true;
      continue;
    }

    if (ch === "\\") {
      const next = text[i + 1];
      if (next === "(" && trySpan(i, "\\(", "\\)", () => false)) continue;
      if (next === "[" && trySpan(i, "\\[", "\\]", () => true)) continue;
      if (next === undefined || next === "\n") {
        out += ch;
        i++;
      } else {
        out += ch + next;
        i += 2;
      }
      continue;
    }

    if (ch === "`") {
      let run = 1;
      while (text[i + run] === "`") run++;
      const ticks = "`".repeat(run);
      let close = -1;
      for (let at = text.indexOf(ticks, i + run); at >= 0; at = text.indexOf(ticks, at + 1)) {
        if (BLANK_LINE.test(text.slice(i + run, at))) break;
        if (text[at - 1] !== "`" && text[at + run] !== "`") {
          close = at;
          break;
        }
      }
      if (close < 0) {
        out += ticks;
        i += run;
      } else {
        out += text.slice(i, close + run);
        i = close + run;
      }
      continue;
    }

    if (ch === "$") {
      if (text[i + 1] === "$") {
        const startsLine = LINE_PREFIX.test(text.slice(lineStartOf(text, i), i));
        const display = (end: number) => {
          if (!startsLine) return false;
          const eol = text.indexOf("\n", end);
          return /^[ \t]*$/.test(text.slice(end, eol < 0 ? text.length : eol));
        };
        if (trySpan(i, "$$", "$$", display)) continue;
        out += "$$";
        i += 2;
        continue;
      }
      if (!isSpace(text[i + 1]) && text[i + 1] !== undefined) {
        const eol = text.indexOf("\n", i);
        const lineEnd = eol < 0 ? text.length : eol;
        let close = -1;
        for (let at = i + 1; at < lineEnd; at++) {
          const c = text[at];
          // No inline math across a code span (rule 1 keeps code spans whole).
          if (c === "`") break;
          if (c === "\\") {
            at++;
            continue;
          }
          if (c === "$" && !isSpace(text[at - 1]) && !/[0-9]/.test(text[at + 1] ?? "")) {
            close = at;
            break;
          }
        }
        if (close > i + 1) {
          const tex = text.slice(i + 1, close).trim();
          if (tex) {
            out += placeholder({ tex, display: false, source: text.slice(i, close + 1) });
            i = close + 1;
            continue;
          }
        }
      }
      out += ch;
      i++;
      continue;
    }

    out += ch;
    i++;
  }
  return { text: out, math };
}

/** Puts each placeholder's original source back (for code, URLs and raw HTML, where math does not render). */
export function restoreMathSource(text: string, math: readonly MathSpan[]): string {
  if (!math.length || !/[]/.test(text)) return text;
  return text.replace(PLACEHOLDER, (whole, inline?: string, display?: string) => {
    const span = math[Number(inline ?? display)];
    return span ? span.source : whole;
  });
}
