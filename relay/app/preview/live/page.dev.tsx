import { notFound } from "next/navigation";
import { LiveHarness } from "@/components/preview/LiveHarness";

/** Dev-only live harness (see components/preview/LiveHarness.tsx); never part of a production build. */
export default async function LivePreviewPage({
  searchParams,
}: {
  searchParams: Promise<Record<string, string | string[] | undefined>>;
}) {
  if (process.env.NODE_ENV === "production") notFound();
  const query = await searchParams;
  const one = (key: string) => (typeof query[key] === "string" ? (query[key] as string) : undefined);
  const refresh = one("refresh");
  if (!refresh) notFound();
  const theme = one("theme") === "dark" ? "dark" : one("theme") === "light" ? "light" : null;
  return (
    <>
      {theme ? (
        <script dangerouslySetInnerHTML={{ __html: `document.documentElement.dataset.theme=${JSON.stringify(theme)};` }} />
      ) : null}
      <LiveHarness refresh={refresh} session={one("session")} view={one("view")} code={one("code")} />
    </>
  );
}
