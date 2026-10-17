//! Grafana Agent Observability for crok: every model call, from the terminal and from Crok Desktop.
//!
//! The sampler reports each model API request ([`xai_grok_sampler::observe`]); this crate hands
//! the reports to a small Node process running the agento11y TypeScript SDK (`bridge/`), which
//! exports each one as a generation to Agent Observability and its spans and `gen_ai.client.*`
//! metrics over OTLP. Both crok surfaces go through the same sampler: the TUI runs the agent in
//! its own process, and Crok Desktop runs `crok agent stdio` per conversation.
//!
//! Off until switched on: `[features] agent_observability` (Settings in the terminal and in Crok
//! Desktop, or `CROK_AGENT_OBSERVABILITY`). The destination is the `AGENTO11Y_*` and
//! `OTEL_EXPORTER_OTLP_*` values in `~/.crok/agento11y.env` (mode 0600), or exported before starting
//! crok. Both files are followed while crok runs ([`switch`]), so the switch and a new destination
//! apply to running sessions. The bridge needs Node 20 or newer (or Bun); `CROK_AGENTO11Y_NODE`
//! names one explicitly. It logs to `~/.crok/logs/agento11y.log`.

#![deny(clippy::indexing_slicing)]

mod bridge;
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

/// Installs the sink that records while the switch is on and a destination is set. Returns what
/// applies now, for the caller's log; `None` when crok has no home to read the settings from.
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

/// Where reports go with the settings as they are now, for a settings screen: the Agent
/// Observability endpoint's host. `None` when no destination is set up.
pub fn destination_host() -> Option<String> {
    let home = xai_dirs::user_grok_home()?;
    let settings = Settings::load(&home, inherited_vars())?;
    settings.get("AGENTO11Y_ENDPOINT").map(endpoint_host)
}

/// The destination's settings file, `~/.crok/agento11y.env`.
pub fn settings_file() -> Option<PathBuf> {
    Some(xai_dirs::user_grok_home()?.join(settings::ENV_FILE_NAME))
}

/// The process's sink.
struct Reporter {
    switch: Switch,
    /// The settings in `agento11y.env`, else from `inherited`; `None` while nothing is configured.
    destination: Followed<Option<Arc<Settings>>>,
    /// The `AGENTO11Y_*` / `OTEL_*` variables crok started with.
    inherited: Vec<(String, String)>,
    home: PathBuf,
    log_path: PathBuf,
    writer: bridge::Writer,
}

impl Reporter {
    fn destination(&self) -> Option<Arc<Settings>> {
        self.destination.get(|path| {
            let settings = Settings::load(&self.home, self.inherited.iter().cloned())?;
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

/// `https://user:pass@host:443/path` → `host:443`: what a settings screen shows, never a credential.
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

    #[test]
    fn records_only_while_switched_on_and_a_destination_is_set() {
        let home = tempfile::tempdir().unwrap();
        let config = home.path().join("config.toml");
        let env_file = home.path().join(settings::ENV_FILE_NAME);
        let log_path = home.path().join("logs").join("agento11y.log");
        let reporter = Reporter {
            switch: Switch::following_user_file(config.clone(), None),
            destination: Followed::new(env_file.clone()),
            inherited: Vec::new(),
            home: home.path().to_owned(),
            log_path: log_path.clone(),
            writer: bridge::start(bridge::Base {
                home: home.path().to_owned(),
                log_path,
                agent_version: "test".to_owned(),
            })
            .unwrap(),
        };
        assert!(!reporter.is_active(), "off by default");
        write(&config, "[features]\nagent_observability = true\n");
        assert!(!reporter.is_active(), "on, but no destination yet");
        assert!(reporter.describe().contains("no destination"));
        write(&env_file, "AGENTO11Y_ENDPOINT=https://agento11y.example\n");
        assert!(
            reporter.is_active(),
            "a destination set up later applies without a restart"
        );
        assert!(
            reporter
                .describe()
                .starts_with("agento11y switch on; settings from")
        );
        write(
            &env_file,
            "AGENTO11Y_ENDPOINT=https://agento11y.example\nAGENTO11Y_ENABLED=false\n",
        );
        assert!(
            !reporter.is_active(),
            "the file's own kill switch still counts"
        );
        write(&env_file, "AGENTO11Y_ENDPOINT=https://agento11y.example\n");
        write(&config, "[features]\nagent_observability = false\n");
        assert!(!reporter.is_active());
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
}
