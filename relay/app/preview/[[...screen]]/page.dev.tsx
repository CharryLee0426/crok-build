import { readFileSync } from "node:fs";
import { join } from "node:path";
import { notFound } from "next/navigation";
import { Preview } from "@/components/preview/Preview";
import { isLang } from "@/lib/i18n";

/**
 * Dev-only (`*.dev.tsx` is a page extension only under `next dev`, see next.config.ts): the signed-in screens with
 * fake data, for screenshots. `?theme=dark|light` forces the scheme, `?lang=` the language, `?device=&path=` the
 * new-session screen's project, `?stheme=` the session theme (`&blur=1` for the photo), `?computer=` the selected one.
 */
export default async function PreviewPage({
  params,
  searchParams,
}: {
  params: Promise<{ screen?: string[] }>;
  searchParams: Promise<Record<string, string | string[] | undefined>>;
}) {
  if (process.env.NODE_ENV === "production") notFound();
  const { screen } = await params;
  const query = await searchParams;
  const theme = query.theme === "dark" || query.theme === "light" ? query.theme : null;
  const lang = isLang(query.lang) ? query.lang : null;
  const device = typeof query.device === "string" ? query.device : null;
  const path = typeof query.path === "string" ? query.path : null;
  const sessionTheme = typeof query.stheme === "string" ? query.stheme : undefined;
  const computer = typeof query.computer === "string" ? query.computer : undefined;
  const name = screen?.join("/") ?? "index";
  // The session-markdown screens show the Markdown showcase the phone apps' demo data uses too.
  const showcase = name.startsWith("session-markdown")
    ? readFileSync(join(process.cwd(), "scripts/markdown-showcase.md"), "utf8")
    : undefined;
  return (
    <>
      {theme ? (
        <script
          // Static, validated value: sets the scheme before the first paint.
          dangerouslySetInnerHTML={{ __html: `document.documentElement.dataset.theme=${JSON.stringify(theme)};` }}
        />
      ) : null}
      <Preview
        screen={name}
        lang={lang}
        target={device && path ? { deviceId: device, path } : undefined}
        showcase={showcase}
        colorMode={theme ?? "system"}
        sessionTheme={sessionTheme}
        blur={query.blur === "1"}
        computer={computer}
      />
    </>
  );
}
