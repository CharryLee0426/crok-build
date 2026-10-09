use std::sync::atomic::{AtomicU8, Ordering};

mod catalog;

// ── Locale ────────────────────────────────────────────────────────────────────

/// All locales supported by the application.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum Locale {
    En = 0,
    ZhHans = 1,
    Ja = 2,
    Es = 3,
    Fr = 4,
    De = 5,
}

impl Locale {
    /// BCP-47 code used in settings and canonical UI language strings.
    pub fn code(self) -> &'static str {
        match self {
            Locale::En => "en",
            Locale::ZhHans => "zh-Hans",
            Locale::Ja => "ja",
            Locale::Es => "es",
            Locale::Fr => "fr",
            Locale::De => "de",
        }
    }
}

// ── Process-global current locale ─────────────────────────────────────────────

static CURRENT_LOCALE: AtomicU8 = AtomicU8::new(Locale::En as u8);

fn locale_from_u8(v: u8) -> Locale {
    match v {
        0 => Locale::En,
        1 => Locale::ZhHans,
        2 => Locale::Ja,
        3 => Locale::Es,
        4 => Locale::Fr,
        5 => Locale::De,
        _ => Locale::En,
    }
}

/// Replace the process-global locale used by [`t`] and friends.
pub fn set_locale(locale: Locale) {
    CURRENT_LOCALE.store(locale as u8, Ordering::Relaxed);
}

/// Return the process-global locale.
pub fn current_locale() -> Locale {
    locale_from_u8(CURRENT_LOCALE.load(Ordering::Relaxed))
}

/// Convenience wrapper — returns the BCP-47 code of the current locale.
pub fn locale_code() -> &'static str {
    current_locale().code()
}

// ── parse_locale ──────────────────────────────────────────────────────────────

/// Parse a locale preference string into a [`Locale`].
///
/// Accepted (case-insensitive, `_` and `-` interchangeable):
/// `en`, `zh`, `zh-Hans`, `zh_CN`, `zh-CN`, `ja`, `es`, `fr`, `de`.
pub fn parse_locale(s: &str) -> Option<Locale> {
    // Normalise: lowercase and replace '_' with '-'.
    let mut buf = [0u8; 16];
    let bytes = s.as_bytes();
    if bytes.len() > buf.len() {
        return None;
    }
    for (i, &b) in bytes.iter().enumerate() {
        buf[i] = if b == b'_' { b'-' } else { b.to_ascii_lowercase() };
    }
    let norm = std::str::from_utf8(&buf[..bytes.len()]).ok()?;

    match norm {
        "en" => Some(Locale::En),
        "zh" | "zh-hans" | "zh-cn" | "zh-tw" => Some(Locale::ZhHans),
        "ja" => Some(Locale::Ja),
        "es" => Some(Locale::Es),
        "fr" => Some(Locale::Fr),
        "de" => Some(Locale::De),
        _ => None,
    }
}

// ── from_system ───────────────────────────────────────────────────────────────

/// Detect the locale from environment variables.
///
/// Checks `LANG`, then `LC_ALL`, then `LC_MESSAGES` (first non-empty).
/// Strips encoding suffixes (e.g. `.UTF-8`) and territory codes (e.g. `_US`).
/// Falls back to [`Locale::En`] when no supported locale is detected.
pub fn from_system() -> Locale {
    let raw = ["LANG", "LC_ALL", "LC_MESSAGES"]
        .iter()
        .filter_map(|k| std::env::var(k).ok())
        .find(|v| !v.is_empty())
        .unwrap_or_default();

    if raw.is_empty() {
        return Locale::En;
    }

    // Strip encoding: "en_US.UTF-8" → "en_US"
    let without_enc = raw.split('.').next().unwrap_or(&raw);
    // Strip territory: "en_US" → "en"
    let lang_tag = without_enc.split('_').next().unwrap_or(without_enc);

    parse_locale(lang_tag).unwrap_or(Locale::En)
}

// ── resolve_locale ────────────────────────────────────────────────────────────

