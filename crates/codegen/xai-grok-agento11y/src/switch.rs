//! The off switch, `[features] agent_observability` in config.toml (on unless it says `false`), and
//! the files crok follows while it runs.
//!
//! Neither app shows the switch: it is there for test runs and for a machine that must not report.
//! Every crok process (a TUI, each Crok Desktop conversation's `crok agent stdio`) looks at the file
//! before each model call, with one `stat`, and resolves the feature again only when the file
//! changed, so a change applies to sessions already running.

use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::SystemTime;

use xai_grok_config_types::{Feature, FeatureConfigLayers, FeatureSources};

/// A file's identity from the outside: both apps replace config.toml whole, so a write moves it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct Stamp {
    modified: Option<SystemTime>,
    len: u64,
}

impl Stamp {
    /// `None` when the file is missing or cannot be read.
    pub(crate) fn of(path: &Path) -> Option<Self> {
        let metadata = std::fs::metadata(path).ok()?;
        Some(Self {
            modified: metadata.modified().ok(),
            len: metadata.len(),
        })
    }
}

/// A value read from a file, kept until the file's stamp moves.
pub(crate) struct Followed<T> {
    path: PathBuf,
    last: Mutex<Option<(Option<Stamp>, T)>>,
}

impl<T: Clone> Followed<T> {
    pub(crate) fn new(path: PathBuf) -> Self {
        Self {
            path,
            last: Mutex::new(None),
        }
    }

    pub(crate) fn path(&self) -> &Path {
        &self.path
    }

    /// The value for the file as it is now; `read` runs only on the first call and after a change.
    pub(crate) fn get(&self, read: impl FnOnce(&Path) -> T) -> T {
        let stamp = Stamp::of(&self.path);
        let mut last = self
            .last
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if let Some((seen, value)) = last.as_ref()
            && *seen == stamp
        {
            return value.clone();
        }
        let value = read(&self.path);
        *last = Some((stamp, value.clone()));
        value
    }
}

/// Whether Agent Observability is on (it is unless switched off).
pub(crate) struct Switch {
    config: Followed<bool>,
    /// `GROK_AGENT_OBSERVABILITY` (or `CROK_AGENT_OBSERVABILITY`) as crok started; it outranks the file.
    env: Option<bool>,
    /// The config tier, read again after each change of the user file.
    layers: fn(&Path) -> FeatureConfigLayers,
}

impl Switch {
    /// Follows `config` (the user `config.toml`) with crok's own config loader, so a requirements pin,
    /// `managed_config.toml` and the `CROK_CONFIG` overlay count as they do for every other feature.
    pub(crate) fn new(config: PathBuf, env: Option<bool>) -> Self {
        Self {
            config: Followed::new(config),
            env,
            layers: effective_layers,
        }
    }

    /// Follows the user file alone, for tests that cannot point crok's config loader at a directory of their own.
    #[cfg(test)]
    pub(crate) fn following_user_file(config: PathBuf, env: Option<bool>) -> Self {
        Self {
            config: Followed::new(config),
            env,
            layers: tests::user_file_only,
        }
    }

    pub(crate) fn is_on(&self) -> bool {
        self.config.get(|path| {
            let layers = (self.layers)(path);
            Feature::AgentObservability
                .resolve(FeatureSources {
                    pin: layers.pin,
                    env: self.env,
                    config: layers.merged(),
                    remote: None,
                })
                .value
        })
    }
}

/// The feature's config tier from the layers crok merges its config from. A config that does not load
/// (an edit half done, a typo) counts as saying nothing, which is on; the next write is read again.
fn effective_layers(_user_config: &Path) -> FeatureConfigLayers {
    match xai_grok_config::effective_config::load_effective_config_with_layers() {
        Ok(loaded) => {
            Feature::AgentObservability.config_layers(&loaded.layers, &loaded.active_campaigns)
        }
        Err(err) => {
            tracing::debug!(%err, "config not read; Agent Observability keeps its default");
            FeatureConfigLayers::default()
        }
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    /// The user file alone, read from where the test wrote it.
    pub(super) fn user_file_only(path: &Path) -> FeatureConfigLayers {
        let user = std::fs::read_to_string(path)
            .ok()
            .and_then(|text| toml::from_str::<toml::Table>(&text).ok())
            .and_then(|doc| doc.get("features")?.get("agent_observability")?.as_bool());
        FeatureConfigLayers {
            user,
            ..FeatureConfigLayers::default()
        }
    }

    fn switch(config: &Path, env: Option<bool>) -> Switch {
        Switch::following_user_file(config.to_owned(), env)
    }

    /// Rewrites the file the way both apps do (a new file renamed over it).
    pub(crate) fn write(path: &Path, text: &str) {
        let partial = path.with_extension("partial");
        std::fs::write(&partial, text).unwrap();
        std::fs::rename(&partial, path).unwrap();
    }

    #[test]
    fn on_by_default_and_follows_the_file_while_running() {
        let home = tempfile::tempdir().unwrap();
        let config = home.path().join("config.toml");
        let switch = switch(&config, None);
        assert!(switch.is_on(), "no config.toml");
        write(&config, "[ui]\ntheme = \"auto\"\n");
        assert!(switch.is_on(), "no key");
        write(&config, "[features]\nagent_observability = false\n");
        assert!(!switch.is_on());
        write(&config, "[features]\nagent_observability = true\n");
        assert!(switch.is_on());
        std::fs::remove_file(&config).unwrap();
        assert!(switch.is_on());
    }

    #[test]
    fn the_environment_outranks_the_file() {
        let home = tempfile::tempdir().unwrap();
        let config = home.path().join("config.toml");
        write(&config, "[features]\nagent_observability = true\n");
        assert!(!switch(&config, Some(false)).is_on());
        write(&config, "[features]\nagent_observability = false\n");
        assert!(switch(&config, Some(true)).is_on());
    }

    #[test]
    fn the_file_is_read_again_only_when_it_changes() {
        let home = tempfile::tempdir().unwrap();
        let path = home.path().join("config.toml");
        write(&path, "a");
        let followed = Followed::new(path.clone());
        let reads = std::cell::Cell::new(0);
        let read = |_: &Path| {
            reads.set(reads.get() + 1);
            reads.get()
        };
        assert_eq!(followed.get(read), 1);
        assert_eq!(followed.get(read), 1);
        write(&path, "bb");
        assert_eq!(followed.get(read), 2);
        assert_eq!(followed.get(read), 2);
    }
}
