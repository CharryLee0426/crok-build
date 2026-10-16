import type { ReactNode } from "react";

/**
 * A small Markdown renderer for assistant replies. It builds React elements only (no HTML strings), so nothing in a
 * reply can inject markup or script. Links open only for http(s) and mailto; anything else (often a path on the
 * computer) shows as plain text. Covers what agents write: headings, paragraphs, fenced code, lists (nested),
 * blockquotes, tables, rules, and inline code / bold / italic / strike / links. Half-streamed input (an unclosed
 * fence or `**`) renders sensibly.
 */
export function renderMarkdown(source: string): ReactNode {
  const lines = source.replace(/\r\n?/g, "\n").split("\n");
  return <>{parseBlocks(lines, "b")}</>;
}

const FENCE = /^ {0,3}(`{3,}|~{3,})\s*([^`\s]*)[^`]*$/;
const HEADING = /^ {0,3}(#{1,6})\s+(.*?)\s*#*\s*$/;
const RULE = /^ {0,3}([-*_])(?:\s*\1){2,}\s*$/;
const QUOTE = /^ {0,3}>\s?/;
const LIST_ITEM = /^(\s*)([-*+]|\d{1,9}[.)])\s+(.*)$/;
const TABLE_SEP = /^\s*\|?\s*:?-{1,}:?\s*(\|\s*:?-{1,}:?\s*)*\|?\s*$/;

function indentOf(line: string): number {
  const match = /^[ \t]*/.exec(line)![0];
  return match.replace(/\t/g, "    ").length;
}

function isBlank(line: string): boolean {
  return line.trim() === "";
}

function startsBlock(line: string, next: string | undefined): boolean {
  return (
    FENCE.test(line) ||
    HEADING.test(line) ||
    RULE.test(line) ||
    QUOTE.test(line) ||
    LIST_ITEM.test(line) ||
    (line.includes("|") && next !== undefined && TABLE_SEP.test(next) && next.includes("-"))
  );
}

function parseBlocks(lines: string[], keyPrefix: string): ReactNode[] {
  const out: ReactNode[] = [];
  let i = 0;
  let n = 0;
  const key = () => `${keyPrefix}-${n++}`;

  while (i < lines.length) {
    const line = lines[i];
    if (isBlank(line)) {
      i++;
      continue;
    }

    const fence = FENCE.exec(line);
    if (fence) {
      const marker = fence[1];
      const lang = fence[2];
      const body: string[] = [];
      i++;
      while (i < lines.length) {
        const close = lines[i].trim();
        if (close.startsWith(marker[0].repeat(marker.length)) && /^[`~]+$/.test(close)) {
          i++;
          break;
        }
        body.push(lines[i]);
        i++;
      }
      out.push(
        <pre key={key()} data-lang={lang || undefined}>
          <code>{body.join("\n")}</code>
        </pre>,
      );
      continue;
    }

    const heading = HEADING.exec(line);
    if (heading) {
      const level = heading[1].length;
      const content = parseInline(heading[2], key());
      const Tag = `h${level}` as "h1" | "h2" | "h3" | "h4" | "h5" | "h6";
      out.push(<Tag key={key()}>{content}</Tag>);
      i++;
      continue;
    }

    if (RULE.test(line)) {
      out.push(<hr key={key()} />);
      i++;
      continue;
    }

    if (QUOTE.test(line)) {
      const body: string[] = [];
      while (i < lines.length && !isBlank(lines[i]) && (QUOTE.test(lines[i]) || body.length > 0)) {
        if (!QUOTE.test(lines[i]) && startsBlock(lines[i], lines[i + 1])) break;
        body.push(lines[i].replace(QUOTE, ""));
        i++;
      }
      const k = key();
      out.push(<blockquote key={k}>{parseBlocks(body, k)}</blockquote>);
      continue;
    }

    if (line.includes("|") && i + 1 < lines.length && TABLE_SEP.test(lines[i + 1]) && lines[i + 1].includes("-")) {
      const header = splitRow(line);
      const aligns = splitRow(lines[i + 1]).map((cell) => {
        const left = cell.startsWith(":");
        const right = cell.endsWith(":");
        return right && left ? "center" : right ? "right" : left ? "left" : undefined;
      });
      i += 2;
      const rows: string[][] = [];
      while (i < lines.length && !isBlank(lines[i]) && lines[i].includes("|")) {
        rows.push(splitRow(lines[i]));
        i++;
      }
      const k = key();
      out.push(
        <table key={k}>
          <thead>
            <tr>
              {header.map((cell, c) => (
                <th key={c} style={aligns[c] ? { textAlign: aligns[c] } : undefined}>
                  {parseInline(cell, `${k}-h${c}`)}
                </th>
              ))}
            </tr>
          </thead>
          <tbody>
            {rows.map((row, r) => (
              <tr key={r}>
                {header.map((_, c) => (
                  <td key={c} style={aligns[c] ? { textAlign: aligns[c] } : undefined}>
                    {parseInline(row[c] ?? "", `${k}-${r}-${c}`)}
                  </td>
                ))}
              </tr>
            ))}
          </tbody>
        </table>,
      );
      continue;
    }

    const item = LIST_ITEM.exec(line);
    if (item) {
      const [list, next] = parseList(lines, i, key());
      out.push(list);
      i = next;
      continue;
    }

    // Paragraph: until a blank line or the start of another block. Single newlines stay line breaks, as in the
    // terminal and Crok Desktop.
    const para: string[] = [line];
    i++;
    while (i < lines.length && !isBlank(lines[i]) && !startsBlock(lines[i], lines[i + 1])) {
      para.push(lines[i]);
      i++;
    }
    const k = key();
    const parts: ReactNode[] = [];
    para.forEach((p, idx) => {
      if (idx > 0) parts.push(<br key={`${k}-br${idx}`} />);
      parts.push(...parseInline(p.trim(), `${k}-${idx}`));
    });
    out.push(<p key={k}>{parts}</p>);
  }
  return out;
}

