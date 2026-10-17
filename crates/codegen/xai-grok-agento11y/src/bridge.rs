//! The bridge process and the thread that feeds it.
//!
//! The sampler hands each finished call to the reporter, which queues it with the settings it is
//! for ([`Writer::send`]). One writer thread owns the bridge: it starts `node agento11y-bridge.mjs`
//! for the first call, writes one JSON line per call to its stdin, and closes that stdin after an
//! idle spell, which makes the bridge flush and exit; the next call starts a new one. A call for
//! other settings (`agento11y.env` was edited) closes the bridge and starts one with the new
//! settings. When crok exits, the pipe closes the same way. The bridge runs in its own session so
//! it can finish that flush.

use std::collections::BTreeMap;
use std::fs::{File, OpenOptions};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, SyncSender, TrySendError};
use std::time::{Duration, Instant};

use xai_grok_sampler::observe::ObservedCall;

use crate::settings::{Settings, Source, is_bridge_var};

/// The bundled bridge (see `bridge/build.mjs`): the agento11y SDK and OpenTelemetry in one file.
const BRIDGE_JS: &str = include_str!("../bridge/dist/agento11y-bridge.mjs");

/// Calls queued for the writer; past this a slow bridge loses records instead of slowing a turn.
const QUEUE_CAPACITY: usize = 256;
/// The bridge log is set aside past this size, keeping one older file.
const MAX_LOG_BYTES: u64 = 5 * 1024 * 1024;
/// A bridge that dies sooner than this after starting is not restarted until [`RESTART_BACKOFF`] has passed.
const MIN_HEALTHY_LIFETIME: Duration = Duration::from_secs(10);
const RESTART_BACKOFF: Duration = Duration::from_secs(60);
/// Idle time after which the bridge is told to flush and exit; the next call starts a new one.
const DEFAULT_IDLE: Duration = Duration::from_secs(300);

/// What every bridge of this process shares, whatever the settings.
pub(crate) struct Base {
    pub home: PathBuf,
    pub log_path: PathBuf,
    /// crok's release version, sent as `AGENTO11Y_AGENT_VERSION` unless the settings name one.
    pub agent_version: String,
}

/// Everything needed to start a bridge for one set of settings.
pub(crate) struct Launch {
    pub runtime: PathBuf,
    pub script: PathBuf,
    /// Variables set on the bridge, on top of crok's environment.
    pub env: BTreeMap<String, String>,
    /// The configured `AGENTO11Y_TAGS`, which the bridge gets with a `surface` tag added.
    pub user_tags: String,
    /// Drop the inherited `AGENTO11Y_*` / `OTEL_*` variables first (the settings file is the whole configuration).
    pub replace_inherited: bool,
    pub idle: Duration,
}

impl Launch {
    /// Finds the runtime and writes the script; the error says, for the bridge log, why it cannot start.
    fn new(settings: &Settings, base: &Base) -> Result<Self, String> {
        let explicit = settings
            .get("CROK_AGENTO11Y_NODE")
            .map(str::to_owned)
            .or_else(|| std::env::var("CROK_AGENTO11Y_NODE").ok());
        let runtime = crate::node::find_runtime(
            explicit.as_deref(),
            std::env::var_os("PATH").as_deref(),
            xai_dirs::home_dir().as_deref(),
        )
        .ok_or("Agent Observability is on but no Node.js was found: install Node 20+ or set CROK_AGENTO11Y_NODE")?;
        let script = write_script(&base.home)
            .map_err(|err| format!("could not write the bridge script: {err}"))?;
        Ok(Self {
            runtime,
            script,
            env: bridge_env(settings, &base.agent_version),
            user_tags: settings
                .get("AGENTO11Y_TAGS")
                .unwrap_or_default()
                .to_owned(),
            replace_inherited: matches!(settings.source, Source::File(_)),
            idle: settings
                .get("CROK_AGENTO11Y_IDLE_SECS")
                .and_then(|secs| secs.parse().ok())
                .map_or(DEFAULT_IDLE, Duration::from_secs),
        })
    }
}

