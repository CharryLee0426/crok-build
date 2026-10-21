//! `[remote]` in `$CROK_HOME/config.toml`, and where the relay is.
//!
//! ```toml
//! [remote]
//! enabled = true                                  # mirror sessions and take commands while signed in
//! url = "https://<deployment>.convex.cloud"       # only for a relay of your own; crok has one built in
//! ```

use std::path::{Path, PathBuf};

use anyhow::Context;

use crate::credentials::Credentials;

/// Env overrides. `CROK_*` names are what people type; crok copies them to `GROK_*` at startup.
const URL_ENVS: [&str; 2] = ["CROK_REMOTE_URL", "GROK_REMOTE_URL"];
const ENABLED_ENVS: [&str; 2] = ["CROK_REMOTE_CONTROL", "GROK_REMOTE_CONTROL"];
/// Set to `0` by Crok Desktop for its helper processes (command catalog, history, panels), which run no sessions of
/// their own and must not appear as hosts.
const BRIDGE_ENVS: [&str; 2] = ["CROK_REMOTE_BRIDGE", "GROK_REMOTE_BRIDGE"];

// `BUILT_IN_ENV`, `BUILT_IN_URL` and `ENVIRONMENTS`: the relay built into this binary, from
// `relay/environments/<CROK_RELAY_ENV>.env` (production unless a test build says `dev`), or a relay of one's own
// named by `CROK_REMOTE_DEFAULT_URL` at build time. See build.rs.
include!(concat!(env!("OUT_DIR"), "/relay_environment.rs"));

/// The environment (`prod`, `dev`) whose relay `url` is, if it is one of them.
pub fn environment_of(url: &str) -> Option<&'static str> {
    let url = normalize_url(url);
    ENVIRONMENTS
        .iter()
        .find(|(_, known)| normalize_url(known) == url)
        .map(|(name, _)| *name)
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct RemoteSettings {
    /// `[remote] enabled`; defaults to true (being signed in is the opt-in).
    pub enabled: bool,
    /// `[remote] url`: a relay of one's own instead of the built-in one.
    pub url: Option<String>,
}

pub fn config_path() -> PathBuf {
    xai_dirs::grok_home().join("config.toml")
}

fn env_value(names: &[&str]) -> Option<String> {
    names
        .iter()
        .find_map(|name| std::env::var(name).ok())
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
}

fn falsy(value: &str) -> bool {
    matches!(
        value.to_ascii_lowercase().as_str(),
        "0" | "false" | "no" | "off"
    )
}

pub fn load() -> RemoteSettings {
    load_from(&config_path())
}

pub fn load_from(path: &Path) -> RemoteSettings {
    let mut settings = RemoteSettings {
        enabled: true,
        url: None,
    };
    if let Ok(text) = std::fs::read_to_string(path)
        && let Ok(doc) = text.parse::<toml_edit::DocumentMut>()
        && let Some(remote) = doc.get("remote").and_then(|item| item.as_table_like())
    {
        if let Some(enabled) = remote.get("enabled").and_then(|item| item.as_bool()) {
            settings.enabled = enabled;
        }
        settings.url = remote
            .get("url")
            .and_then(|item| item.as_str())
            .map(str::trim)
            .filter(|url| !url.is_empty())
            .map(normalize_url);
    }
    if let Some(value) = env_value(&ENABLED_ENVS) {
        settings.enabled = !falsy(&value);
    }
    settings
}

/// Whether this process may run a bridge at all (Crok Desktop turns it off for helper processes).
pub fn bridge_allowed() -> bool {
    env_value(&BRIDGE_ENVS).is_none_or(|value| !falsy(&value))
}

/// `https://x.convex.cloud/` → `https://x.convex.cloud`.
pub fn normalize_url(url: &str) -> String {
    url.trim().trim_end_matches('/').to_string()
}

/// The relay to use: an explicit `--server`, then `CROK_REMOTE_URL`, then `[remote] url`, then the one the saved
/// credentials were issued by, then the one built into this binary, so nobody has to set it.
pub fn server_url(explicit: Option<&str>, credentials: Option<&Credentials>) -> String {
    explicit
        .map(normalize_url)
        .filter(|url| !url.is_empty())
        .or_else(|| env_value(&URL_ENVS).map(|url| normalize_url(&url)))
        .or_else(|| load().url)
        .or_else(|| credentials.map(|c| c.server.clone()))
        .unwrap_or_else(|| normalize_url(BUILT_IN_URL))
}

