"use client";

import type { Element, ElementContent } from "hast";
import katex from "katex";
import { common } from "lowlight";
import type { LanguageFn } from "lowlight";
import dart from "highlight.js/lib/languages/dart";
import dockerfile from "highlight.js/lib/languages/dockerfile";
import graphql from "highlight.js/lib/languages/graphql";
import powershell from "highlight.js/lib/languages/powershell";
import scala from "highlight.js/lib/languages/scala";
import { useState } from "react";
import type { ComponentProps, ReactNode } from "react";
import Markdown from "react-markdown";
import type { Components, ExtraProps } from "react-markdown";
import rehypeHighlight from "rehype-highlight";
import remarkBreaks from "remark-breaks";
import remarkGfm from "remark-gfm";
import { CheckIcon, CopyIcon } from "@/components/icons";
import { useI18n } from "@/components/I18nProvider";
import { extractMath, PLACEHOLDER, restoreMathSource } from "@/lib/math";
import type { MathSpan } from "@/lib/math";

/**
 * Assistant replies as GitHub-flavoured Markdown with math (relay/DESIGN.md §5 "Replies in Markdown"): react-markdown
 * with remark-gfm and remark-breaks (a single newline stays a line break, as in the terminal and Crok Desktop),
 * highlight.js for fenced code in a language it knows, KaTeX for math found by `extractMath` before parsing. It builds
 * React elements only; raw HTML in a reply shows as its text (`<br>` excepted), the one HTML string is KaTeX's own
 * output (`trust: false`, so TeX cannot add links or styles). Links open only for http(s) and mailto; anything else
 * (often a path on the computer) is plain text. Images are never fetched: they show as links.
 */
export function renderMarkdown(source: string): ReactNode {
  const { text, math } = extractMath(source);
  return (
    <Markdown
      remarkPlugins={[remarkGfm, remarkBreaks, [remarkCrok, { math }]]}
      rehypePlugins={[[rehypeHighlight, HIGHLIGHT]]}
      components={COMPONENTS}
    >
      {text}
    </Markdown>
  );
}

// ---- Highlighting ----

/**
 * react-markdown builds its processor on every render, and rehype-highlight registers its languages each time.
 * highlight.js keeps a grammar's compiled modes on the language object, so handing it the same object every time
 * compiles each grammar once instead of on every streamed chunk.
 */
function once(language: LanguageFn): LanguageFn {
  let defined: ReturnType<LanguageFn> | undefined;
  return (hljs) => (defined ??= language(hljs));
}

/** rehype-highlight's options: highlight.js "common" plus a few languages and the phone apps' aliases. */
export const HIGHLIGHT = {
  languages: Object.fromEntries(
    Object.entries({ ...common, dart, dockerfile, graphql, powershell, scala }).map(([name, fn]) => [name, once(fn)]),
  ),
  // The aliases the phone apps know that highlight.js does not have itself.
  aliases: {
    ini: ["cfg", "conf", "properties"],
    json: ["json5"],
    objectivec: ["objective-c", "m"],
    python: ["python3"],
    xml: ["vue"],
  },
};

// ---- Placeholders, images, raw HTML (an mdast pass after remark-gfm and remark-breaks) ----

type MdNode = {
  type: string;
  value?: string;
  url?: string;
  title?: string | null;
  alt?: string | null;
  lang?: string | null;
  meta?: string | null;
  label?: string | null;
  children?: MdNode[];
  data?: Record<string, unknown>;
};

/** Containers of blocks; anywhere else, raw HTML sits inside text. */
const FLOW = new Set(["root", "blockquote", "listItem", "footnoteDefinition"]);
const BR = /^<br\s*\/?>$/i;

function remarkCrok(options: { math: readonly MathSpan[] }) {
  const { math } = options;
  const restore = (value: string) => restoreMathSource(value, math);

  const mathNode = (span: MathSpan): MdNode => ({
    type: "crokMath",
    data: {
      hName: "crok-math",
      hProperties: { dataTex: span.tex, dataDisplay: span.display, dataSource: span.source },
      hChildren: [],
    },
  });

  const splitMath = (value: string): MdNode[] => {
    if (!math.length || !/[]/.test(value)) return [{ type: "text", value }];
    const out: MdNode[] = [];
    let last = 0;
    for (const match of value.matchAll(PLACEHOLDER)) {
      const span = math[Number(match[1] ?? match[2])];
      if (!span) continue;
      if (match.index > last) out.push({ type: "text", value: value.slice(last, match.index) });
      out.push(mathNode(span));
      last = match.index + match[0].length;
    }
    if (last < value.length) out.push({ type: "text", value: value.slice(last) });
    return out;
  };

  const textWithBreaks = (value: string): MdNode[] =>
    value.split("\n").flatMap((line, index) => (index ? [{ type: "break" }, { type: "text", value: line }] : [{ type: "text", value: line }]));

  const walk = (parent: MdNode, inLink: boolean) => {
    if (!parent.children) return;
    const flow = FLOW.has(parent.type);
    const out: MdNode[] = [];
    for (const node of parent.children) {
      switch (node.type) {
        case "text":
          out.push(...splitMath(node.value ?? ""));
          continue;
        case "html": {
          const value = restore(node.value ?? "");
          if (BR.test(value.trim())) {
            if (!flow) out.push({ type: "break" });
          } else if (flow) {
            out.push({ type: "paragraph", children: textWithBreaks(value) });
          } else {
            out.push({ type: "text", value });
          }
          continue;
        }
        case "image":
        case "imageReference": {
          const alt = restore(node.alt ?? "");
          const url = node.url ? restore(node.url) : "";
          const label = { type: "text", value: `🖼 ${alt || url || node.label || ""}`.trimEnd() };
          if (inLink || !url) out.push(label);
          else out.push({ type: "link", url, title: node.title ? restore(node.title) : null, children: [label] });
          continue;
        }
      }
      for (const key of ["value", "url", "title", "lang", "meta"] as const) {
        const field = node[key];
        if (typeof field === "string") node[key] = restore(field);
      }
      walk(node, inLink || node.type === "link" || node.type === "linkReference");
      out.push(node);
    }
    parent.children = dropBreaksAroundDisplay(out);
  };

  return (tree: MdNode) => walk(tree, false);
}

