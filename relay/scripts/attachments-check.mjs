#!/usr/bin/env node
/**
 * Checks the web's rules for photos and files in prompts (relay/DESIGN.md §5 "Photos and files in prompts") without a
 * browser: limits, which files are images and how they are re-encoded, sizes, names, the file rows' words and the
 * media grid, from lib/attachments.ts.
 *
 *   node scripts/attachments-check.mjs        (in relay/, after npm install)
 *
 * The app's TypeScript is compiled on the fly with the repo's own `typescript` (module hooks below), like
 * scripts/markdown-check.mjs.
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

const A = await import(pathToFileURL(join(root, "lib/attachments.ts")).href);

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
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
const eq = (name, got, want) => check(name, same(got, want), `expected ${JSON.stringify(want)}, got ${JSON.stringify(got)}`);

console.log("Limits");
eq("10 attachments", A.MAX_ATTACHMENTS, 10);
eq("20 MB a file", A.MAX_FILE_BYTES, 20 * 1024 * 1024);
eq("GIFs as they are up to 10 MB", A.MAX_GIF_BYTES, 10 * 1024 * 1024);
eq("2048 px images, 480 px thumbnails", [A.MAX_IMAGE_SIDE, A.THUMB_SIDE], [2048, 480]);
eq("JPEG 0.85, thumbnails 0.7", [A.JPEG_QUALITY, A.THUMB_QUALITY], [0.85, 0.7]);
{
  const r = A.admit([{ size: 1 }, { size: 2 }, { size: 3 }], 8);
  eq("two more fit after eight, the third is refused", [r.accepted, r.tooMany, r.tooBig], [[0, 1], true, false]);
  const big = A.admit([{ size: 21 * 1024 * 1024 }, { size: 10 }], 0);
  eq("a file over 20 MB is not added, the next one is", [big.accepted, big.tooMany, big.tooBig], [[1], false, true]);
  eq("exactly 20 MB is fine", A.admit([{ size: 20 * 1024 * 1024 }], 0).accepted, [0]);
}

console.log("Types");
eq("the system's type wins", A.fileType("a.pdf", "application/x-custom"), "application/x-custom");
eq("else by extension", A.fileType("Report.PDF", ""), "application/pdf");
eq("else application/octet-stream", A.fileType("Makefile", undefined), "application/octet-stream");
eq("image/jpg is image/jpeg", A.fileType("a.jpg", "image/jpg"), "image/jpeg");
eq("parameters are dropped", A.fileType("a.txt", "Text/Plain; charset=utf-8"), "text/plain");
eq("HEIC by extension", A.fileType("IMG_0001.HEIC", ""), "image/heic");
check("HEIC is prepared as an image", A.isImageType("image/heic"));
check("SVG stays a file", !A.isImageType("image/svg+xml"));
check("a PDF is a file", !A.isImageType("application/pdf"));

console.log("Re-encoding");
eq("4032×3024 → 2048×1536", A.fitSize(4032, 3024, 2048), { width: 2048, height: 1536 });
eq("a portrait screenshot", A.fitSize(1179, 2556, 2048), { width: 945, height: 2048 });
eq("never upscaled", A.fitSize(800, 600, 2048), { width: 800, height: 600 });
eq("a thin strip keeps a pixel", A.fitSize(5000, 1, 480), { width: 480, height: 1 });
eq("a thumbnail", A.fitSize(2048, 1536, 480), { width: 480, height: 360 });
eq("a GIF up to 10 MB goes as it is", A.imagePlan("image/gif", 10 * 1024 * 1024, false), { keep: true, type: "image/gif" });
eq("a bigger GIF is its first frame as JPEG", A.imagePlan("image/gif", 11 * 1024 * 1024, false), { keep: false, type: "image/jpeg" });
eq("a PNG stays a PNG", A.imagePlan("image/png", 100, false), { keep: false, type: "image/png" });
eq("a JPEG is re-encoded as JPEG", A.imagePlan("image/jpeg", 100, false), { keep: false, type: "image/jpeg" });
eq("a WebP with transparency becomes PNG", A.imagePlan("image/webp", 100, true), { keep: false, type: "image/png" });
eq("a WebP without becomes JPEG", A.imagePlan("image/webp", 100, false), { keep: false, type: "image/jpeg" });
eq("HEIC becomes JPEG", A.imagePlan("image/heic", 100, false), { keep: false, type: "image/jpeg" });

console.log("Names");
eq("the extension follows the uploaded type", A.renameForType("IMG_0001.HEIC", "image/jpeg"), "IMG_0001.jpg");
eq(".jpeg stays", A.renameForType("cat.jpeg", "image/jpeg"), "cat.jpeg");
eq("a WebP with transparency as PNG", A.renameForType("logo.webp", "image/png"), "logo.png");
eq("a name without extension gets one", A.renameForType("scan", "image/png"), "scan.png");
eq("a GIF keeps its name", A.renameForType("party.gif", "image/gif"), "party.gif");
eq("a file type leaves the name alone", A.renameForType("notes.md", "text/markdown"), "notes.md");
{
  const at = new Date(2026, 9, 27, 9, 5, 3);
  eq("photo-YYYYMMDD-HHMMSS.jpg, local time", A.photoName(at, 0), "photo-20261027-090503.jpg");
  eq("the second of one pick", A.photoName(at, 1), "photo-20261027-090503-2.jpg");
  eq("the third", A.photoName(at, 2), "photo-20261027-090503-3.jpg");
  eq("a PNG photo", A.photoName(at, 0, "image/png"), "photo-20261027-090503.png");
}
check("a pasted image.png has no name of its own", A.isPlaceholderName("image.png"));
check("image.jpeg neither", A.isPlaceholderName("image.jpeg"));
check("IMG_0001.png has one", !A.isPlaceholderName("IMG_0001.png"));

console.log("File rows");
eq("bytes", A.formatSize(12, "en"), "12 B");
eq("kilobytes, no decimals from 10", A.formatSize(840 * 1024, "en"), "840 KB");
eq("megabytes with one decimal", A.formatSize(1_258_291, "en"), "1.2 MB");
eq("20 MB", A.formatSize(20 * 1024 * 1024, "en"), "20 MB");
eq("German decimals", A.formatSize(1_258_291, "de"), "1,2 MB");
eq("size, then the extension in capitals", A.fileDetail("report.pdf", 1_258_291, "en"), "1.2 MB · PDF");
eq("no extension: the size alone", A.fileDetail("Makefile", 100, "en"), "100 B");
eq("a short name stays", A.middleTruncate("notes.md", 26), "notes.md");
{
  const long = A.middleTruncate("quarterly-numbers-final-version-3-reviewed.xlsx", 26);
  check("a long name keeps its end", Array.from(long).length === 26 && long.endsWith(".xlsx") && long.includes("…"), long);
}

console.log("Media");
eq("one image", A.gridRows(1), [[0]]);
eq("two side by side", A.gridRows(2), [[0, 1]]);
eq("three: the last full width", A.gridRows(3), [[0, 1], [2]]);
eq("four: two rows", A.gridRows(4), [[0, 1], [2, 3]]);
eq("five", A.gridRows(5), [[0, 1], [2, 3], [4]]);
eq("a landscape photo fills the width", A.singleImageBox(4032, 3024, 320, 320), { width: 320, height: 240 });
eq("a portrait one is at most 320 tall", A.singleImageBox(1179, 2556, 320, 320), { width: 148, height: 320 });
eq("a very tall one is letterboxed at 120 wide", A.singleImageBox(100, 2000, 320, 320), { width: 120, height: 320 });
eq("unknown size: square", A.singleImageBox(undefined, undefined, 320, 320), { width: 320, height: 320 });

console.log("Relay shapes");
eq(
  "sendPrompt input leaves out what is not there",
  A.attachmentInput({ storageId: "s1", name: "a.pdf", mimeType: "application/pdf", size: 3, kind: "file", url: null, thumbUrl: null }),
  { storageId: "s1", name: "a.pdf" },
);
eq(
  "and keeps the thumbnail and size of an image",
  A.attachmentInput({ storageId: "s1", thumbId: "t1", name: "a.jpg", mimeType: "image/jpeg", size: 3, kind: "image", width: 4, height: 3, url: null, thumbUrl: null }),
  { storageId: "s1", name: "a.jpg", thumbId: "t1", width: 4, height: 3 },
);
{
  const views = A.attachmentViews([{ name: "x.png", mimeType: "image/png", size: 5, kind: "image" }]);
  eq("stored attachments without URLs read as gone", [views[0].url, views[0].thumbUrl, views[0].kind], [null, null, "image"]);
  eq("nothing reads as nothing", A.attachmentViews(undefined), []);
  const relay = [
    { storageId: "s1", name: "a.jpg", mimeType: "image/jpeg", size: 1, kind: "image", url: "https://relay/a", thumbUrl: "https://relay/t" },
    { name: "b.md", mimeType: "text/markdown", size: 1, kind: "file", url: null, thumbUrl: null },
  ];
  const local = [
    { ...relay[0], url: "blob:a", thumbUrl: "blob:t", storageId: "s1" },
    { ...relay[1], url: "blob:b", thumbUrl: null, storageId: "s2" },
  ];
  const merged = A.withLocalCopies(relay, local);
  eq("this page's copies stand in for the relay's URLs", [merged[0].url, merged[0].thumbUrl], ["blob:a", "blob:t"]);
  eq("but not for what the relay no longer has", merged[1].url, null);
  eq("different counts: the relay's as they are", A.withLocalCopies(relay, local.slice(0, 1)), relay);
}

console.log(failures === 0 ? `\nAll ${checks} attachment checks passed.` : `\n${failures} of ${checks} checks failed.`);
process.exit(failures === 0 ? 0 : 1);