/// The bridge's variables: the settings and crok's version. `AGENTO11Y_TAGS` is added when the
/// bridge starts, with the surface known by then ([`client_tags`]).
fn bridge_env(settings: &Settings, agent_version: &str) -> BTreeMap<String, String> {
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

/// One call and the settings it is to be sent with.
struct Job {
    call: ObservedCall,
    settings: Arc<Settings>,
}

/// The queue to the writer thread.
pub(crate) struct Writer {
    tx: SyncSender<Job>,
    dropped: AtomicU64,
}

impl Writer {
    /// Queues one call; never waits.
    pub(crate) fn send(&self, call: ObservedCall, settings: Arc<Settings>) {
        match self.tx.try_send(Job { call, settings }) {
            Ok(()) | Err(TrySendError::Disconnected(_)) => {}
            Err(TrySendError::Full(job)) => {
                let dropped = self.dropped.fetch_add(1, Ordering::Relaxed) + 1;
                if dropped == 1 || dropped.is_multiple_of(100) {
                    tracing::warn!(
                        dropped,
                        generation = job.call.generation_id(),
                        "agento11y bridge is behind; model-call records are being dropped"
                    );
                }
            }
        }
    }
}

/// Starts the writer thread and returns the queue that feeds it. No bridge runs until a call comes.
pub(crate) fn start(base: Base) -> io::Result<Writer> {
    let (tx, rx) = mpsc::sync_channel(QUEUE_CAPACITY);
    std::thread::Builder::new()
        .name("agento11y-bridge".to_owned())
        .spawn(move || run_writer(rx, base))?;
    Ok(Writer {
        tx,
        dropped: AtomicU64::new(0),
    })
}

struct Bridge {
    child: Child,
    stdin: ChildStdin,
    started: Instant,
}

/// One set of settings and the bridge that sends with them.
struct Destination {
    settings: Arc<Settings>,
    /// `None` when the bridge cannot start with these settings; the reason is in the bridge log.
    launch: Option<Launch>,
    bridge: Option<Bridge>,
    paused_until: Option<Instant>,
}

impl Destination {
    fn new(settings: Arc<Settings>, base: &Base) -> Self {
        let launch = Launch::new(&settings, base)
            .inspect_err(|reason| {
                log_line(&base.log_path, reason);
                tracing::warn!("{reason}");
            })
            .ok();
        if let Some(launch) = &launch {
            tracing::info!(
                "agento11y on: {}; bridge {} with {}",
                settings.describe(),
                launch.script.display(),
                launch.runtime.display()
            );
        }
        Self {
            settings,
            launch,
            bridge: None,
            paused_until: None,
        }
    }

    fn idle(&self) -> Duration {
        self.launch
            .as_ref()
            .map_or(DEFAULT_IDLE, |launch| launch.idle)
    }

    fn close_bridge(&mut self) {
        if let Some(bridge) = self.bridge.take() {
            close(bridge);
        }
    }
}

fn run_writer(rx: Receiver<Job>, base: Base) {
    let mut current: Option<Destination> = None;
    loop {
        let idle = current.as_ref().map_or(DEFAULT_IDLE, Destination::idle);
        match rx.recv_timeout(idle) {
            Ok(Job { call, settings }) => {
                let mut line = call.to_json_line();
                if line.is_empty() {
                    continue;
                }
                line.push('\n');
                // A rewrite that changed nothing (setup.sh run again) keeps the running bridge
                let destination = match current.take() {
                    Some(same) if same.settings.is_same(&settings) => same,
                    other => {
                        if let Some(mut old) = other {
                            old.close_bridge();
                        }
                        Destination::new(settings, &base)
                    }
                };
                let destination = current.insert(destination);
                if let Some(launch) = &destination.launch {
                    deliver(
                        &mut destination.bridge,
                        &mut destination.paused_until,
                        launch,
                        &base,
                        line.as_bytes(),
                    );
                }
            }
            Err(RecvTimeoutError::Timeout) => {
                if let Some(destination) = current.as_mut() {
                    destination.close_bridge();
                }
            }
            Err(RecvTimeoutError::Disconnected) => {
                if let Some(mut last) = current.take() {
                    last.close_bridge();
                }
                return;
            }
        }
    }
}

/// Writes one line, starting the bridge first if needed and once more if the write fails.
fn deliver(
    bridge: &mut Option<Bridge>,
    paused_until: &mut Option<Instant>,
    launch: &Launch,
    base: &Base,
    line: &[u8],
) {
    for _ in 0..2 {
        if bridge.is_none() {
            if paused_until.is_some_and(|until| Instant::now() < until) {
                return;
            }
            match spawn(launch, base) {
                Ok(started) => {
                    tracing::info!(pid = started.child.id(), "started the agento11y bridge");
                    *bridge = Some(started);
                    *paused_until = None;
                }
                Err(err) => {
                    log_line(
                        &base.log_path,
                        &format!("crok could not start the bridge: {err}"),
                    );
                    tracing::warn!(%err, "could not start the agento11y bridge");
                    *paused_until = Some(Instant::now() + RESTART_BACKOFF);
                    return;
                }
            }
        }
        let Some(running) = bridge.as_mut() else {
            return;
        };
        match running
            .stdin
            .write_all(line)
            .and_then(|()| running.stdin.flush())
        {
            Ok(()) => return,
            Err(err) => {
                let lived = running.started.elapsed();
                tracing::warn!(%err, "the agento11y bridge stopped reading; restarting it");
                if let Some(dead) = bridge.take() {
                    close(dead);
                }
                if lived < MIN_HEALTHY_LIFETIME {
                    log_line(
                        &base.log_path,
                        &format!(
                            "the bridge exited {}s after it started; crok waits {}s before starting another",
                            lived.as_secs(),
                            RESTART_BACKOFF.as_secs()
                        ),
                    );
                    *paused_until = Some(Instant::now() + RESTART_BACKOFF);
                    return;
                }
            }
        }
    }
}

/// Closes the bridge's stdin, which makes it flush and exit, and reaps it off this thread.
fn close(bridge: Bridge) {
    let Bridge {
        mut child, stdin, ..
    } = bridge;
    drop(stdin);
    let _ = std::thread::Builder::new()
        .name("agento11y-bridge-reap".to_owned())
        .spawn(move || {
            let _ = child.wait();
        });
}

fn spawn(launch: &Launch, base: &Base) -> io::Result<Bridge> {
    let log = open_log(&base.log_path)?;
    log_line(
        &base.log_path,
        &format!(
            "crok {} starts the bridge with {}",
            std::process::id(),
            launch.runtime.display()
        ),
    );
    let mut cmd = Command::new(&launch.runtime);
    cmd.arg(&launch.script)
        .current_dir(&base.home)
        .stdin(Stdio::piped())
        .stdout(log.try_clone()?)
        .stderr(log);
    if launch.replace_inherited {
        for (name, _) in std::env::vars_os() {
            if name.to_str().is_some_and(is_bridge_var) {
                cmd.env_remove(&name);
            }
        }
    }
    // A user's NODE_OPTIONS (--require hooks, inspectors) has no business in the bridge.
    cmd.env_remove("NODE_OPTIONS");
    cmd.envs(&launch.env);
    let surface = xai_grok_sampler::observe::surface();
    cmd.env(
        "AGENTO11Y_TAGS",
        client_tags(&launch.user_tags, surface.as_deref()),
    );
    xai_tty_utils::detach_std_command(&mut cmd);
    // Detached on purpose: when crok exits, the bridge outlives it only to flush, and exits
    // when its stdin closes. A bridge crok closes itself is reaped in `close`.
    #[allow(clippy::disallowed_methods)]
    let mut child = cmd.spawn()?;
    let stdin = child
        .stdin
        .take()
        .ok_or_else(|| io::Error::other("bridge started without a stdin pipe"))?;
    Ok(Bridge {
        child,
        stdin,
        started: Instant::now(),
    })
}

/// The bridge's client tags: the configured ones plus `surface`, unless they set it themselves.
/// Client tags reach the spans and metrics too, so the Performance view can split TUI from desktop.
pub(crate) fn client_tags(user_tags: &str, surface: Option<&str>) -> String {
    let user_tags = user_tags.trim().trim_matches(',');
    let has_surface = user_tags
        .split(',')
        .any(|pair| pair.split('=').next().map(str::trim) == Some("surface"));
    match surface {
        Some(surface) if !has_surface && user_tags.is_empty() => format!("surface={surface}"),
        Some(surface) if !has_surface => format!("{user_tags},surface={surface}"),
        _ => user_tags.to_owned(),
    }
}

/// Writes the embedded bridge under `home/agento11y/`, named by its content hash, and removes older copies.
pub(crate) fn write_script(home: &Path) -> io::Result<PathBuf> {
    let dir = home.join("agento11y");
    std::fs::create_dir_all(&dir)?;
    let hash = blake3::hash(BRIDGE_JS.as_bytes()).to_hex();
    let name = format!("bridge-{}.mjs", hash.get(..12).unwrap_or(hash.as_str()));
    let path = dir.join(&name);
    let current = std::fs::metadata(&path).is_ok_and(|m| m.len() == BRIDGE_JS.len() as u64);
    if !current {
        let partial = dir.join(format!("{name}.{}.partial", std::process::id()));
        std::fs::write(&partial, BRIDGE_JS)?;
        std::fs::rename(&partial, &path)?;
    }
    if let Ok(entries) = std::fs::read_dir(&dir) {
        for entry in entries.flatten() {
            let file_name = entry.file_name();
            let Some(file_name) = file_name.to_str() else {
                continue;
            };
            if file_name != name && file_name.starts_with("bridge-") && file_name.ends_with(".mjs")
            {
                let _ = std::fs::remove_file(entry.path());
            }
        }
    }
    Ok(path)
}

fn open_log(path: &Path) -> io::Result<File> {
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    if std::fs::metadata(path).is_ok_and(|m| m.len() > MAX_LOG_BYTES) {
        let _ = std::fs::rename(path, path.with_extension("log.1"));
    }
    let mut options = OpenOptions::new();
    options.create(true).append(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    options.open(path)
}

/// Appends a line from crok itself to the bridge log, so the log alone explains a quiet bridge.
pub(crate) fn log_line(path: &Path, message: &str) {
    if let Ok(mut log) = open_log(path) {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default();
        let _ = writeln!(log, "{} INFO crok: {message}", utc_timestamp(now));
    }
}

/// `2026-10-16T06:08:26.269Z`, the format the bridge's own lines use.
fn utc_timestamp(since_epoch: Duration) -> String {
    let secs = since_epoch.as_secs();
    let days = i64::try_from(secs / 86_400).unwrap_or_default();
    let rem = secs % 86_400;
    // Civil date from days since 1970-01-01 (Howard Hinnant's algorithm).
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = yoe + era * 400 + i64::from(month <= 2);
    format!(
        "{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}.{:03}Z",
        rem / 3_600,
        rem % 3_600 / 60,
        rem % 60,
        since_epoch.subsec_millis()
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_script_is_written_once_and_older_copies_go() {
        let home = tempfile::tempdir().unwrap();
        let dir = home.path().join("agento11y");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("bridge-000000000000.mjs"), "old").unwrap();
        let path = write_script(home.path()).unwrap();
        assert_eq!(std::fs::read_to_string(&path).unwrap(), BRIDGE_JS);
        assert_eq!(write_script(home.path()).unwrap(), path);
        let names: Vec<_> = std::fs::read_dir(&dir)
            .unwrap()
            .map(|e| e.unwrap().file_name())
            .collect();
        assert_eq!(names, [path.file_name().unwrap().to_owned()]);
    }

    #[test]
    fn the_surface_joins_the_configured_tags_unless_they_name_one() {
        assert_eq!(client_tags("", Some("desktop")), "surface=desktop");
        assert_eq!(client_tags("team=me,", Some("tui")), "team=me,surface=tui");
        assert_eq!(client_tags("surface=laptop", Some("tui")), "surface=laptop");
        assert_eq!(client_tags("team=me", None), "team=me");
    }

    #[test]
    fn log_timestamps_match_the_bridge_format() {
        let at = |secs: u64, millis: u64| {
            utc_timestamp(Duration::from_secs(secs) + Duration::from_millis(millis))
        };
        assert_eq!(at(0, 0), "1970-01-01T00:00:00.000Z");
        assert_eq!(at(1_792_130_906, 269), "2026-10-16T06:08:26.269Z");
        assert_eq!(at(951_782_400, 5), "2000-02-29T00:00:00.005Z");
    }

    #[test]
    fn the_embedded_bridge_is_the_built_bundle() {
        assert!(BRIDGE_JS.starts_with("// Generated by build.mjs"));
        assert!(BRIDGE_JS.contains("startStreamingGeneration"));
    }
}