const isDisplayMath = (node: MdNode | undefined) =>
  node?.type === "crokMath" && (node.data?.hProperties as { dataDisplay?: boolean } | undefined)?.dataDisplay === true;
const isBlankText = (node: MdNode) => node.type === "text" && !node.value?.trim();

/** A display formula is its own line already: line breaks right before or after it would add empty lines. */
function dropBreaksAroundDisplay(nodes: MdNode[]): MdNode[] {
  if (!nodes.some(isDisplayMath)) return nodes;
  const neighbour = (from: number, step: number) => {
    let at = from + step;
    while (at >= 0 && at < nodes.length && isBlankText(nodes[at])) at += step;
    return nodes[at];
  };
  return nodes.filter((node, index) => node.type !== "break" || !(isDisplayMath(neighbour(index, -1)) || isDisplayMath(neighbour(index, 1))));
}

// ---- Math ----

const texCache = new Map<string, string | null>();

/** KaTeX's HTML for a formula, or null for TeX it cannot render (shown as its source instead, never as an error). */
function renderTex(tex: string, display: boolean): string | null {
  const key = (display ? "D" : "I") + tex;
  const hit = texCache.get(key);
  if (hit !== undefined) return hit;
  let html: string | null;
  try {
    html = katex.renderToString(tex, { displayMode: display, throwOnError: true, trust: false, strict: "ignore" });
  } catch {
    html = null;
  }
  if (texCache.size >= 500) texCache.delete(texCache.keys().next().value!);
  texCache.set(key, html);
  return html;
}

function MathElement({ node }: ExtraProps) {
  const props = node?.properties ?? {};
  const tex = String(props.dataTex ?? "");
  const display = props.dataDisplay === true;
  const html = renderTex(tex, display);
  if (html === null) {
    const fallback = <code className="md-math-source">{String(props.dataSource ?? tex)}</code>;
    return display ? <span className="md-math-display">{fallback}</span> : fallback;
  }
  return <span className={display ? "md-math-display" : "md-math"} dangerouslySetInnerHTML={{ __html: html }} />;
}

// ---- Code blocks ----

function textOf(node: ElementContent | Element | undefined): string {
  if (!node) return "";
  if (node.type === "text") return node.value;
  if (node.type === "element") return node.children.map(textOf).join("");
  return "";
}

function CodeBlock({ node, children }: ComponentProps<"pre"> & ExtraProps) {
  const code = node?.children.find((child): child is Element => child.type === "element" && child.tagName === "code");
  const classes = code?.properties.className;
  const language = Array.isArray(classes)
    ? classes.map(String).find((name) => name.startsWith("language-"))?.slice("language-".length)
    : undefined;
  return (
    <div className="md-code">
      <div className="md-code-head">
        <span className="md-code-lang">{language ?? ""}</span>
        <CopyCode text={textOf(code).replace(/\n$/, "")} />
      </div>
      <pre>{children}</pre>
    </div>
  );
}

function CopyCode({ text }: { text: string }) {
  const { t } = useI18n();
  const [copied, setCopied] = useState(false);
  return (
    <button
      type="button"
      className="md-code-copy"
      onClick={() => {
        navigator.clipboard?.writeText(text).then(
          () => {
            setCopied(true);
            window.setTimeout(() => setCopied(false), 1500);
          },
          () => {},
        );
      }}
    >
      {copied ? <CheckIcon size={13} /> : <CopyIcon size={13} />}
      <span>{copied ? t("copied") : t("copy")}</span>
    </button>
  );
}

// ---- Links, tables, task items ----

function safeHref(url: string | undefined): string | null {
  const trimmed = (url ?? "").trim();
  if (/^https?:\/\//i.test(trimmed) || /^mailto:/i.test(trimmed)) return trimmed;
  return null;
}

function Link({ href, title, children }: ComponentProps<"a"> & ExtraProps) {
  const safe = safeHref(href);
  if (!safe) return <span>{children}</span>;
  return (
    <a href={safe} title={title} target="_blank" rel="noopener noreferrer nofollow">
      {children}
    </a>
  );
}

function Table({ children }: ComponentProps<"table"> & ExtraProps) {
  return (
    <div className="md-table">
      <table>{children}</table>
    </div>
  );
}

// A cell's content in a box capped at 28em, so a column wraps at word boundaries there and the table scrolls instead.
function HeaderCell({ node: _node, children, ...rest }: ComponentProps<"th"> & ExtraProps) {
  return (
    <th {...rest}>
      <div className="md-cell">{children}</div>
    </th>
  );
}

function Cell({ node: _node, children, ...rest }: ComponentProps<"td"> & ExtraProps) {
  return (
    <td {...rest}>
      <div className="md-cell">{children}</div>
    </td>
  );
}

function Input({ node: _node, ...rest }: ComponentProps<"input"> & ExtraProps) {
  if (rest.type !== "checkbox") return <input {...rest} />;
  return <span className="md-task">{rest.checked ? "☑" : "☐"}</span>;
}

const COMPONENTS = {
  a: Link,
  input: Input,
  pre: CodeBlock,
  table: Table,
  td: Cell,
  th: HeaderCell,
  "crok-math": MathElement,
} as Components;
