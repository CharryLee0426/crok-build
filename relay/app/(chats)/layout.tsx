import { auth } from "@clerk/nextjs/server";
import type { ReactNode } from "react";
import { ChatsFrame } from "@/components/frames";

/**
 * `/` and `/sessions/[id]` share this layout so the session list stays mounted (and subscribed) while you move
 * between sessions. Signed-out visitors get the page alone: the landing on `/`, a sign-in redirect elsewhere.
 */
export default async function ChatsLayout({ children }: { children: ReactNode }) {
  const { userId } = await auth();
  if (!userId) return children;
  return <ChatsFrame>{children}</ChatsFrame>;
}