/// Resolve a user preference string to a concrete [`Locale`].
///
/// * `None`, `""`, or `"auto"` → system locale (via [`from_system`])
/// * otherwise → [`parse_locale`], falling back to system then [`Locale::En`]
pub fn resolve_locale(pref: Option<&str>) -> Locale {
    match pref {
        None | Some("") | Some("auto") => from_system(),
        Some(s) => parse_locale(s).unwrap_or_else(|| {
            let sys = from_system();
            if sys != Locale::En {
                sys
            } else {
                Locale::En
            }
        }),
    }
}

// ── Translation helpers ────────────────────────────────────────────────────────

fn lookup_with_fallback(key: &str) -> Option<&'static str> {
    let locale = current_locale();
    catalog::lookup(locale, key).or_else(|| {
        if locale == Locale::En {
            None
        } else {
            catalog::lookup(Locale::En, key)
        }
    })
}

/// Look up a message key in the current locale, falling back to English, then `""`.
pub fn t(key: &str) -> &'static str {
    lookup_with_fallback(key).unwrap_or("")
}

/// Look up a message key in the current locale (then English). Returns `fallback` on miss.
pub fn t_or<'a>(key: &str, fallback: &'a str) -> &'a str {
    lookup_with_fallback(key).unwrap_or(fallback)
}

// ── Settings convenience helpers ───────────────────────────────────────────────

/// Look up `setting.{key}.label` in the current locale (English fallback).
/// Returns `None` when the key is absent from the catalog.
pub fn settings_label(key: &str) -> Option<&'static str> {
    let mut buf = String::with_capacity(8 + key.len() + 6);
    buf.push_str("setting.");
    buf.push_str(key);
    buf.push_str(".label");
    lookup_with_fallback(&buf)
}

/// Look up `setting.{key}.description` in the current locale (English fallback).
/// Returns `None` when the key is absent from the catalog.
pub fn settings_description(key: &str) -> Option<&'static str> {
    let mut buf = String::with_capacity(8 + key.len() + 12);
    buf.push_str("setting.");
    buf.push_str(key);
    buf.push_str(".description");
    lookup_with_fallback(&buf)
}

// ── Category labels ────────────────────────────────────────────────────────────

/// Look up the display label for a settings category id.
///
/// Recognised ids: `appearance`, `mouse`, `editor`, `agent`, `privacy`,
/// `models`, `session`, `advanced`.
pub fn category_label(id: &str) -> Option<&'static str> {
    let mut buf = String::with_capacity(9 + id.len());
    buf.push_str("category.");
    buf.push_str(id);
    lookup_with_fallback(&buf)
}

// ── SUPPORTED_LOCALES ──────────────────────────────────────────────────────────

/// Ordered list of supported locale codes and their English display names,
/// suitable for populating a settings UI picker.
///
/// The first entry `("auto", "System")` represents the system-detected locale.
pub const SUPPORTED_LOCALES: &[(&str, &str)] = &[
    ("auto", "System"),
    ("en", "English"),
    ("zh-Hans", "Simplified Chinese"),
    ("ja", "Japanese"),
    ("es", "Spanish"),
    ("fr", "French"),
    ("de", "German"),
];

// ── canonical_ui_language ──────────────────────────────────────────────────────

/// Normalise a raw UI language preference value into one of the canonical
/// tokens understood by the settings UI: `auto`, `en`, `zh-Hans`, `ja`,
/// `es`, `fr`, `de`.
///
/// `None` or `""` returns `"auto"`. Unrecognised values also return `"auto"`.
pub fn canonical_ui_language(value: Option<&str>) -> &'static str {
    let s = match value {
        None | Some("") => return "auto",
        Some(s) => s,
    };
    if s.eq_ignore_ascii_case("auto") {
        return "auto";
    }
    match parse_locale(s) {
        Some(Locale::En) => "en",
        Some(Locale::ZhHans) => "zh-Hans",
        Some(Locale::Ja) => "ja",
        Some(Locale::Es) => "es",
        Some(Locale::Fr) => "fr",
        Some(Locale::De) => "de",
        None => "auto",
    }
}