/// Rejects anything that is not an http(s) URL, so a typo fails at sign-in rather than at connect.
pub fn validate_url(url: &str) -> anyhow::Result<()> {
    let parsed = reqwest::Url::parse(url).with_context(|| format!("not a URL: {url}"))?;
    anyhow::ensure!(
        matches!(parsed.scheme(), "http" | "https"),
        "the relay URL must start with https:// (or http:// for a local relay): {url}"
    );
    Ok(())
}

fn edit_config(path: &Path, edit: impl FnOnce(&mut toml_edit::Table)) -> anyhow::Result<()> {
    let text = match std::fs::read_to_string(path) {
        Ok(text) => text,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => String::new(),
        Err(error) => return Err(error).with_context(|| format!("reading {}", path.display())),
    };
    let mut doc = text
        .parse::<toml_edit::DocumentMut>()
        .with_context(|| format!("{} is not valid TOML", path.display()))?;
    let remote = doc
        .entry("remote")
        .or_insert_with(|| toml_edit::Item::Table(toml_edit::Table::new()));
    let Some(table) = remote.as_table_mut() else {
        anyhow::bail!("[remote] in {} is not a table", path.display());
    };
    edit(table);
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)
            .with_context(|| format!("creating {}", parent.display()))?;
    }
    let tmp = path.with_extension("toml.crok-remote-tmp");
    std::fs::write(&tmp, doc.to_string()).with_context(|| format!("writing {}", tmp.display()))?;
    std::fs::rename(&tmp, path).with_context(|| format!("replacing {}", path.display()))?;
    Ok(())
}

/// Writes `[remote] enabled`.
pub fn save_enabled(enabled: bool) -> anyhow::Result<()> {
    edit_config(&config_path(), |table| {
        table["enabled"] = toml_edit::value(enabled);
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn defaults_to_enabled_without_a_section() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("config.toml");
        std::fs::write(&path, "[ui]\ntheme = \"auto\"\n").unwrap();
        let settings = load_from(&path);
        assert!(settings.enabled);
        assert_eq!(settings.url, None);
    }

    #[test]
    fn reads_the_section() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("config.toml");
        std::fs::write(
            &path,
            "[remote]\nenabled = false\nurl = \"https://a.convex.cloud/\"\n",
        )
        .unwrap();
        let settings = load_from(&path);
        assert!(!settings.enabled);
        assert_eq!(settings.url.as_deref(), Some("https://a.convex.cloud"));
    }

    #[test]
    fn edits_keep_the_rest_of_the_file() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("config.toml");
        std::fs::write(&path, "# mine\n[ui]\ntheme = \"auto\" # keep\n").unwrap();
        edit_config(&path, |table| {
            table["url"] = toml_edit::value("https://b.convex.cloud")
        })
        .unwrap();
        let text = std::fs::read_to_string(&path).unwrap();
        assert!(text.contains("# mine"));
        assert!(text.contains("theme = \"auto\" # keep"));
        assert!(text.contains("[remote]\nurl = \"https://b.convex.cloud\""));
    }

    #[test]
    fn a_relay_is_built_in() {
        assert!(validate_url(BUILT_IN_URL).is_ok());
        assert!(["prod", "dev", "custom"].contains(&BUILT_IN_ENV));
        if BUILT_IN_ENV != "custom" {
            assert_eq!(environment_of(BUILT_IN_URL), Some(BUILT_IN_ENV));
        }
    }

    #[test]
    fn both_environments_are_built_in() {
        let url_of = |env: &str| {
            ENVIRONMENTS
                .iter()
                .find(|(name, _)| *name == env)
                .map(|(_, url)| *url)
        };
        let (Some(prod), Some(dev)) = (url_of("prod"), url_of("dev")) else {
            panic!("relay/environments needs prod and dev: {ENVIRONMENTS:?}");
        };
        assert_ne!(prod, dev);
        for (name, url) in ENVIRONMENTS {
            assert!(validate_url(url).is_ok(), "{name}: {url}");
            assert_eq!(environment_of(&format!("{url}/")), Some(*name));
        }
        assert_eq!(environment_of("http://127.0.0.1:3210"), None);
    }

    #[test]
    fn urls_are_checked() {
        assert!(validate_url("https://x.convex.cloud").is_ok());
        assert!(validate_url("http://127.0.0.1:3210").is_ok());
        assert!(validate_url("x.convex.cloud").is_err());
        assert!(validate_url("ftp://x").is_err());
    }
}
