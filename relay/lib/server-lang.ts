import "server-only";
import { cookies, headers } from "next/headers";
import type { Lang, LangChoice, MessageKey } from "./i18n";
import { isLang, LANG_COOKIE, parseAcceptLanguage, pickLang, translate } from "./i18n";

/** The first render's language: the footer choice (cookie) or else the browser's Accept-Language. */
export async function serverLang(): Promise<{ lang: Lang; choice: LangChoice }> {
  const cookie = (await cookies()).get(LANG_COOKIE)?.value;
  if (isLang(cookie)) return { lang: cookie, choice: cookie };
  const accept = (await headers()).get("accept-language");
  return { lang: pickLang(parseAcceptLanguage(accept)), choice: "auto" };
}

/** A page title in the visitor's language. */
export async function pageTitle(key: MessageKey): Promise<string> {
  const { lang } = await serverLang();
  return translate(lang, key);
}
