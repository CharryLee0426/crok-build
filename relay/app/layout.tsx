import { ClerkProvider } from "@clerk/nextjs";
import type { Metadata, Viewport } from "next";
import type { ReactNode } from "react";
import { ConvexClientProvider } from "@/components/ConvexClientProvider";
import { I18nProvider } from "@/components/I18nProvider";
import { SettingsProvider } from "@/components/Settings";
import { ToastProvider } from "@/components/Toast";
import { translate } from "@/lib/i18n";
import { serverLang } from "@/lib/server-lang";
import { COLOR_MODE_SCRIPT } from "@/lib/settings";
import "./globals.css";

export async function generateMetadata(): Promise<Metadata> {
  const { lang } = await serverLang();
  const name = translate(lang, "app_name");
  return {
    title: { default: name, template: `%s · ${name}` },
    description: translate(lang, "landing_lead"),
    applicationName: name,
    robots: { index: true, follow: false },
  };
}

export const viewport: Viewport = {
  width: "device-width",
  initialScale: 1,
  viewportFit: "cover",
  themeColor: [
    { media: "(prefers-color-scheme: light)", color: "#eeeeee" },
    { media: "(prefers-color-scheme: dark)", color: "#141414" },
  ],
};

/** Clerk's widgets in the Crok palette; the CSS variables follow light and dark with the rest of the app. */
const clerkAppearance = {
  variables: {
    colorPrimary: "var(--accent)",
    colorPrimaryForeground: "var(--accent-fg)",
    colorBackground: "var(--surface)",
    colorForeground: "var(--fg)",
    colorMutedForeground: "var(--muted)",
    colorNeutral: "var(--fg)",
    colorInput: "var(--canvas)",
    colorInputForeground: "var(--fg)",
    colorBorder: "var(--line)",
    colorDanger: "var(--danger)",
    borderRadius: "0.75rem",
    fontFamily: "inherit",
  },
};

export default async function RootLayout({ children }: { children: ReactNode }) {
  const { lang, choice } = await serverLang();
  return (
    // suppressHydrationWarning: <html> attributes are set before hydration (lang by the I18n provider, data-theme by
    // the color-mode script below and the dev preview), which is expected.
    <html lang={lang} suppressHydrationWarning>
      <head>
        {/* Static: applies a stored Light or Dark color mode before the first paint (components/Settings.tsx). */}
        <script dangerouslySetInnerHTML={{ __html: COLOR_MODE_SCRIPT }} />
      </head>
      <body>
        <ClerkProvider dynamic signInUrl="/sign-in" signUpUrl="/sign-up" afterSignOutUrl="/" appearance={clerkAppearance}>
          <ConvexClientProvider>
            <I18nProvider initialLang={lang} initialChoice={choice}>
              <SettingsProvider>
                <ToastProvider>{children}</ToastProvider>
              </SettingsProvider>
            </I18nProvider>
          </ConvexClientProvider>
        </ClerkProvider>
      </body>
    </html>
  );
}
