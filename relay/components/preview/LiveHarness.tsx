"use client";

/**
 * Dev-only (/preview/live): the real, data-bound screens against a Convex deployment without Clerk, signed in as a
 * linked device instead (the relay accepts device JWTs for every viewer function). Pass a device refresh token:
 * `/preview/live?refresh=crr_…&session=<sessionDocId>` (also `view=devices`, `view=link&code=…`).
 */
import { ConvexHttpClient } from "convex/browser";
import { ConvexProvider, ConvexReactClient } from "convex/react";
import { useEffect, useState } from "react";
import { api } from "@/convex/_generated/api";
import { AppHeader, ConnectionIndicator } from "@/components/chrome";
import { DevicesScreen } from "@/components/Devices";
import { ChatLayout, ChooseSession, PageFrame } from "@/components/frames";
import { LinkApproval } from "@/components/LinkDevice";
import { SessionsPane } from "@/components/SessionList";
import { SessionScreen } from "@/components/session/SessionScreen";

function useDeviceClient(refreshToken: string): ConvexReactClient | null {
  const [client, setClient] = useState<ConvexReactClient | null>(null);
  useEffect(() => {
    const url = process.env.NEXT_PUBLIC_CONVEX_URL!;
    const http = new ConvexHttpClient(url);
    const live = new ConvexReactClient(url);
    live.setAuth(async () => (await http.mutation(api.deviceAuth.refresh, { refreshToken })).accessToken);
    setClient(live);
    return () => {
      void live.close();
    };
  }, [refreshToken]);
  return client;
}

export function LiveHarness({ refresh, session, view, code }: { refresh: string; session?: string; view?: string; code?: string }) {
  const client = useDeviceClient(refresh);
  if (!client) return null;
  const header = <AppHeader account={<span className="h-8 w-8 rounded-full bg-accent" />} status={<ConnectionIndicator />} />;
  let body;
  if (view === "devices") {
    body = (
      <PageFrame header={header} gate={false}>
        <DevicesScreen />
      </PageFrame>
    );
  } else if (view === "link" && code) {
    body = (
      <PageFrame header={header} gate={false}>
        <LinkApproval code={code} app={false} />
      </PageFrame>
    );
  } else {
    body = (
      <ChatLayout header={header} pane={<SessionsPane activeId={session} />} inSession={Boolean(session)} gate={false}>
        {session ? <SessionScreen id={session} /> : <ChooseSession />}
      </ChatLayout>
    );
  }
  return <ConvexProvider client={client}>{body}</ConvexProvider>;
}