function parseList(lines: string[], start: number, k: string): [ReactNode, number] {
  const first = LIST_ITEM.exec(lines[start])!;
  const baseIndent = indentOf(first[1]);
  const ordered = /\d/.test(first[2]);
  const startNumber = ordered ? parseInt(first[2], 10) : undefined;
  const items: { lines: string[] }[] = [];
  let i = start;
  let loose = false;

  while (i < lines.length) {
    const line = lines[i];
    const match = LIST_ITEM.exec(line);
    if (match && indentOf(match[1]) === baseIndent && /\d/.test(match[2]) === ordered) {
      items.push({ lines: [match[3]] });
      i++;
      continue;
    }
    if (isBlank(line)) {
      // A blank line continues the list only if indented content (or another item) follows.
      const nextIdx = i + 1;
      const next = lines[nextIdx];
      if (next === undefined) break;
      const nextItem = LIST_ITEM.exec(next);
      if ((nextItem && indentOf(nextItem[1]) === baseIndent) || indentOf(next) > baseIndent) {
        if (items.length) items[items.length - 1].lines.push("");
        loose = true;
        i++;
        continue;
      }
      break;
    }
    if (indentOf(line) > baseIndent && items.length) {
      items[items.length - 1].lines.push(line.replace(new RegExp(`^\\s{0,${baseIndent + 4}}`), ""));
      i++;
      continue;
    }
    if (items.length && !startsBlock(line, lines[i + 1])) {
      // Lazy continuation of the item's paragraph.
      items[items.length - 1].lines.push(line.trim());
      i++;
      continue;
    }
    break;
  }

  const children = items.map((entry, idx) => {
    const ik = `${k}-${idx}`;
    const blocks = parseBlocks(entry.lines, ik);
    const tight = !loose && entry.lines.every((l) => !isBlank(l));
    // A tight item renders its first paragraph inline, so bullets don't get paragraph margins.
    return (
      <li key={ik}>
        {tight
          ? blocks.map((block) =>
              isParagraph(block) ? <span key={(block as { key: string }).key}>{paragraphChildren(block)}</span> : block,
            )
          : blocks}
      </li>
    );
  });

  const list = ordered ? (
    <ol key={k} start={startNumber !== 1 ? startNumber : undefined}>
      {children}
    </ol>
  ) : (
    <ul key={k}>{children}</ul>
  );
  return [list, i];
}

function isParagraph(node: ReactNode): boolean {
  return typeof node === "object" && node !== null && "type" in node && node.type === "p";
}

function paragraphChildren(node: ReactNode): ReactNode {
  return (node as { props: { children: ReactNode } }).props.children;
}

function splitRow(line: string): string[] {
  let row = line.trim();
  if (row.startsWith("|")) row = row.slice(1);
  if (row.endsWith("|") && !row.endsWith("\\|")) row = row.slice(0, -1);
  const cells: string[] = [];
  let current = "";
  for (let i = 0; i < row.length; i++) {
    const ch = row[i];
    if (ch === "\\" && row[i + 1] === "|") {
      current += "|";
      i++;
    } else if (ch === "|") {
      cells.push(current.trim());
      current = "";
    } else {
      current += ch;
    }
  }
  cells.push(current.trim());
  return cells;
}

