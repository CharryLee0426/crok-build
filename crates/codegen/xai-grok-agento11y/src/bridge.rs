//! The bridge process and the thread that feeds it.
//!
//! The sampler hands each finished call to [`BridgeSink::record`], which only queues it. One
//! writer thread owns the bridge: it starts `node agento11y-bridge.mjs` for the first call,
//! writes one JSON line per call to its stdin, and closes that stdin after an idle spell, which
//! makes the bridge flush and exit; the next call starts a new one. When crok exits, the pipe
//! closes the same way. The bridge runs in its own session so it can finish that flush.

use std::collections::BTreeMap;
use std::fs::{File, OpenOptions};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, SyncSender, TrySendError};
use std::time::{Duration, Instant};

use xai_grok_sampler::observe::{GenerationSink, ObservedCall};

use crate::settings::is_bridge_var;

/// The bundled bridge (see `bridge/build.mjs`): the agento11y SDK and OpenTelemetry in one file.
const BRIDGE_JS: &str = include_str!("../bridge/dist/agento11y-bridge.mjs");

/// Calls queued for the writer; past this a slow bridge loses records instead of slowing a turn.
const QUEUE_CAPACITY: usize = 256;
/// The bridge log is set aside past this size, keeping one older file.
const MAX_LOG_BYTES: u64 = 5 * 1024 * 1024;
/// A bridge that dies sooner than this after starting is not restarted until [`RESTART_BACKOFF`] has passed.
const MIN_HEALTHY_LIFETIME: Duration = Duration::from_secs(10);
const RESTART_BACKOFF: Duration = Duration::from_secs(60);

/// Everything needed to start a bridge.
pub(crate) struct Launch {
    pub runtime: PathBuf,
    pub script: PathBuf,
    pub home: PathBuf,
    pub log_path: PathBuf,
    /// Variables set on the bridge, on top of crok's environment.
    pub env: BTreeMap<String, String>,
    /// The configured `AGENTO11Y_TAGS`, which the bridge gets with a `surface` tag added.
    pub user_tags: String,
    /// Drop the inherited `AGENTO11Y_*` / `OTEL_*` variables first (the settings file is the whole configuration).
    pub replace_inherited: bool,
}

pub(crate) struct BridgeSink {
    tx: SyncSender<ObservedCall>,
    dropped: AtomicU64,
}

impl GenerationSink for BridgeSink {
    fn record(&self, call: ObservedCall) {
        match self.tx.try_send(call) {
            Ok(()) | Err(TrySendError::Disconnected(_)) => {}
            Err(TrySendError::Full(call)) => {
                let dropped = self.dropped.fetch_add(1, Ordering::Relaxed) + 1;
                if dropped == 1 || dropped.is_multiple_of(100) {
                    tracing::warn!(
                        dropped,
                        generation = call.generation_id(),
                        "agento11y bridge is behind; model-call records are being dropped"
                    );
                }
            }
        }
    }
}

/// Starts the writer thread and returns the sink that feeds it.
pub(crate) fn start(launch: Launch, idle: Duration) -> io::Result<BridgeSink> {
    let (tx, rx) = mpsc::sync_channel(QUEUE_CAPACITY);
    std::thread::Builder::new()
        .name("agento11y-bridge".to_owned())
        .spawn(move || run_writer(rx, launch, idle))?;
    Ok(BridgeSink {
        tx,
        dropped: AtomicU64::new(0),
    })
}

struct Bridge {
    child: Child,
    stdin: ChildStdin,
    started: Instant,
}

fn run_writer(rx: Receiver<ObservedCall>, launch: Launch, idle: Duration) {
    let mut bridge: Option<Bridge> = None;
    let mut paused_until: Option<Instant> = None;
    loop {
        match rx.recv_timeout(idle) {
            Ok(call) => {
                let mut line = call.to_json_line();
                if line.is_empty() {
                    continue;
                }
                line.push('\n');
                deliver(&mut bridge, &mut paused_until, &launch, line.as_bytes());
            }
            Err(RecvTimeoutError::Timeout) => {
                if let Some(idle_bridge) = bridge.take() {
                    close(idle_bridge);
                }
            }
            Err(RecvTimeoutError::Disconnected) => {
                if let Some(last) = bridge.take() {
                    close(last);
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
    line: &[u8],
) {
    for _ in 0..2 {
        if bridge.is_none() {
            if paused_until.is_some_and(|until| Instant::now() < until) {
                return;
            }
            match spawn(launch) {
                Ok(started) => {
                    tracing::info!(pid = started.child.id(), "started the agento11y bridge");
                    *bridge = Some(started);
                    *paused_until = None;
                }
                Err(err) => {
                    log_line(
                        &launch.log_path,
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
                        &launch.log_path,
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

fn spawn(launch: &Launch) -> io::Result<Bridge> {
    let log = open_log(&launch.log_path)?;
    log_line(
        &launch.log_path,
        &format!(
            "crok {} starts the bridge with {}",
            std::process::id(),
            launch.runtime.display()
        ),
    );
    let mut cmd = Command::new(&launch.runtime);
    cmd.arg(&launch.script)
        .current_dir(&launch.home)
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
