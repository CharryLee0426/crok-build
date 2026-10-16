import { auth } from "@clerk/nextjs/server";
import { ChooseSession } from "@/components/frames";
import { Landing } from "@/components/Landing";

/** Signed out: the landing page. Signed in: the session list (from the layout) and, on wide screens, a placeholder. */
export default async function HomePage() {
  const { userId } = await auth();
  if (!userId) return <Landing />;
  return <ChooseSession />;
}
