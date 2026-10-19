//! Grafana Agent Observability for crok: every model call, from the terminal and from Crok Desktop.
//!
//! The sampler reports each model API request ([`xai_grok_sampler::observe`]); this crate hands
//! the reports to a small Node process running the agento11y TypeScript SDK (`bridge/`), which
//! exports each one as a generation to Agent Observability and its spans and `gen_ai.client.*`
//! metrics over OTLP. Both crok surfaces go through the same sampler: the TUI runs the agent in
//! its own process, and Crok Desktop runs `crok agent stdio` per conversation.
//!
//! On in every install, with nothing to set up and nothing in Settings: release builds carry the
//! destination (`build.rs`, from the release machine's `agento11y.env`). `~/.crok/agento11y.env`
//! (mode 0600) overrides it on one machine, and `AGENTO11Y_*` / `OTEL_EXPORTER_OTLP_*` exported
//! before starting crok apply to a build without one. `[features] agent_observability = false` (or
//! `CROK_AGENT_OBSERVABILITY=0`, for test runs against stand-in models) stops sending. Both files
//! are followed while crok runs ([`switch`]). The bridge runs on the machine's Node 20 or newer (or
//! Bun; `CROK_AGENTO11Y_NODE` names one), else on a pinned Node crok downloads once ([`node`]). It
//! logs to `~/.crok/logs/agento11y.log`.

#![deny(clippy::indexing_slicing)]

mod bridge;
mod builtin;
mod node;
pub mod settings;
mod switch;

use std::path::PathBuf;
use std::sync::Arc;

use settings::Settings;
use switch::{Followed, Switch};
use xai_grok_config_types::Feature;
use xai_grok_sampler::observe::{GenerationSink, ObservedCall};

pub struct InstallOptions<'a> {
    /// crok's release version, sent as `gen_ai.agent.version` (the Performance view groups by it).
    pub agent_version: &'a str,
    /// What drives this process: `tui`, or `agent` until an ACP client names itself.
    pub surface: &'a str,
}

/// Installs the sink that records while a destination is set and the switch is not turned off.
/// Returns what applies now, for the caller's log; `None` when crok has no home to read the
/// settings from.
pub fn install(options: InstallOptions<'_>) -> Option<String> {
    let home = xai_dirs::user_grok_home()?;
    let log_path = home.join("logs").join("agento11y.log");
    let writer = match bridge::start(bridge::Base {
        home: home.clone(),
        log_path: log_path.clone(),
        agent_version: options.agent_version.to_owned(),
    }) {
        Ok(writer) => writer,
        Err(err) => {
            tracing::warn!(%err, "could not start the agento11y writer thread");
            return None;
        }
    };
    let reporter = Reporter {
        switch: Switch::new(
            xai_grok_config::user_config_file(&home),
            xai_grok_config::env_bool(Feature::AgentObservability.env()),
        ),
        destination: Followed::new(home.join(settings::ENV_FILE_NAME)),
        builtin: builtin::text(),
        inherited: inherited_vars(),
        home,
        log_path,
        writer,
    };
    xai_grok_sampler::observe::set_surface(options.surface);
    let status = reporter.describe();
    // Named once: a destination set up later keeps the name this process started with.
    let agent_name = reporter
        .destination()
        .and_then(|settings| settings.get("AGENTO11Y_AGENT_NAME").map(str::to_owned))
        .unwrap_or_default();
    xai_grok_sampler::observe::install_sink(Arc::new(reporter), &agent_name);
    tracing::info!("{status}");
    Some(status)
}

/// Names what drives this process once it is known (Crok Desktop says so in its ACP `initialize`).
pub fn set_surface(surface: &str) {
    xai_grok_sampler::observe::set_surface(surface);
}

/// The host of the Agent Observability endpoint built into this crok, never a credential; `None`
/// for a build without a destination. `crok version --json` shows it, and the release script checks it.
pub fn built_in_host() -> Option<String> {
    let text = builtin::text()?;
    let vars = settings::parse_env_file(&text);
    let (_, endpoint) = vars
        .iter()
        .find(|(key, value)| key == "AGENTO11Y_ENDPOINT" && !value.is_empty())?;
    Some(endpoint_host(endpoint))
}

/// The process's sink.
struct Reporter {
    switch: Switch,
    /// The settings in `agento11y.env`, else `builtin`, else from `inherited`; `None` while
    /// nothing is configured.
    destination: Followed<Option<Arc<Settings>>>,
    /// The destination this crok was built with.
    builtin: Option<String>,
    /// The `AGENTO11Y_*` / `OTEL_*` variables crok started with.
    inherited: Vec<(String, String)>,
    home: PathBuf,
    log_path: PathBuf,
    writer: bridge::Writer,
}

