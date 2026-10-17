import { auth } from "@clerk/nextjs/server";
import type { Metadata } from "next";
import { NewSessionScreen } from "@/components/session/NewSession";
import { pageTitle } from "@/lib/server-lang";

export async function generateMetadata(): Promise<Metadata> {
  return { title: await pageTitle("new_session"), robots: { index: false } };
}

type SearchParams = Promise<Record<string, string | string[] | undefined>>;

function first(value: string | string[] | undefined): string {
  return (Array.isArray(value) ? value[0] : value) ?? "";
}

/** `/new?device=<deviceId>&path=<folder>`: a new session in that folder of that computer (DESIGN.md §5). */
export default async function NewSessionPage({ searchParams }: { searchParams: SearchParams }) {
  await auth.protect();
  const params = await searchParams;
  return <NewSessionScreen deviceId={first(params.device)} path={first(params.path)} />;
}
