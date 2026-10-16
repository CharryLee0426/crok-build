"use client";

import { useI18n } from "@/components/I18nProvider";
import { WarningIcon } from "@/components/icons";
import { Button, Notice } from "@/components/ui";

/** Last-resort boundary for a page that threw (screens catch the expected relay errors themselves). */
export default function ErrorPage({ reset }: { error: Error & { digest?: string }; reset: () => void }) {
  const { t } = useI18n();
  return (
    <div className="flex min-h-dvh items-center justify-center">
      <Notice
        icon={<WarningIcon size={32} />}
        title={t("error_title")}
        action={
          <Button tone="primary" onClick={reset}>
            {t("try_again")}
          </Button>
        }
      >
        {t("error_generic")}
      </Notice>
    </div>
  );
}
