//! Where the bridge's settings come from: `~/.crok/agento11y.env`, else the destination built into
//! crok (`build.rs`), else the process environment.
//!
//! Release builds carry the destination, so an install reports with nothing set up. The file
//! overrides it on one machine (another stack, or `AGENTO11Y_ENABLED=false`); crok keeps
//! credentials in owner-only files under its home, and Crok Desktop, started from Finder, never
//! sees a shell's exports. The file and the built-in destination are each the whole
//! configuration: inherited `AGENTO11Y_*` and `OTEL_*` variables are dropped, so an exporter set
//! up for another tool cannot redirect crok's data.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

/// The settings file inside crok's home.
pub const ENV_FILE_NAME: &str = "agento11y.env";

/// Variable prefixes handed to the bridge; everything else in the file is ignored.
const BRIDGE_PREFIXES: [&str; 3] = ["AGENTO11Y_", "OTEL_", "CROK_AGENTO11Y_"];

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Source {
    File(PathBuf),
    /// The destination this crok was built with.
    BuiltIn,
    Environment,
}

#[derive(Debug, Clone)]
pub struct Settings {
    pub source: Source,
    /// The variables the bridge gets, after defaults are filled in.
    pub vars: BTreeMap<String, String>,
    /// Set when the settings file can be read by other users.
    pub loose_permissions: bool,
}

impl Settings {
    /// Loads from `home`'s settings file, else from `builtin` (the built-in settings' text), else
    /// from `env`. `None` means nothing is sent: no endpoint, or `AGENTO11Y_ENABLED=false`.
    pub fn load(
        home: &Path,
        builtin: Option<&str>,
        env: impl IntoIterator<Item = (String, String)>,
    ) -> Option<Self> {
        let path = home.join(ENV_FILE_NAME);
        let (source, vars, loose_permissions) = match (std::fs::read_to_string(&path), builtin) {
            (Ok(text), _) => (
                Source::File(path.clone()),
                bridge_vars(parse_env_file(&text)),
                is_readable_by_others(&path),
            ),
            (Err(_), Some(text)) => (Source::BuiltIn, bridge_vars(parse_env_file(text)), false),
            (Err(_), None) => (Source::Environment, bridge_vars(env), false),
        };
        let mut settings = Self {
            source,
            vars,
            loose_permissions,
        };
        if !settings.is_enabled() {
            return None;
        }
        settings.fill_cloud_defaults();
        Some(settings)
    }

    /// Whether the inherited `AGENTO11Y_*` / `OTEL_*` variables are dropped from the bridge's environment.
    pub fn replaces_inherited(&self) -> bool {
        !matches!(self.source, Source::Environment)
    }

    /// The same configuration from the same place, whatever else changed in the file.
    pub fn is_same(&self, other: &Self) -> bool {
        self.source == other.source && self.vars == other.vars
    }

    pub fn get(&self, key: &str) -> Option<&str> {
        self.vars
            .get(key)
            .map(String::as_str)
            .filter(|v| !v.is_empty())
    }

    fn is_enabled(&self) -> bool {
        let switched_off = self.get("AGENTO11Y_ENABLED").is_some_and(|v| {
            matches!(
                v.to_ascii_lowercase().as_str(),
                "0" | "false" | "no" | "off"
            )
        });
        !switched_off && self.get("AGENTO11Y_ENDPOINT").is_some()
    }

    /// Grafana Cloud needs HTTP transport and basic auth, and the SDK's defaults (no auth)
    /// fail with a 401 that nothing reports. Fill both in when the credentials are there.
    fn fill_cloud_defaults(&mut self) {
        if self.get("AGENTO11Y_PROTOCOL").is_none() {
            self.vars
                .insert("AGENTO11Y_PROTOCOL".to_owned(), "http".to_owned());
        }
        if self.get("AGENTO11Y_AUTH_MODE").is_none()
            && self.get("AGENTO11Y_AUTH_TENANT_ID").is_some()
            && self.get("AGENTO11Y_AUTH_TOKEN").is_some()
        {
            self.vars
                .insert("AGENTO11Y_AUTH_MODE".to_owned(), "basic".to_owned());
        }
    }

