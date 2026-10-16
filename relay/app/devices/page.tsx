import { auth } from "@clerk/nextjs/server";
import type { Metadata } from "next";
import { DevicesScreen } from "@/components/Devices";
import { PageFrame } from "@/components/frames";
import { pageTitle } from "@/lib/server-lang";

export async function generateMetadata(): Promise<Metadata> {
  return { title: await pageTitle("devices_title"), robots: { index: false } };
}

export default async function DevicesPage() {
  await auth.protect();
  return (
    <PageFrame>
      <DevicesScreen />
    </PageFrame>
  );
}
