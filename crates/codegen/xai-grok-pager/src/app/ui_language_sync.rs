//! Picks up `[ui].ui_language` edits made by another process while the pager runs.
//!
//! Crok Desktop and the terminal share `~/.crok/config.toml`; whichever side changes
//! the interface language writes it there. Each side applies the file at launch, and
//! this poller lets a running pager follow a change made by the desktop (or by hand)
//! without a restart. It checks the file's metadata every [`POLL_INTERVAL`] and only
//! reads and parses the file when the stamp moved.

use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

/// How often the pager stats `config.toml`. One `stat` per tick; the file is read only on change.
pub(crate) const POLL_INTERVAL: Duration = Duration::from_secs(2);

/// What a change to `config.toml` looks like from the outside: both the desktop and
/// the terminal replace the file atomically, so mtime and size move together.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub(crate) struct ConfigStamp {
    exists: bool,
    modified: Option<SystemTime>,
    len: u64,
}

impl ConfigStamp {
    pub(crate) fn of(path: &Path) -> Self {
        match std::fs::metadata(path) {
            Ok(meta) => Self {
                exists: true,
                modified: meta.modified().ok(),
                len: meta.len(),
            },
            Err(_) => Self::default(),
        }
    }
}

/// Tracks the user `config.toml` and reports the canonical interface language when it changes.
pub(crate) struct UiLanguageSync {
    path: PathBuf,
    stamp: ConfigStamp,
}

impl UiLanguageSync {
    /// Starts from the current file state, so the first poll only fires on a later edit.
    pub(crate) fn start() -> Self {
        Self::at(xai_grok_shell::util::config::user_config_path())
    }

    pub(crate) fn at(path: PathBuf) -> Self {
        let stamp = ConfigStamp::of(&path);
        Self { path, stamp }
    }

    /// `Some(canonical)` when `config.toml` changed since the last poll, carrying the
    /// `[ui].ui_language` now on disk (`"auto"` when absent or unknown).
    pub(crate) fn poll(&mut self) -> Option<&'static str> {
        let stamp = ConfigStamp::of(&self.path);
        if stamp == self.stamp {
            return None;
        }
        self.stamp = stamp;
        Some(read_ui_language(&self.path))
    }
}

/// The canonical `[ui].ui_language` in `path`, `"auto"` when the file or key is missing or unparsable.
pub(crate) fn read_ui_language(path: &Path) -> &'static str {
    let raw = std::fs::read_to_string(path)
        .ok()
        .and_then(|text| toml::from_str::<toml::Value>(&text).ok())
        .and_then(|root| {
            root.get("ui")?
                .get("ui_language")?
                .as_str()
                .map(str::to_owned)
        });
    crate::settings::canonical_ui_language(raw.as_deref())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn write(path: &Path, text: &str) {
        let tmp = path.with_extension("tmp");
        std::fs::write(&tmp, text).unwrap();
        std::fs::rename(&tmp, path).unwrap();
    }

    #[test]
    fn read_ui_language_canonicalises_and_defaults() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("config.toml");
        assert_eq!(read_ui_language(&path), "auto", "missing file");
        write(&path, "[ui]\ntheme = \"dark\"\n");
        assert_eq!(read_ui_language(&path), "auto", "missing key");
        write(&path, "[ui]\nui_language = \"zh_CN\"\n");
        assert_eq!(read_ui_language(&path), "zh-Hans");
        write(&path, "[ui]\nui_language = \"klingon\"\n");
        assert_eq!(read_ui_language(&path), "auto", "unknown code");
        write(&path, "this is not toml = = =");
        assert_eq!(read_ui_language(&path), "auto", "unparsable file");
    }

    #[test]
    fn poll_fires_only_when_the_file_changes() {
        let dir = dir_with_config("[ui]\nui_language = \"en\"\n");
        let path = dir.path().join("config.toml");
        let mut sync = UiLanguageSync::at(path.clone());
        assert_eq!(sync.poll(), None, "unchanged since start");
        assert_eq!(sync.poll(), None);

        // Different content (and a new inode from the atomic replace) → one report.
        write(&path, "[ui]\nui_language = \"ja\"\n");
        assert_eq!(sync.poll(), Some("ja"));
        assert_eq!(sync.poll(), None, "reported once");
    }

    #[test]
    fn poll_reports_auto_when_the_file_disappears() {
        let dir = dir_with_config("[ui]\nui_language = \"de\"\n");
        let path = dir.path().join("config.toml");
        let mut sync = UiLanguageSync::at(path.clone());
        std::fs::remove_file(&path).unwrap();
        assert_eq!(sync.poll(), Some("auto"));
        assert_eq!(sync.poll(), None);
    }

    #[test]
    fn poll_starts_from_a_missing_file() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("config.toml");
        let mut sync = UiLanguageSync::at(path.clone());
        assert_eq!(sync.poll(), None);
        write(&path, "[ui]\nui_language = \"fr\"\n");
        assert_eq!(sync.poll(), Some("fr"));
    }

    fn dir_with_config(text: &str) -> tempfile::TempDir {
        let dir = tempfile::tempdir().unwrap();
        write(&dir.path().join("config.toml"), text);
        dir
    }
}
