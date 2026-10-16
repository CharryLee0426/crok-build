import { notFound } from "next/navigation";
import { Preview } from "@/components/preview/Preview";
import { isLang } from "@/lib/i18n";

/**
 * Dev-only (`*.dev.tsx` is a page extension only under `next dev`, see next.config.ts): the signed-in screens with
 * fake data, for screenshots. `?theme=dark|light` forces the scheme, `?lang=` the language.
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
  return (
    <>
      {theme ? (
        <script
          // Static, validated value: sets the scheme before the first paint.
          dangerouslySetInnerHTML={{ __html: `document.documentElement.dataset.theme=${JSON.stringify(theme)};` }}
        />
      ) : null}
      <Preview screen={screen?.join("/") ?? "index"} lang={lang} />
    </>
  );
}
