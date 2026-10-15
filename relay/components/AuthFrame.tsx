"use client";

import Link from "next/link";
import type { ReactNode } from "react";
import { Footer } from "./chrome";
import { useI18n } from "./I18nProvider";
import { CrokLogo } from "./ui";

/** The bar signed-out pages show: the logo (the language picker is in the footer). */
export function SignedOutHeader() {
  const { t } = useI18n();
  return (
    <header className="mx-auto flex h-16 w-full max-w-6xl items-center px-4 sm:px-6">
      <Link href="/" className="flex items-center">
        <CrokLogo size={26} name={t("app_name")} />
      </Link>
    </header>
  );
}

/** Sign-in and sign-up: Clerk's widget, centred, between the logo and the footer. */
export function AuthFrame({ children }: { children: ReactNode }) {
  return (
    <div className="flex min-h-dvh flex-col">
      <SignedOutHeader />
      <main className="flex flex-1 items-start justify-center px-4 py-8 sm:items-center">{children}</main>
      <Footer className="mx-auto w-full max-w-6xl" />
    </div>
  );
}
