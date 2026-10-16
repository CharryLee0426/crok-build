"use client";

import { SignedOutHeader } from "@/components/AuthFrame";
import { Footer } from "@/components/chrome";
import { useI18n } from "@/components/I18nProvider";
import { ButtonLink, Notice } from "@/components/ui";

export default function NotFound() {
  const { t } = useI18n();
  return (
    <div className="flex min-h-dvh flex-col">
      <SignedOutHeader />
      <main className="flex flex-1 items-center justify-center">
        <Notice
          title={t("page_not_found_title")}
          action={
            <ButtonLink href="/" tone="primary">
              {t("go_home")}
            </ButtonLink>
          }
        >
          {t("page_not_found")}
        </Notice>
      </main>
      <Footer className="mx-auto w-full max-w-6xl" />
    </div>
  );
}
