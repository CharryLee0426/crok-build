//! The settings modal reads in every interface language: its rows, their descriptions, the options of
//! each chooser, and the chrome and toasts around them.
//!
//! These tests read the catalog with `lookup_in`, which takes the locale as an argument, so they never
//! change the process-wide locale other tests render with.

use super::registry::{SettingKind, SettingsRegistry, choice_group};
use std::path::Path;
use xai_grok_i18n::{ALL_LOCALES, Locale, lookup_in};

/// Option names that are the same in every language (theme and product names); the catalog has no entry
/// for them and the registry's own text shows.
const UNTRANSLATED_NAMES: &[(&str, &str)] = &[
    ("theme", "groknight"),
    ("theme", "grokday"),
    ("theme", "tokyonight"),
    ("theme", "rosepine-moon"),
    ("theme", "oscura-midnight"),
    ("voice_stt_provider", "openrouter"),
];

/// `key` has text in every language, and its English is `en`: the registry and the call sites keep the
/// English wording, so the catalog cannot drift from what the code says.
fn assert_translated(key: &str, en: &str) {
    assert_eq!(
        lookup_in(Locale::En, key),
        Some(en),
        "catalog English for {key} differs from the code's"
    );
    for &locale in ALL_LOCALES {
        let text = lookup_in(locale, key).unwrap_or_default();
        assert!(
            !text.trim().is_empty(),
            "{key} has no {} text",
            locale.code()
        );
    }
}

#[test]
fn every_setting_reads_in_every_language() {
    let registry = SettingsRegistry::defaults();
    for meta in registry.all() {
        assert_translated(&format!("setting.{}.label", meta.key), meta.label);
        assert_translated(
            &format!("setting.{}.description", meta.key),
            meta.description,
        );
    }
}

#[test]
fn every_choice_reads_in_every_language() {
    let registry = SettingsRegistry::defaults();
    for meta in registry.all() {
        let SettingKind::Enum { choices, .. } = &meta.kind else {
            continue;
        };
        let group = choice_group(meta.key);
        for choice in *choices {
            let name = format!("choice.{group}.{}", choice.canonical);
            if UNTRANSLATED_NAMES.contains(&(group, choice.canonical)) {
                assert_eq!(lookup_in(Locale::En, &name), None, "{name} is a name");
            } else {
                assert_translated(&name, choice.display);
            }
            let description = format!("{name}.description");
            if choice.description.trim().is_empty() {
                assert_eq!(lookup_in(Locale::En, &description), None);
            } else {
                assert_translated(&description, choice.description);
            }
        }
    }
}

/// A setting's description is more than its English in the other languages: the row's detail is the
/// part a reader most needs in their own language.
#[test]
fn descriptions_are_not_left_in_english() {
    let registry = SettingsRegistry::defaults();
    for meta in registry.all() {
        let key = format!("setting.{}.description", meta.key);
        for &locale in ALL_LOCALES {
            if locale == Locale::En {
                continue;
            }
            assert_ne!(
                lookup_in(locale, &key),
                Some(meta.description),
                "{key} is still English in {}",
                locale.code()
            );
        }
    }
}

/// The text of a Rust string literal starting at the opening quote; `None` when `source` does not start one.
fn string_literal(source: &str) -> Option<(String, usize)> {
    let mut chars = source.char_indices();
    if chars.next()?.1 != '"' {
        return None;
    }
    let mut text = String::new();
    while let Some((at, c)) = chars.next() {
        match c {
            '"' => return Some((text, at + 1)),
            '\\' => match chars.next()?.1 {
                'n' => text.push('\n'),
                't' => text.push('\t'),
                'u' => {
                    let rest = &source[at..];
                    let close = rest.find('}')?;
                    let code = u32::from_str_radix(&rest[3..close], 16).ok()?;
                    text.push(char::from_u32(code)?);
                    // `\u{` is consumed up to the `u`; skip the braces and digits
                    for _ in 0..close - 1 {
                        chars.next();
                    }
                }
                other => text.push(other),
            },
            other => text.push(other),
        }
    }
    None
}

/// Every `tr("key", "English")` call in `source`.
fn tr_calls(source: &str) -> Vec<(String, String)> {
    let mut calls = Vec::new();
    let mut from = 0;
    while let Some(found) = source[from..].find("tr(") {
        let at = from + found;
        from = at + 3;
        let before = source[..at].chars().next_back();
        if before.is_some_and(|c| c.is_alphanumeric() || c == '_') {
            continue; // another function whose name ends in `tr`
        }
        let args = source[at + 3..].trim_start();
        let Some((key, used)) = string_literal(args) else {
            continue;
        };
        let rest = args[used..].trim_start();
        let Some(rest) = rest.strip_prefix(',') else {
            continue;
        };
        if let Some((english, _)) = string_literal(rest.trim_start()) {
            calls.push((key, english));
        }
    }
    calls
}

fn rust_sources(dir: &Path, out: &mut Vec<std::path::PathBuf>) {
    for entry in std::fs::read_dir(dir).expect("source directory").flatten() {
        let path = entry.path();
        if path.is_dir() {
            rust_sources(&path, out);
        } else if path.extension().is_some_and(|e| e == "rs") {
            out.push(path);
        }
    }
}

/// Each `tr("key", "English")` in this crate names a catalog entry with that English and a translation
/// in every language. The English stays at the call site so the code reads on its own; this is what
/// keeps the two copies the same.
#[test]
fn every_tr_call_matches_the_catalog() {
    let mut files = Vec::new();
    rust_sources(
        &Path::new(env!("CARGO_MANIFEST_DIR")).join("src"),
        &mut files,
    );
    let mut seen = 0;
    for file in files {
        if file.ends_with("settings/i18n_tests.rs") {
            continue;
        }
        let source = std::fs::read_to_string(&file).expect("readable source");
        for (key, english) in tr_calls(&source) {
            assert_translated(&key, &english);
            seen += 1;
        }
    }
    assert!(
        seen > 100,
        "found only {seen} tr() calls: the scan is broken"
    );
}

#[test]
fn the_scan_reads_escapes_and_wrapped_calls() {
    let source = "x = tr(\n    \"a.b\",\n    \"\\u{2713} {label}: \\\"q\\\"\",\n); str(\"no\", \"no\"); xai_grok_i18n::tr(\"c\", \"d\")";
    assert_eq!(
        tr_calls(source),
        vec![
            ("a.b".to_string(), "\u{2713} {label}: \"q\"".to_string()),
            ("c".to_string(), "d".to_string()),
        ]
    );
}
