"use client";

import { createContext, Fragment, useCallback, useContext, useEffect, useMemo, useState } from "react";
import type { ReactNode } from "react";
import { readStorage, writeStorage } from "@/lib/browser";
import type { Lang, LangChoice, MessageKey, PluralBase, Vars } from "@/lib/i18n";
import { isLang, LANG_COOKIE, LANG_STORAGE_KEY, pickLang, pluralKey, translate } from "@/lib/i18n";

type I18n = {
  lang: Lang;
  /** What the person picked in the footer; "auto" follows the browser. */
  choice: LangChoice;
  setChoice: (choice: LangChoice) => void;
  t: (key: MessageKey, vars?: Vars) => string;
  /** Plural-aware: `tn("tool_calls", 3)` picks `tool_calls_one` / `tool_calls_other` and fills `{count}`. */
  tn: (base: PluralBase, count: number, vars?: Vars) => string;
  /** A string with React nodes in its placeholders, e.g. `{cmd}` → <code>crok remote login</code>. */
  tx: (key: MessageKey, nodes: Record<string, ReactNode>) => ReactNode;
};

const I18nContext = createContext<I18n | null>(null);

function writeCookie(choice: LangChoice) {
  try {
    document.cookie =
      choice === "auto"
        ? `${LANG_COOKIE}=; path=/; max-age=0; samesite=lax`
        : `${LANG_COOKIE}=${choice}; path=/; max-age=31536000; samesite=lax`;
  } catch {
    // ignore
  }
}

/**
 * The server picks the first language from the cookie or Accept-Language (so the first paint is already right);
 * here the localStorage choice, or the browser's own languages, take over.
 */
export function I18nProvider({
  initialLang,
  initialChoice,
  fixed = false,
  children,
}: {
  initialLang: Lang;
  initialChoice: LangChoice;
  /** Keep `initialLang` regardless of storage and browser (the dev preview's `?lang=`). */
  fixed?: boolean;
  children: ReactNode;
}) {
  const [choice, setChoiceState] = useState<LangChoice>(initialChoice);
  const [lang, setLang] = useState<Lang>(initialLang);

  useEffect(() => {
    if (fixed) return;
    // localStorage holds the choice; the cookie (initialChoice) mirrors it and stands in when storage was cleared.
    const stored = readStorage(LANG_STORAGE_KEY);
    const nextChoice: LangChoice = isLang(stored) ? stored : initialChoice;
    const nextLang = nextChoice === "auto" ? pickLang(navigator.languages ?? [navigator.language]) : nextChoice;
    setChoiceState(nextChoice);
    setLang(nextLang);
    if (nextChoice !== initialChoice) writeCookie(nextChoice);
    if (nextChoice !== "auto" && stored !== nextChoice) writeStorage(LANG_STORAGE_KEY, nextChoice);
    // Runs once on mount: the server's guess is replaced by what this browser knows.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  useEffect(() => {
    document.documentElement.lang = lang;
  }, [lang]);

  const setChoice = useCallback((next: LangChoice) => {
    setChoiceState(next);
    writeStorage(LANG_STORAGE_KEY, next === "auto" ? null : next);
    writeCookie(next);
    setLang(next === "auto" ? pickLang(navigator.languages ?? [navigator.language]) : next);
  }, []);

  const value = useMemo<I18n>(() => {
    const t = (key: MessageKey, vars?: Vars) => translate(lang, key, vars);
    return {
      lang,
      choice,
      setChoice,
      t,
      tn: (base, count, vars) => translate(lang, pluralKey(lang, base, count), { count, ...vars }),
      tx: (key, nodes) => {
        const template = translate(lang, key);
        const parts = template.split(/(\{\w+\})/g);
        return parts.map((part, i) => {
          const name = /^\{(\w+)\}$/.exec(part)?.[1];
          if (name && name in nodes) return <Fragment key={i}>{nodes[name]}</Fragment>;
          return part ? <Fragment key={i}>{part}</Fragment> : null;
        });
      },
    };
  }, [lang, choice, setChoice]);

  return <I18nContext.Provider value={value}>{children}</I18nContext.Provider>;
}

export function useI18n(): I18n {
  const value = useContext(I18nContext);
  if (!value) throw new Error("useI18n outside I18nProvider");
  return value;
}