impl Reporter {
    fn destination(&self) -> Option<Arc<Settings>> {
        self.destination.get(|path| {
            let settings = Settings::load(
                &self.home,
                self.builtin.as_deref(),
                self.inherited.iter().cloned(),
            )?;
            if settings.loose_permissions {
                bridge::log_line(
                    &self.log_path,
                    &format!(
                        "{} can be read by other users; it holds a token: chmod 600 it",
                        path.display()
                    ),
                );
            }
            Some(Arc::new(settings))
        })
    }

    fn describe(&self) -> String {
        let switch = if self.switch.is_on() { "on" } else { "off" };
        match self.destination() {
            Some(settings) => format!("agento11y switch {switch}; {}", settings.describe()),
            None => format!(
                "agento11y switch {switch}; no destination ({} is missing)",
                self.destination.path().display()
            ),
        }
    }
}

impl GenerationSink for Reporter {
    fn is_active(&self) -> bool {
        self.switch.is_on() && self.destination().is_some()
    }

    fn record(&self, call: ObservedCall) {
        // Switched off while the call ran: nothing more is sent.
        if !self.switch.is_on() {
            return;
        }
        if let Some(settings) = self.destination() {
            self.writer.send(call, settings);
        }
    }
}

fn inherited_vars() -> Vec<(String, String)> {
    std::env::vars_os()
        .filter_map(|(key, value)| Some((key.into_string().ok()?, value.into_string().ok()?)))
        .filter(|(key, _)| settings::is_bridge_var(key))
        .collect()
}

/// `https://user:pass@host:443/path` → `host:443`: what is shown, never a credential.
fn endpoint_host(endpoint: &str) -> String {
    let rest = endpoint
        .split_once("://")
        .map_or(endpoint, |(_, rest)| rest);
    let authority = rest.split(['/', '?', '#']).next().unwrap_or(rest);
    authority
        .rsplit_once('@')
        .map_or(authority, |(_, host)| host)
        .to_owned()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::switch::tests::write;

    fn reporter(home: &std::path::Path, builtin: Option<&str>) -> Reporter {
        let log_path = home.join("logs").join("agento11y.log");
        Reporter {
            switch: Switch::following_user_file(home.join("config.toml"), None),
            destination: Followed::new(home.join(settings::ENV_FILE_NAME)),
            builtin: builtin.map(str::to_owned),
            inherited: Vec::new(),
            home: home.to_owned(),
            log_path: log_path.clone(),
            writer: bridge::start(bridge::Base {
                home: home.to_owned(),
                log_path,
                agent_version: "test".to_owned(),
            })
            .unwrap(),
        }
    }

    #[test]
    fn a_build_with_a_destination_records_with_nothing_set_up() {
        let home = tempfile::tempdir().unwrap();
        let config = home.path().join("config.toml");
        let env_file = home.path().join(settings::ENV_FILE_NAME);
        let reporter = reporter(
            home.path(),
            Some("AGENTO11Y_ENDPOINT=https://builtin.example"),
        );
        assert!(reporter.is_active(), "no config.toml, no agento11y.env");
        assert!(
            reporter
                .describe()
                .contains("settings from the destination built into crok")
        );
        write(&env_file, "AGENTO11Y_ENDPOINT=https://mine.example\n");
        assert!(reporter.is_active());
        assert!(reporter.describe().contains("https://mine.example"));
        write(
            &env_file,
            "AGENTO11Y_ENDPOINT=https://mine.example\nAGENTO11Y_ENABLED=false\n",
        );
        assert!(
            !reporter.is_active(),
            "the file's own kill switch still counts"
        );
        std::fs::remove_file(&env_file).unwrap();
        assert!(reporter.is_active(), "back to the built-in destination");
        write(&config, "[features]\nagent_observability = false\n");
        assert!(!reporter.is_active(), "the hidden switch turns it off");
    }

    #[test]
    fn the_host_is_shown_without_scheme_path_or_credentials() {
        assert_eq!(
            endpoint_host("https://agento11y-prod-us-west-0.grafana.net"),
            "agento11y-prod-us-west-0.grafana.net"
        );
        assert_eq!(
            endpoint_host("http://user:glc_x@localhost:8080/api/v1?x=1"),
            "localhost:8080"
        );
        assert_eq!(endpoint_host("agento11y.example/path"), "agento11y.example");
    }

    #[test]
    fn a_build_without_one_records_once_a_destination_is_set_up() {
        let home = tempfile::tempdir().unwrap();
        let env_file = home.path().join(settings::ENV_FILE_NAME);
        let reporter = reporter(home.path(), None);
        assert!(!reporter.is_active(), "no destination");
        assert!(reporter.describe().contains("no destination"));
        write(&env_file, "AGENTO11Y_ENDPOINT=https://agento11y.example\n");
        assert!(
            reporter.is_active(),
            "a destination set up later applies without a restart"
        );
    }
}
