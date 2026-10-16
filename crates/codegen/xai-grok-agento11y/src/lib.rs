//! Grafana Agent Observability for crok: every model call, from the terminal and from Crok Desktop.
//!
//! The sampler reports each model API request ([`xai_grok_sampler::observe`]); this crate hands
//! the reports to a small Node process running the agento11y TypeScript SDK (`bridge/`), which
//! exports each one as a generation to Agent Observability and its spans and `gen_ai.client.*`
//! metrics over OTLP. Both crok surfaces go through the same sampler: the TUI runs the agent in
//! its own process, and Crok Desktop runs `crok agent stdio` per conversation.
//!
//! Off unless configured: put the `AGENTO11Y_*` and `OTEL_EXPORTER_OTLP_*` values in
//! `~/.crok/agento11y.env` (mode 0600), or export them before starting crok. The bridge needs
//! Node 20 or newer (or Bun); `CROK_AGENTO11Y_NODE` names one explicitly. It logs to
//! `~/.crok/logs/agento11y.log`.

#![deny(clippy::indexing_slicing)]

mod bridge;
mod node;
pub mod settings;

use std::sync::Arc;
use std::time::Duration;

use settings::{Settings, Source};

/// Idle time after which the bridge is told to flush and exit; the next call starts a new one.
const DEFAULT_IDLE: Duration = Duration::from_secs(300);

pub struct InstallOptions<'a> {
    /// crok's release version, sent as `gen_ai.agent.version` (the Performance view groups by it).
    pub agent_version: &'a str,
    /// What drives this process: `tui`, or `agent` until an ACP client names itself.
    pub surface: &'a str,
}

/// Turns recording on when it is configured. Returns what was set up, for the caller's log;
/// `None` when it is off or cannot run (the reason is in the bridge log).
pub fn install(options: InstallOptions<'_>) -> Option<String> {
    let home = xai_dirs::user_grok_home()?;
    let environment = std::env::vars_os()
        .filter_map(|(key, value)| Some((key.into_string().ok()?, value.into_string().ok()?)));
    let settings = Settings::load(&home, environment)?;
    let log_path = home.join("logs").join("agento11y.log");
    if settings.loose_permissions {
        bridge::log_line(
            &log_path,
            &format!(
                "{} can be read by other users; it holds a token: chmod 600 it",
                home.join(settings::ENV_FILE_NAME).display()
            ),
        );
    }
    let explicit = settings
        .get("CROK_AGENTO11Y_NODE")
        .map(str::to_owned)
        .or_else(|| std::env::var("CROK_AGENTO11Y_NODE").ok());
    let Some(runtime) = node::find_runtime(
        explicit.as_deref(),
        std::env::var_os("PATH").as_deref(),
        xai_dirs::home_dir().as_deref(),
    ) else {
        bridge::log_line(
            &log_path,
            "Agent Observability is configured but no Node.js was found: install Node 20+ or set CROK_AGENTO11Y_NODE",
        );
        return None;
    };
    let script = match bridge::write_script(&home) {
        Ok(script) => script,
        Err(err) => {
            bridge::log_line(
                &log_path,
                &format!("could not write the bridge script: {err}"),
            );
            return None;
        }
    };
    xai_grok_sampler::observe::set_surface(options.surface);
    let status = format!(
        "agento11y on: {}; bridge {} with {}",
        settings.describe(),
        script.display(),
        runtime.display()
    );
    let idle = settings
        .get("CROK_AGENTO11Y_IDLE_SECS")
        .and_then(|secs| secs.parse().ok())
        .map_or(DEFAULT_IDLE, Duration::from_secs);
    let agent_name = settings
        .get("AGENTO11Y_AGENT_NAME")
        .unwrap_or("crok")
        .to_owned();
    let launch = bridge::Launch {
        env: bridge_env(&settings, options.agent_version),
        user_tags: settings
            .get("AGENTO11Y_TAGS")
            .unwrap_or_default()
            .to_owned(),
        replace_inherited: matches!(settings.source, Source::File(_)),
        runtime,
        script,
        home,
        log_path,
    };
    let sink = match bridge::start(launch, idle) {
        Ok(sink) => sink,
        Err(err) => {
            tracing::warn!(%err, "could not start the agento11y writer thread");
            return None;
        }
    };
    xai_grok_sampler::observe::install_sink(Arc::new(sink), &agent_name);
    tracing::info!("{status}");
    Some(status)
}

/// Names what drives this process once it is known (Crok Desktop says so in its ACP `initialize`).
pub fn set_surface(surface: &str) {
    xai_grok_sampler::observe::set_surface(surface);
}

/// The bridge's variables: the settings and crok's version. `AGENTO11Y_TAGS` is added when the
/// bridge starts, with the surface known by then ([`bridge::client_tags`]).
fn bridge_env(
    settings: &Settings,
    agent_version: &str,
) -> std::collections::BTreeMap<String, String> {
    let mut env = settings.vars.clone();
    env.remove("AGENTO11Y_TAGS");
    if settings.get("AGENTO11Y_AGENT_VERSION").is_none() && !agent_version.is_empty() {
        env.insert(
            "AGENTO11Y_AGENT_VERSION".to_owned(),
            agent_version.to_owned(),
        );
    }
    env
}
