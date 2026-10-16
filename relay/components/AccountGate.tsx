"use client";

import { useAuth } from "@clerk/nextjs";
import { useConvexAuth, useMutation } from "convex/react";
import { useRouter } from "next/navigation";
import { Component, useEffect, useState } from "react";
import type { ErrorInfo, ReactNode } from "react";
import { api } from "@/convex/_generated/api";
import { useI18n } from "./I18nProvider";
import { WarningIcon } from "./icons";
import { Button, Loading, Notice } from "./ui";

/** The Clerk user whose relay row exists already in this page load (`users:ensure` runs once per sign-in). */
let ensuredFor: string | null = null;

/**
 * Renders its children only once Convex accepted the Clerk token and the person's relay row exists
 * (`users:ensure`): every other relay call needs that row. Shows why when the relay rejects the sign-in.
 */
export function AccountGate({ children }: { children: ReactNode }) {
  const { t } = useI18n();
  const { isLoading, isAuthenticated } = useConvexAuth();
  const { isLoaded, isSignedIn, userId } = useAuth();
  const ensure = useMutation(api.users.ensure);
  const [ready, setReady] = useState(() => userId != null && ensuredFor === userId);
  const [failed, setFailed] = useState(false);
  const [attempt, setAttempt] = useState(0);

  useEffect(() => {
    if (!isAuthenticated || !userId) return;
    if (ensuredFor === userId) {
      setReady(true);
      return;
    }
    let cancelled = false;
    setFailed(false);
    ensure({}).then(
      () => {
        ensuredFor = userId;
        if (!cancelled) setReady(true);
      },
      () => {
        if (!cancelled) setFailed(true);
      },
    );
    return () => {
      cancelled = true;
    };
  }, [isAuthenticated, userId, ensure, attempt]);

  // Signed out (the account menu, another tab, an expired session): let the server decide where to go — the landing
  // page on `/`, sign-in (and back) on protected pages.
  const router = useRouter();
  useEffect(() => {
    if (isLoaded && !isSignedIn) router.refresh();
  }, [isLoaded, isSignedIn, router]);

  if (failed) {
    return (
      <Notice
        icon={<WarningIcon size={32} />}
        title={t("error_title")}
        action={<Button onClick={() => setAttempt((a) => a + 1)}>{t("try_again")}</Button>}
      >
        {t("err_network")}
      </Notice>
    );
  }
  if (!isLoaded || isLoading) return <Loading />;
  if (!isAuthenticated) {
    if (!isSignedIn) return <Loading />;
    return (
      <Notice icon={<WarningIcon size={32} />} title={t("gate_rejected_title")}>
        {t("gate_rejected")}
      </Notice>
    );
  }
  if (!ready) return <Loading />;
  return <>{children}</>;
}

type BoundaryProps = { fallback: (error: unknown, reset: () => void) => ReactNode; children: ReactNode; resetKey?: string };

/** Catches a query that throws (an unknown or foreign session id, a dropped row) and shows a friendly screen. */
export class ErrorBoundary extends Component<BoundaryProps, { error: unknown; key?: string }> {
  state: { error: unknown; key?: string } = { error: null, key: this.props.resetKey };

  static getDerivedStateFromError(error: unknown) {
    return { error };
  }

  static getDerivedStateFromProps(props: BoundaryProps, state: { error: unknown; key?: string }) {
    if (props.resetKey !== state.key) return { error: null, key: props.resetKey };
    return null;
  }

  componentDidCatch(error: unknown, info: ErrorInfo) {
    if (process.env.NODE_ENV !== "production") console.warn("Caught by ErrorBoundary:", error, info.componentStack);
  }

  render() {
    if (this.state.error) return this.props.fallback(this.state.error, () => this.setState({ error: null }));
    return this.props.children;
  }
}