// ── Tests ──────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_locale_basic() {
        assert_eq!(parse_locale("en"), Some(Locale::En));
        assert_eq!(parse_locale("EN"), Some(Locale::En));
        assert_eq!(parse_locale("zh"), Some(Locale::ZhHans));
        assert_eq!(parse_locale("zh-Hans"), Some(Locale::ZhHans));
        assert_eq!(parse_locale("zh_CN"), Some(Locale::ZhHans));
        assert_eq!(parse_locale("zh-CN"), Some(Locale::ZhHans));
        assert_eq!(parse_locale("ja"), Some(Locale::Ja));
        assert_eq!(parse_locale("es"), Some(Locale::Es));
        assert_eq!(parse_locale("fr"), Some(Locale::Fr));
        assert_eq!(parse_locale("de"), Some(Locale::De));
        assert_eq!(parse_locale("pt"), None);
        assert_eq!(parse_locale(""), None);
    }

    #[test]
    fn parse_locale_case_insensitive() {
        assert_eq!(parse_locale("JA"), Some(Locale::Ja));
        assert_eq!(parse_locale("De"), Some(Locale::De));
        assert_eq!(parse_locale("ZH-HANS"), Some(Locale::ZhHans));
    }

    #[test]
    fn resolve_auto_falls_back() {
        // resolve_locale with auto/None/empty should always return *some* Locale
        // without panicking, regardless of environment.
        let _ = resolve_locale(None);
        let _ = resolve_locale(Some(""));
        let _ = resolve_locale(Some("auto"));
    }

    #[test]
    fn resolve_known_pref() {
        assert_eq!(resolve_locale(Some("de")), Locale::De);
        assert_eq!(resolve_locale(Some("ja")), Locale::Ja);
        assert_eq!(resolve_locale(Some("zh-Hans")), Locale::ZhHans);
    }

    #[test]
    fn t_fallback_on_missing_key() {
        // A clearly invalid key should return the empty string.
        set_locale(Locale::En);
        assert_eq!(t("this.key.does.not.exist"), "");
        assert_eq!(t_or("this.key.does.not.exist", "default"), "default");
    }

    #[test]
    fn t_known_key() {
        set_locale(Locale::En);
        assert_eq!(t("common.cancel"), "Cancel");

        set_locale(Locale::De);
        assert_eq!(t("common.cancel"), "Abbrechen");

        set_locale(Locale::Ja);
        assert_eq!(t("common.cancel"), "キャンセル");

        // Reset to avoid polluting other tests.
        set_locale(Locale::En);
    }

    #[test]
    fn canonical_auto() {
        assert_eq!(canonical_ui_language(None), "auto");
        assert_eq!(canonical_ui_language(Some("")), "auto");
        assert_eq!(canonical_ui_language(Some("auto")), "auto");
        assert_eq!(canonical_ui_language(Some("AUTO")), "auto");
        assert_eq!(canonical_ui_language(Some("bogus")), "auto");
    }

    #[test]
    fn canonical_known() {
        assert_eq!(canonical_ui_language(Some("en")), "en");
        assert_eq!(canonical_ui_language(Some("zh-Hans")), "zh-Hans");
        assert_eq!(canonical_ui_language(Some("zh_CN")), "zh-Hans");
        assert_eq!(canonical_ui_language(Some("ja")), "ja");
        assert_eq!(canonical_ui_language(Some("es")), "es");
        assert_eq!(canonical_ui_language(Some("fr")), "fr");
        assert_eq!(canonical_ui_language(Some("de")), "de");
    }

    #[test]
    fn settings_helpers() {
        set_locale(Locale::En);
        assert_eq!(settings_label("ui_language"), Some("Interface language"));
        assert_eq!(
            settings_description("ui_language"),
            Some("Language for the terminal UI. System follows your locale when supported. Restart not required.")
        );
        assert_eq!(settings_label("compact_mode"), Some("Compact mode"));
        assert_eq!(category_label("appearance"), Some("Appearance"));
        assert_eq!(category_label("advanced"), Some("Advanced"));
        set_locale(Locale::En);
    }

    #[test]
    fn locale_code_roundtrip() {
        assert_eq!(Locale::ZhHans.code(), "zh-Hans");
        assert_eq!(Locale::En.code(), "en");
        assert_eq!(Locale::De.code(), "de");
    }

    #[test]
    fn supported_locales_starts_with_auto() {
        assert_eq!(SUPPORTED_LOCALES[0].0, "auto");
    }
}