// ---- Inline ----

type InlineRule = {
  re: RegExp;
  render: (m: RegExpExecArray, key: string) => ReactNode;
  /** Characters before the token the match swallowed (lookbehind substitute). */
  lead?: (m: RegExpExecArray) => string;
};

function safeHref(url: string): string | null {
  const trimmed = url.trim();
  if (/^https?:\/\//i.test(trimmed) || /^mailto:/i.test(trimmed)) return trimmed;
  return null;
}

function linkNode(text: ReactNode, url: string, key: string): ReactNode {
  const href = safeHref(url);
  if (!href) return <span key={key}>{text}</span>;
  return (
    <a key={key} href={href} target="_blank" rel="noopener noreferrer nofollow">
      {text}
    </a>
  );
}

const INLINE_RULES: InlineRule[] = [
  {
    re: /\\([\\`*_{}[\]()#+\-.!~|>])/g,
    render: (m) => m[1],
  },
  {
    re: /(`+)([\s\S]*?[^`])\1(?!`)/g,
    render: (m, key) => <code key={key}>{m[2].replace(/^ ([\s\S]*) $/, "$1")}</code>,
  },
  {
    re: /\[([^\]\n]+)\]\(\s*<?([^)\s>]+)>?(?:\s+"[^"]*")?\s*\)/g,
    render: (m, key) => linkNode(parseInline(m[1], key), m[2], key),
  },
  {
    re: /<((?:https?:\/\/|mailto:)[^>\s]+)>/g,
    render: (m, key) => linkNode(m[1], m[1], key),
  },
  {
    re: /https?:\/\/[^\s<>"]*[^\s<>".,:;'!?)\]}*_]/g,
    render: (m, key) => linkNode(m[0], m[0], key),
  },
  {
    re: /\*\*(?=\S)([\s\S]*?\S)\*\*/g,
    render: (m, key) => <strong key={key}>{parseInline(m[1], key)}</strong>,
  },
  {
    re: /(^|[^\w])__(?=\S)([\s\S]*?\S)__(?!\w)/g,
    lead: (m) => m[1],
    render: (m, key) => <strong key={key}>{parseInline(m[2], key)}</strong>,
  },
  {
    re: /~~(?=\S)([\s\S]*?\S)~~/g,
    render: (m, key) => <del key={key}>{parseInline(m[1], key)}</del>,
  },
  {
    re: /\*(?=[^\s*])([\s\S]*?[^\s*])\*(?!\*)/g,
    render: (m, key) => <em key={key}>{parseInline(m[1], key)}</em>,
  },
  {
    re: /(^|[^\w])_(?=[^\s_])([\s\S]*?[^\s_])_(?!\w)/g,
    lead: (m) => m[1],
    render: (m, key) => <em key={key}>{parseInline(m[2], key)}</em>,
  },
];

function parseInline(text: string, keyPrefix: string): ReactNode[] {
  const out: ReactNode[] = [];
  let pos = 0;
  let n = 0;
  // Cache each rule's next match; recompute only when the scan has moved past it.
  const next: (RegExpExecArray | null | undefined)[] = INLINE_RULES.map(() => undefined);

  while (pos < text.length) {
    let best = -1;
    let bestStart = Infinity;
    for (let r = 0; r < INLINE_RULES.length; r++) {
      let match = next[r];
      if (match === undefined || (match !== null && match.index < pos)) {
        const re = INLINE_RULES[r].re;
        re.lastIndex = pos;
        match = re.exec(text);
        next[r] = match;
      }
      if (!match) continue;
      const lead = INLINE_RULES[r].lead?.(match).length ?? 0;
      const start = match.index + lead;
      if (start < bestStart) {
        bestStart = start;
        best = r;
      }
    }
    if (best < 0) break;
    const match = next[best]!;
    const lead = INLINE_RULES[best].lead?.(match) ?? "";
    const tokenStart = match.index + lead.length;
    if (tokenStart > pos) out.push(text.slice(pos, tokenStart));
    out.push(INLINE_RULES[best].render(match, `${keyPrefix}.${n++}`));
    pos = match.index + match[0].length;
    if (pos <= tokenStart) pos = tokenStart + 1; // never loop on an empty match
  }
  if (pos < text.length) out.push(text.slice(pos));
  return out;
}