    /// What is configured, for the log; never a credential.
    pub fn describe(&self) -> String {
        let source = match &self.source {
            Source::File(path) => path.display().to_string(),
            Source::BuiltIn => "the destination built into crok".to_owned(),
            Source::Environment => "the environment".to_owned(),
        };
        let otlp = self
            .get("OTEL_EXPORTER_OTLP_ENDPOINT")
            .unwrap_or("(not set: no traces or metrics)");
        let headers = if self.get("OTEL_EXPORTER_OTLP_HEADERS").is_some() {
            "set"
        } else {
            "not set"
        };
        format!(
            "settings from {source}; generations to {}, auth {}; otlp to {otlp}, headers {headers}",
            self.get("AGENTO11Y_ENDPOINT").unwrap_or_default(),
            self.get("AGENTO11Y_AUTH_MODE").unwrap_or("none"),
        )
    }
}

fn bridge_vars(vars: impl IntoIterator<Item = (String, String)>) -> BTreeMap<String, String> {
    vars.into_iter()
        .filter(|(key, _)| BRIDGE_PREFIXES.iter().any(|prefix| key.starts_with(prefix)))
        .collect()
}

/// Whether `name` is one of the variables a settings file replaces in the bridge's environment.
pub fn is_bridge_var(name: &str) -> bool {
    BRIDGE_PREFIXES
        .iter()
        .any(|prefix| name.starts_with(prefix))
}

/// Parses the dotenv subset: `KEY=value` lines, `#` comments, optional `export`, and single
/// or double quotes (double quotes take `\"`, `\\` and `\n`).
pub fn parse_env_file(text: &str) -> Vec<(String, String)> {
    text.lines()
        .filter_map(|line| {
            let line = line.trim();
            if line.is_empty() || line.starts_with('#') {
                return None;
            }
            let line = line.strip_prefix("export ").unwrap_or(line);
            let (key, value) = line.split_once('=')?;
            let key = key.trim();
            if key.is_empty() || !key.chars().all(|c| c.is_ascii_alphanumeric() || c == '_') {
                return None;
            }
            Some((key.to_owned(), unquote(value.trim())))
        })
        .collect()
}

fn unquote(value: &str) -> String {
    if let Some(inner) = value
        .strip_prefix('\'')
        .and_then(|rest| rest.strip_suffix('\''))
    {
        return inner.to_owned();
    }
    if let Some(inner) = value
        .strip_prefix('"')
        .and_then(|rest| rest.strip_suffix('"'))
    {
        let mut out = String::with_capacity(inner.len());
        let mut chars = inner.chars();
        while let Some(c) = chars.next() {
            if c != '\\' {
                out.push(c);
                continue;
            }
            match chars.next() {
                Some('n') => out.push('\n'),
                Some(other) => out.push(other),
                None => out.push('\\'),
            }
        }
        return out;
    }
    // An unquoted value ends at a ` #` comment.
    value
        .split_once(" #")
        .map_or(value, |(head, _)| head)
        .trim_end()
        .to_owned()
}

#[cfg(unix)]
fn is_readable_by_others(path: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    std::fs::metadata(path).is_ok_and(|m| m.permissions().mode() & 0o077 != 0)
}

#[cfg(not(unix))]
fn is_readable_by_others(_path: &Path) -> bool {
    false
}

#[cfg(test)]
mod tests {
    use super::*;

    fn env(pairs: &[(&str, &str)]) -> Vec<(String, String)> {
        pairs
            .iter()
            .map(|(k, v)| ((*k).to_owned(), (*v).to_owned()))
            .collect()
    }

    #[test]
    fn parses_quotes_comments_and_export() {
        let text = "# Grafana\nexport AGENTO11Y_ENDPOINT=https://example.test\n\
                    OTEL_EXPORTER_OTLP_HEADERS='Authorization=Basic YWJjOmRlZg=='\n\
                    AGENTO11Y_TAGS=\"team=me,env=dev\"\nAGENTO11Y_DEBUG=1 # chatty\n\
                    not a line\n=nokey\n";
        let vars = parse_env_file(text);
        assert_eq!(
            vars,
            env(&[
                ("AGENTO11Y_ENDPOINT", "https://example.test"),
                (
                    "OTEL_EXPORTER_OTLP_HEADERS",
                    "Authorization=Basic YWJjOmRlZg=="
                ),
                ("AGENTO11Y_TAGS", "team=me,env=dev"),
                ("AGENTO11Y_DEBUG", "1"),
            ])
        );
    }

