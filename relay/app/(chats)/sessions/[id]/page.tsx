import { auth } from "@clerk/nextjs/server";
import type { Metadata } from "next";
import { SessionScreen } from "@/components/session/SessionScreen";
import { pageTitle } from "@/lib/server-lang";

export async function generateMetadata(): Promise<Metadata> {
  return { title: await pageTitle("nav_sessions"), robots: { index: false } };
}

export default async function SessionPage({ params }: { params: Promise<{ id: string }> }) {
  await auth.protect();
  const { id } = await params;
  return <SessionScreen id={decodeURIComponent(id)} />;
}
