#!/usr/bin/env node
/**
 * Checks the web's Markdown rendering (relay/DESIGN.md §5 "Replies in Markdown") without a browser:
 *
 *   node scripts/markdown-check.mjs        (in relay/, after npm install)
 *
 * 1. The math test vectors from DESIGN.md against lib/math.ts (the scanner the phones implement too).
 * 2. scripts/markdown-showcase.md rendered to static HTML through lib/markdown.tsx: every labelled code block
 *    highlighted, every formula typeset by KaTeX (and the unsupported one shown as its source), tables in their
 *    scroller, no <img>, raw HTML as text, unsafe links as text.
 * 3. Half-streamed replies (an unclosed fence, an unclosed $$) render without throwing and keep their text.
 *
 * The app's TypeScript is compiled on the fly with the repo's own `typescript` (module hooks below), so the check runs
 * the real modules, `@/` imports included.
 */
import { existsSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { registerHooks } from "node:module";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import ts from "typescript";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");

registerHooks({
  resolve(specifier, context, next) {
    const local = specifier.startsWith("@/") ? join(root, specifier.slice(2)) : null;
    const relative =
      (specifier.startsWith("./") || specifier.startsWith("../")) && context.parentURL?.startsWith("file:")
        ? join(dirname(fileURLToPath(context.parentURL)), specifier)
        : null;
    const base = local ?? relative;
    if (base && !/\.[cm]?js$/.test(base)) {
      for (const candidate of [base, `${base}.ts`, `${base}.tsx`, join(base, "index.ts")]) {
        if (existsSync(candidate) && statSync(candidate).isFile()) {
          return { url: pathToFileURL(candidate).href, shortCircuit: true };
        }
      }
    }
    return next(specifier, context);
  },
  load(url, context, next) {
    if (url.endsWith(".css")) return { format: "module", source: "export {};", shortCircuit: true };
    if (url.endsWith(".ts") || url.endsWith(".tsx")) {
      const source = readFileSync(fileURLToPath(url), "utf8");
      const output = ts.transpileModule(source, {
        fileName: fileURLToPath(url),
        compilerOptions: {
          module: ts.ModuleKind.ESNext,
          target: ts.ScriptTarget.ES2022,
          jsx: ts.JsxEmit.ReactJSX,
          verbatimModuleSyntax: false,
          esModuleInterop: true,
        },
      });
      return { format: "module", source: output.outputText, shortCircuit: true };
    }
    return next(url, context);
  },
});

const { extractMath } = await import(pathToFileURL(join(root, "lib/math.ts")).href);
const { renderMarkdown, HIGHLIGHT } = await import(pathToFileURL(join(root, "lib/markdown.tsx")).href);
const { I18nProvider } = await import(pathToFileURL(join(root, "components/I18nProvider.tsx")).href);
const { createElement } = await import("react");
const { renderToStaticMarkup } = await import("react-dom/server");
const { createLowlight } = await import("lowlight");

let failures = 0;
let checks = 0;
function check(name, ok, detail = "") {
  checks++;
  if (ok) {
    console.log(`  ok   ${name}`);
  } else {
    failures++;
    console.log(`  FAIL ${name}${detail ? `\n       ${detail}` : ""}`);
  }
}

// ---- 1. Math test vectors (DESIGN.md) ----

console.log("Math scanner (DESIGN.md test vectors)");
const I = (tex) => ({ tex, display: false });
const D = (tex) => ({ tex, display: true });
const vectors = [
  ["Euler: $e^{i\\pi}+1=0$.", [I("e^{i\\pi}+1=0")]],
  ["costs $5 and $10", []],
  ["echo $HOME and $PATH", []],
  ["$ x $", []],
  ["$x$5", []],
  ["the $x$-axis", [I("x")]],
  ["\\$5 and \\$6", []],
  ["`$x$` and\n\n```\n$y$\n```", []],
  ["\\(a^2\\) and \\[b^2\\]", [I("a^2"), D("b^2")]],
  ["$$\n\\int_0^1 x\\,dx\n$$", [D("\\int_0^1 x\\,dx")]],
  ["a $$x$$ b", [I("x")]],
  ["> $$\n> a\n> $$", [D("a")]],
  ["| $a|b$ | c |", [I("a|b")]],
  ["$$\n\\frac{a}{", []],
];
for (const [input, expected] of vectors) {
  const { text, math } = extractMath(input);
  const got = math.map(({ tex, display }) => ({ tex, display }));
  const same = JSON.stringify(got) === JSON.stringify(expected);
  check(JSON.stringify(input), same, `expected ${JSON.stringify(expected)}, got ${JSON.stringify(got)}`);
  if (!expected.length) check(`  text unchanged: ${JSON.stringify(input)}`, text === input, JSON.stringify(text));
}
{
  const { text } = extractMath("> $$\n> a\n> $$");
  check("display math in a quote stays in the quote", text === "> 0", JSON.stringify(text));
  const fenced = "- item\n  ```sh\n  echo $x$\n  ```\n";
  check("fence inside a list item is copied untouched", extractMath(fenced).text === fenced);
  const quoted = "> ```\n> $a$\n> ```";
  check("fence inside a quote is copied untouched", extractMath(quoted).text === quoted);
  check("\\\\( is an escaped backslash, not math", extractMath("\\\\(x\\\\)").math.length === 0);
  check("no math across a blank line", extractMath("$$\na\n\nb\n$$").math.length === 0);
  check("unclosed \\( stays literal", extractMath("see \\(x").text === "see \\(x");
}

// ---- Highlight aliases the phones know ----

console.log("Highlighting: every phone language alias is known to the web");
const lowlight = createLowlight(HIGHLIGHT.languages);
lowlight.registerAlias(HIGHLIGHT.aliases);
const phoneAliases = `swift kotlin kt kts java rust rs go golang c h cpp c++ cc cxx hpp objc objective-c m mm csharp cs c#
  javascript js jsx mjs cjs typescript ts tsx mts python py python3 ruby rb php bash sh shell zsh console shellsession
  powershell ps1 pwsh json jsonc json5 yaml yml toml ini cfg conf properties sql html xml svg plist xhtml vue css scss
  less diff patch markdown md dockerfile docker makefile make mk lua dart scala graphql gql`.split(/\s+/).filter(Boolean);
const unknown = phoneAliases.filter((name) => !lowlight.registered(name));
check(`${phoneAliases.length} aliases registered`, unknown.length === 0, `unknown: ${unknown.join(" ")}`);

// ---- 2. The showcase ----

const render = (markdown) =>
  renderToStaticMarkup(
    createElement(I18nProvider, { initialLang: "en", initialChoice: "en", fixed: true }, renderMarkdown(markdown)),
  );

console.log("Showcase (scripts/markdown-showcase.md)");
const showcase = readFileSync(join(root, "scripts/markdown-showcase.md"), "utf8");
const started = performance.now();
const html = render(showcase);
const firstMs = performance.now() - started;
const again = performance.now();
render(showcase);
const secondMs = performance.now() - again;

// MARKDOWN_CHECK_HTML=<file> keeps the rendered showcase for a look.
if (process.env.MARKDOWN_CHECK_HTML) writeFileSync(process.env.MARKDOWN_CHECK_HTML, html);

const codeBlocks = [...html.matchAll(/<div class="md-code">([\s\S]*?)<\/pre><\/div>/g)].map((m) => m[1]);
const labelled = ["swift", "kotlin", "rust", "python", "ts", "bash", "json", "diff"];
for (const lang of labelled) {
  const block = codeBlocks.find((b) => b.includes(`<span class="md-code-lang">${lang}</span>`));
  check(`code block "${lang}" has a header and is highlighted`, !!block && /class="hljs-[a-z_]+/.test(block));
}
const plain = codeBlocks.find((b) => b.includes('<span class="md-code-lang"></span>'));
check("the unlabelled block has an empty language, no highlighting", !!plain && !/hljs-/.test(plain));
check("every code block has a Copy button", codeBlocks.length === 9 && codeBlocks.every((b) => b.includes(">Copy</span>")));
check("diff lines are inserted / deleted", /hljs-addition/.test(html) && /hljs-deletion/.test(html));
check("Kotlin template `${…}` survives", html.includes("${") || html.includes("$<span"), "");

const katexCount = (html.match(/class="katex"/g) ?? []).length;
const displayCount = (html.match(/class="md-math-display"/g) ?? []).length;
// Inline: e^{iπ}+1=0, \frac{a}{b}, x, O(n log n) in the table → 4; display: integral, matrix, polynomial → 3.
check(`KaTeX typeset 7 formulas (got ${katexCount})`, katexCount === 7);
check(`3 display formulas (got ${displayCount})`, displayCount === 3);
check(
  "unsupported TeX shows its source, muted",
  html.includes('<code class="md-math-source">$\\unknowncommand{x}$</code>'),
);
check("no KaTeX error markup", !html.includes("katex-error"));
check("money and shell dollars stay text", html.includes("costs $5 and $10") && html.includes("echo $HOME and $PATH"));

check("tables sit in a scroller", (html.match(/<div class="md-table"><table>/g) ?? []).length === 2);
check("table cells are capped", /<td[^>]*><div class="md-cell">/.test(html));
check("GFM alignment kept", /<th style="text-align:center">/.test(html) && /<td style="text-align:right">/.test(html));
check("<br> in a cell is a line break", /line one<br\/?>\s*line two/.test(html));
check("no <img> anywhere", !/<img\b/i.test(html));
check(
  "the image is a link, not fetched",
  /<a href="https:\/\/crok-relay\.vercel\.app\/icon\.svg"[^>]*>🖼 Crok logo<\/a>/.test(html),
);
check("raw HTML shows as text", html.includes("&lt;div class=&quot;x&quot;&gt;not a div&lt;/div&gt;"));
check("a path is not a link", html.includes("<span>main.rs</span>") && !html.includes('href="src/main.rs"'));
check("bare URL is a link", html.includes('href="https://crok-relay.vercel.app/sessions"'));
check("task items as ☑ / ☐", html.includes('<span class="md-task">☑</span>') && html.includes('<span class="md-task">☐</span>'));
check("nested quote", /<blockquote>[\s\S]*<blockquote>/.test(html));
check("three-level list", /<ol>[\s\S]*<ul>[\s\S]*<ol>/.test(html));
check("headings 1–6", [1, 2, 3, 4, 5, 6].every((n) => html.includes(`<h${n}>`)));
check("single newline is a line break", /it starts a new line|starts a new line/.test(html) && /<br\/?>\s*This line follows/.test(html));
check(`render takes ${firstMs.toFixed(1)} ms cold, ${secondMs.toFixed(1)} ms warm (warm < 60 ms)`, secondMs < 60);

console.log("Edge cases");
const linkedImage = render("[![shot](https://x.dev/a.png)](https://x.dev/page)");
check("a linked image is the link's text, no nested <a>", !/<a [^>]*>[^<]*<a /.test(linkedImage) && linkedImage.includes("🖼 shot"));
check("<BR /> in any case is a line break", /a<br\/?>\s*b/.test(render("a<BR />b")));
check("math in a link URL is put back as source", render("[x](https://x.dev/$a$b)").includes('href="https://x.dev/$a$b"'));
check("indented code keeps its dollars", render("    echo $a$ and $b$\n").includes("echo $a$ and $b$"));

// ---- 3. Half-streamed ----

console.log("Half-streamed replies");
const cut = showcase.indexOf("for f in *.log");
const partialFence = render(showcase.slice(0, cut + 10));
check("unclosed fence runs to the end as code", partialFence.endsWith("</code></pre></div>") || /for f in[\s\S]*<\/code><\/pre><\/div>$/.test(partialFence));
const partialMath = render("Display:\n\n$$\n\\int_0^\\infty e^{-x^2}");
check("unclosed $$ stays literal text", partialMath.includes("$$") && !partialMath.includes("katex"));
const partialBold = render("This is **almost bold");
check("unclosed ** stays literal", partialBold.includes("**almost bold"));

console.log(`\n${checks - failures}/${checks} checks passed`);
process.exit(failures ? 1 : 0);
