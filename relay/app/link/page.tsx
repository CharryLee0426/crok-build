import { auth } from "@clerk/nextjs/server";
import type { Metadata } from "next";
import { SignedOutHeader } from "@/components/AuthFrame";
import { PageFrame } from "@/components/frames";
import { LinkApproval, LinkEntry } from "@/components/LinkDevice";
import { normalizeUserCode } from "@/lib/browser";
import { pageTitle } from "@/lib/server-lang";

export async function generateMetadata(): Promise<Metadata> {
  return { title: await pageTitle("link_title"), robots: { index: false } };
}

type SearchParams = Promise<Record<string, string | string[] | undefined>>;

function first(value: string | string[] | undefined): string {
  return (Array.isArray(value) ? value[0] : value) ?? "";
}

/**
 * `/link` asks for the code a device shows; `/link?code=XXXX-XXXX` (the link crok opens, `&app=1` from a phone's
 * browser sheet) is the approval page and needs a signed-in person: visitors go to sign-in and come back here.
 */
export default async function LinkPage({ searchParams }: { searchParams: SearchParams }) {
  const params = await searchParams;
  const code = normalizeUserCode(first(params.code));
  const app = first(params.app) === "1";
  if (!code) {
    // The code form works signed out too; approving it then asks for sign-in.
    const { userId } = await auth();
    return (
      <PageFrame gate={Boolean(userId)} header={userId ? undefined : <SignedOutHeader />}>
        <LinkEntry app={app} />
      </PageFrame>
    );
  }
  await auth.protect();
  return (
    <PageFrame>
      <LinkApproval code={code} app={app} />
    </PageFrame>
  );
}