    #[test]
    fn the_file_replaces_the_environment_and_fills_cloud_defaults() {
        let home = tempfile::tempdir().unwrap();
        std::fs::write(
            home.path().join(ENV_FILE_NAME),
            "AGENTO11Y_ENDPOINT=https://agento11y.example\nAGENTO11Y_AUTH_TENANT_ID=42\n\
             AGENTO11Y_AUTH_TOKEN=glc_x\nOTEL_EXPORTER_OTLP_ENDPOINT=https://otlp.example/otlp\n\
             UNRELATED=1\n",
        )
        .unwrap();
        let inherited = env(&[
            ("OTEL_EXPORTER_OTLP_ENDPOINT", "http://localhost:4318"),
            ("AGENTO11Y_ENDPOINT", "http://localhost:8080"),
        ]);
        let settings = Settings::load(
            home.path(),
            Some("AGENTO11Y_ENDPOINT=https://builtin.example"),
            inherited,
        )
        .unwrap();
        assert_eq!(
            settings.get("AGENTO11Y_ENDPOINT"),
            Some("https://agento11y.example")
        );
        assert_eq!(
            settings.get("OTEL_EXPORTER_OTLP_ENDPOINT"),
            Some("https://otlp.example/otlp")
        );
        assert_eq!(settings.get("AGENTO11Y_PROTOCOL"), Some("http"));
        assert_eq!(settings.get("AGENTO11Y_AUTH_MODE"), Some("basic"));
        assert_eq!(settings.get("UNRELATED"), None);
        assert!(!settings.describe().contains("glc_x"));
    }

    #[test]
    fn without_a_file_the_environment_decides_and_no_endpoint_means_off() {
        let home = tempfile::tempdir().unwrap();
        assert!(
            Settings::load(
                home.path(),
                None,
                env(&[("OTEL_EXPORTER_OTLP_ENDPOINT", "x")])
            )
            .is_none()
        );
        let on = Settings::load(
            home.path(),
            None,
            env(&[("AGENTO11Y_ENDPOINT", "https://a.example")]),
        );
        assert_eq!(on.unwrap().source, Source::Environment);
        let off = Settings::load(
            home.path(),
            None,
            env(&[
                ("AGENTO11Y_ENDPOINT", "https://a.example"),
                ("AGENTO11Y_ENABLED", "false"),
            ]),
        );
        assert!(off.is_none());
    }

    #[test]
    fn the_built_in_destination_ranks_between_the_file_and_the_environment() {
        let home = tempfile::tempdir().unwrap();
        let builtin = "AGENTO11Y_ENDPOINT=https://builtin.example\nAGENTO11Y_AUTH_TENANT_ID=7\n\
                       AGENTO11Y_AUTH_TOKEN=glc_builtin\nOTEL_EXPORTER_OTLP_ENDPOINT=https://otlp.builtin/otlp";
        let inherited = env(&[
            ("AGENTO11Y_ENDPOINT", "http://localhost:8080"),
            ("OTEL_EXPORTER_OTLP_HEADERS", "x-other=1"),
        ]);
        let settings = Settings::load(home.path(), Some(builtin), inherited.clone()).unwrap();
        assert_eq!(settings.source, Source::BuiltIn);
        assert!(settings.replaces_inherited());
        assert_eq!(
            settings.get("AGENTO11Y_ENDPOINT"),
            Some("https://builtin.example")
        );
        assert_eq!(settings.get("OTEL_EXPORTER_OTLP_HEADERS"), None);
        assert_eq!(settings.get("AGENTO11Y_AUTH_MODE"), Some("basic"));
        assert!(!settings.describe().contains("glc_builtin"));

        std::fs::write(
            home.path().join(ENV_FILE_NAME),
            "AGENTO11Y_ENDPOINT=https://mine.example\n",
        )
        .unwrap();
        let mine = Settings::load(home.path(), Some(builtin), inherited.clone()).unwrap();
        assert_eq!(mine.get("AGENTO11Y_ENDPOINT"), Some("https://mine.example"));
        std::fs::write(
            home.path().join(ENV_FILE_NAME),
            "AGENTO11Y_ENDPOINT=https://mine.example\nAGENTO11Y_ENABLED=false\n",
        )
        .unwrap();
        assert!(
            Settings::load(home.path(), Some(builtin), inherited).is_none(),
            "the file turns the built-in destination off on this machine"
        );
    }

    #[cfg(unix)]
    #[test]
    fn a_world_readable_file_is_flagged() {
        use std::os::unix::fs::PermissionsExt;
        let home = tempfile::tempdir().unwrap();
        let path = home.path().join(ENV_FILE_NAME);
        std::fs::write(&path, "AGENTO11Y_ENDPOINT=https://a.example\n").unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o644)).unwrap();
        assert!(
            Settings::load(home.path(), None, Vec::new())
                .unwrap()
                .loose_permissions
        );
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
        assert!(
            !Settings::load(home.path(), None, Vec::new())
                .unwrap()
                .loose_permissions
        );
    }
}
