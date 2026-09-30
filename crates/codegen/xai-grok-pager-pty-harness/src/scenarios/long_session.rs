//! Resume a long recorded session, scroll through its history, then stream a long response on top of it.
//!
//! Input: `PTY_BENCH_LONG_SESSION_TRACE=<path>`, a trace export of a real session (the `.html` viewer or its `trace-data` JSON).
//! [`launch`] seeds that session into the sandbox crok home (see [`crate::trace_session`]) and spawns the pager with `--resume <id>`.
//!
//! Phases, each reported as its own [`BenchResults`]:
//! - `long_session.resume`: spawn until the last recorded agent message is on screen (`extra.resume_ms`), plus idle CPU once settled.
//! - `long_session.scroll`: a mouse-wheel-up burst, a PageUp sweep, then a PageDown sweep back (`extra.*_input_latency_*`: inject → next frame end).
//! - `long_session.stream`: a paced markdown response streamed below the history (`extra.frame_interval_*`, `extra.cpu_pct`).
//!
//! Frame `p50/p95/p99/max` are the harness's BSU→ESU frame write times; the latency and interval extras capture render cost that happens before a frame starts writing.
//!
//! Optional knobs:
//! - `PTY_BENCH_LONG_SESSION_SENTINEL`: screen text that marks the resumed history as painted (default: derived from the last agent message).
//! - `PTY_BENCH_LONG_SESSION_ALL_FILES=1`: seed every recorded session file, not just the resume set.
//! - `PTY_BENCH_SAMPLE_OUT=<file>` (macOS): run `sample <pager pid> 5` during the stream phase and write the call tree there.
//! - `PTY_BENCH_LONG_SESSION_SCREENS=<dir>`: dump the visible screen at each phase boundary (checks the history actually painted).

use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};

use super::{BenchResults, ContentController, PtyHarness, ScenarioLaunch};
use crate::keys;
use crate::results::percentile;
use crate::trace_session::{MaterializeOptions, TraceSession};

pub const TRACE_ENV: &str = "PTY_BENCH_LONG_SESSION_TRACE";
pub const SENTINEL_ENV: &str = "PTY_BENCH_LONG_SESSION_SENTINEL";
pub const ALL_FILES_ENV: &str = "PTY_BENCH_LONG_SESSION_ALL_FILES";
pub const SAMPLE_ENV: &str = "PTY_BENCH_SAMPLE_OUT";
pub const SCREENS_ENV: &str = "PTY_BENCH_LONG_SESSION_SCREENS";

const STATE_FILE: &str = "long_session.json";
const RESUME_TIMEOUT: Duration = Duration::from_secs(180);
/// Settled = no frame for this long after the history tail appears.
const QUIET_WINDOW: Duration = Duration::from_millis(750);
const SETTLE_CAP: Duration = Duration::from_secs(15);
const IDLE_WINDOW: Duration = Duration::from_secs(2);

/// 0-based cell inside the transcript area (rows above the composer) for wheel reports.
const WHEEL_ROW: u16 = 10;
const WHEEL_COL: u16 = 40;
const SGR_WHEEL_UP: u16 = 64;
const WHEEL_EVENTS: usize = 120;
const WHEEL_INTERVAL: Duration = Duration::from_millis(16);
const PAGE_KEYS: usize = 40;
const PAGE_INTERVAL: Duration = Duration::from_millis(50);
/// Longest wait for the frame an input should produce; inputs that produce none (clamped, coalesced) count as `*_no_frame`.
const FRAME_WAIT: Duration = Duration::from_millis(300);

const STREAM_SENTINEL: &str = "long-session-stream";
const STREAM_SECTIONS: usize = 40;
const STREAM_CHUNK_DELAY: Duration = Duration::from_millis(3);
const STREAM_WINDOW: Duration = Duration::from_secs(6);
const SAMPLE_SECS: u32 = 5;

/// Handed from [`launch`] (before spawn) to [`run_phases`] (after spawn) through the sandbox root.
#[derive(Serialize, Deserialize)]
struct LaunchState {
    session_id: String,
    sentinel: String,
    updates_lines: usize,
    updates_bytes: u64,
}

/// Seed the recorded session and return `--resume <id>` spawn args in the sandbox workspace.
pub fn launch(content: &ContentController) -> Result<ScenarioLaunch> {
    let trace_path = std::env::var_os(TRACE_ENV)
        .map(PathBuf::from)
        .with_context(|| format!("long_session needs {TRACE_ENV}=<trace export .html or .json>"))?;
    let trace = TraceSession::load(&trace_path)?;
    // getcwd() reports the resolved path (/private/var/... on macOS); key the session dir the same way.
    let cwd = dunce::canonicalize(content.sandbox().workspace())
        .context("canonicalize sandbox workspace")?;
    let options = MaterializeOptions {
        all_files: std::env::var(ALL_FILES_ENV).is_ok_and(|v| v == "1"),
    };
    let seeded = trace.materialize(content.sandbox().grok_home(), &cwd, options)?;

    let sentinel = match std::env::var(SENTINEL_ENV) {
        Ok(s) if !s.is_empty() => s,
        _ => trace
            .last_agent_message()
            .as_deref()
            .and_then(sentinel_from_message)
            .with_context(|| {
                format!("no usable sentinel in the last agent message; set {SENTINEL_ENV}")
            })?,
    };
    let state = LaunchState {
        session_id: seeded.session_id.clone(),
        sentinel,
        updates_lines: seeded.updates_lines,
        updates_bytes: seeded.updates_bytes,
    };
    eprintln!(
        "long_session: seeded {} into {} (files {:?}, updates.jsonl {} lines / {} bytes), sentinel {:?}",
        state.session_id,
        seeded.session_dir.display(),
        seeded.files_written,
        state.updates_lines,
        state.updates_bytes,
        state.sentinel,
    );
    std::fs::write(
        content.sandbox().root().join(STATE_FILE),
        serde_json::to_vec(&state)?,
    )
    .context("write long_session launch state")?;

    Ok(ScenarioLaunch {
        args: vec!["--resume".to_owned(), seeded.session_id],
        cwd: Some(cwd),
    })
}

pub async fn run_phases(
    harness: &mut PtyHarness,
    content: &ContentController,
) -> Result<Vec<BenchResults>> {
    let state: LaunchState = serde_json::from_slice(
        &std::fs::read(content.sandbox().root().join(STATE_FILE))
            .context("long_session launch state missing; was Scenario::launch called?")?,
    )?;
    let pid = harness.child_pid().context("pager pid")?;

    // ── Phase 1: resume ──────────────────────────────────────────────
    let mut first_frame = None;
    harness.wait_until("resumed history tail", RESUME_TIMEOUT, |h| {
        if first_frame.is_none() && h.frame_count() > 0 {
            first_frame = Some(h.elapsed_since_spawn());
        }
        h.contains_text(&state.sentinel)
    })?;
    let resume = harness.elapsed_since_spawn();
    let resume_frames = harness.frame_count();
    let settle = settle(harness);
    dump_screen(harness, "1-resumed");
    let mut resume_result = harness.bench_results("long_session.resume", resume);

    harness.reset_timing();
    let cpu = CpuMeter::start(pid);
    harness.update(IDLE_WINDOW);
    let (idle_cpu_pct, _) = cpu.finish();
    resume_result = resume_result
        .with_extra("resume_ms", ms(resume))
        .with_extra("first_frame_ms", first_frame.map_or(-1.0, ms))
        .with_extra("frames_until_resumed", resume_frames as f64)
        .with_extra("settle_after_resume_ms", ms(settle))
        .with_extra("idle_cpu_pct", idle_cpu_pct)
        .with_extra("idle_frames", harness.frame_count() as f64)
        .with_extra("updates_lines", state.updates_lines as f64)
        .with_extra("updates_bytes", state.updates_bytes as f64);

    // ── Phase 2: scroll the history ──────────────────────────────────
    harness.reset_timing();
    let screen_before = harness.screen_contents();
    let cpu = CpuMeter::start(pid);
    let start = Instant::now();
    let wheel = format!("\x1b[<{SGR_WHEEL_UP};{};{}M", WHEEL_COL + 1, WHEEL_ROW + 1);
    let wheel_lat = paced_inputs(harness, wheel.as_bytes(), WHEEL_EVENTS, WHEEL_INTERVAL)?;
    let moved_by_wheel = harness.screen_contents() != screen_before;
    dump_screen(harness, "2-after-wheel");
    let pgup_lat = paced_inputs(harness, keys::PGUP, PAGE_KEYS, PAGE_INTERVAL)?;
    let tail_hidden_after_pgup = !harness.contains_text(&state.sentinel);
    dump_screen(harness, "3-after-pgup");
    let pgdn_lat = paced_inputs(harness, keys::PGDN, PAGE_KEYS, PAGE_INTERVAL)?;
    harness.update(Duration::from_millis(250));
    let scroll_wall = start.elapsed();
    dump_screen(harness, "4-after-pgdn");
    let (scroll_cpu_pct, _) = cpu.finish();
    let mut scroll_result = harness
        .bench_results("long_session.scroll", scroll_wall)
        .with_extra("cpu_pct", scroll_cpu_pct)
        .with_extra("wheel_moved_viewport", bool_f(moved_by_wheel))
        .with_extra(
            "pgup_scrolled_tail_offscreen",
            bool_f(tail_hidden_after_pgup),
        );
    for (name, lat) in [
        ("wheel", &wheel_lat),
        ("pgup", &pgup_lat),
        ("pgdn", &pgdn_lat),
    ] {
        scroll_result = add_latency(scroll_result, name, lat);
    }

    // ── Phase 3: stream a long response on top of the history ────────
    content.set_chunk_delay(Some(STREAM_CHUNK_DELAY));
    content.set_response(build_stream_response(STREAM_SECTIONS));
    harness.inject_keys(b"please continue\r")?;
    harness.wait_for_text(STREAM_SENTINEL, Duration::from_secs(60))?;
    harness.reset_timing();
    let sampler = start_sampler(pid)?;
    let cpu = CpuMeter::start(pid);
    let start = Instant::now();
    let mut frame_ends = Vec::new();
    let mut seen = 0;
    while start.elapsed() < STREAM_WINDOW {
        harness.update(Duration::from_millis(1));
        let now = harness.frame_count();
        while seen < now {
            frame_ends.push(Instant::now());
            seen += 1;
        }
        if !harness.is_running()? {
            break;
        }
    }
    let stream_wall = start.elapsed();
    let (stream_cpu_pct, stream_tree_cpu_pct) = cpu.finish();
    let still_streaming =
        harness.contains_text("Responding") || harness.contains_text("Ctrl+c:cancel");
    dump_screen(harness, "5-streaming");
    let intervals: Vec<Duration> = frame_ends.windows(2).map(|w| w[1] - w[0]).collect();
    let mut stream_result = harness
        .bench_results("long_session.stream", stream_wall)
        .with_extra("cpu_pct", stream_cpu_pct)
        .with_extra("tree_cpu_pct", stream_tree_cpu_pct)
        .with_extra("still_streaming_at_end", bool_f(still_streaming));
    stream_result = add_latency(
        stream_result,
        "frame_interval",
        &Latencies::from_measured(&intervals),
    );
    if let Some((mut child, out)) = sampler {
        let _ = child.wait();
        eprintln!("long_session: wrote sample profile to {}", out.display());
    }

    // Let the turn finish so quitting does not race an in-flight stream.
    let _ = harness.wait_for_turn_idle(Duration::from_secs(60));
    content.set_chunk_delay(None);

    let results = vec![resume_result, scroll_result, stream_result];
    for r in &results {
        print_summary(r);
    }
    Ok(results)
}

fn dump_screen(harness: &PtyHarness, name: &str) {
    let Some(dir) = std::env::var_os(SCREENS_ENV).map(PathBuf::from) else {
        return;
    };
    let _ = std::fs::create_dir_all(&dir);
    let _ = std::fs::write(dir.join(format!("{name}.txt")), harness.screen_contents());
}

/// Pump until no frame completes for [`QUIET_WINDOW`] (capped at [`SETTLE_CAP`]); returns the time spent.
fn settle(harness: &mut PtyHarness) -> Duration {
    let start = Instant::now();
    loop {
        let before = harness.frame_count();
        harness.update(QUIET_WINDOW);
        if harness.frame_count() == before || start.elapsed() >= SETTLE_CAP {
            return start.elapsed();
        }
    }
}

/// Inject `bytes` `count` times, one per `interval`, timing each inject → next completed frame.
fn paced_inputs(
    harness: &mut PtyHarness,
    bytes: &[u8],
    count: usize,
    interval: Duration,
) -> Result<Latencies> {
    let mut measured = Vec::with_capacity(count);
    let mut no_frame = 0;
    for _ in 0..count {
        let before = harness.frame_count();
        let t = Instant::now();
        harness.inject_keys(bytes)?;
        let mut got = None;
        while t.elapsed() < FRAME_WAIT {
            harness.update(Duration::from_millis(1));
            if harness.frame_count() > before {
                got = Some(t.elapsed());
                break;
            }
        }
        match got {
            Some(d) => measured.push(d),
            None => no_frame += 1,
        }
        let spent = t.elapsed();
        if spent < interval {
            harness.update(interval - spent);
        }
    }
    let mut lat = Latencies::from_measured(&measured);
    lat.no_frame = no_frame;
    Ok(lat)
}

struct Latencies {
    sorted_ms: Vec<f64>,
    no_frame: usize,
}

impl Latencies {
    fn from_measured(d: &[Duration]) -> Self {
        let mut sorted_ms: Vec<f64> = d.iter().map(|d| ms(*d)).collect();
        sorted_ms.sort_by(|a, b| a.total_cmp(b));
        Self {
            sorted_ms,
            no_frame: 0,
        }
    }
}

fn add_latency(mut r: BenchResults, name: &str, lat: &Latencies) -> BenchResults {
    let s = &lat.sorted_ms;
    for (label, pct) in [("p50", 50.0), ("p95", 95.0), ("p99", 99.0)] {
        r = r.with_extra(format!("{name}_{label}_ms"), percentile(s, pct));
    }
    r.with_extra(format!("{name}_max_ms"), s.last().copied().unwrap_or(0.0))
        .with_extra(format!("{name}_count"), s.len() as f64)
        .with_extra(format!("{name}_no_frame"), lat.no_frame as f64)
}

fn print_summary(r: &BenchResults) {
    let mut line = format!(
        "[{}] frames={} fps={:.1} frame_ms p50={:.2} p95={:.2} p99={:.2} max={:.2}",
        r.scenario, r.total_frames, r.avg_fps, r.p50_ms, r.p95_ms, r.p99_ms, r.max_ms
    );
    for (k, v) in &r.extra {
        line.push_str(&format!(" {k}={v:.2}"));
    }
    eprintln!("{line}");
}

/// First run of plain words (no markdown punctuation) from the message, up to ~40 chars.
fn sentinel_from_message(message: &str) -> Option<String> {
    message.lines().find_map(|line| {
        let mut out = String::new();
        for word in line.split_whitespace() {
            if word.chars().any(|c| "*`_[]#<>|~\\".contains(c)) {
                break;
            }
            if !out.is_empty() && out.len() + word.len() + 1 > 40 {
                break;
            }
            if !out.is_empty() {
                out.push(' ');
            }
            out.push_str(word);
        }
        (out.chars().count() >= 12).then_some(out)
    })
}

fn build_stream_response(sections: usize) -> String {
    use std::fmt::Write as _;
    let mut s = format!("{STREAM_SENTINEL}: status report on top of a long history\n\n");
    for i in 0..sections {
        let _ = write!(
            s,
            "## Step {i}: verify the endpoint\n\n\
             The worker for step {i} started cleanly and pulled the **image** from `ghcr.io`, \
             so the remaining blocker is the [registry scope](https://example.com/docs/{i}). \
             I checked the logs, the health probe, and the queue depth before moving on to the next item.\n\n\
             - endpoint `ep-{i}` is **ready** with 2 workers\n\
             - queue depth is {i}, latency p95 is {}ms\n\
             - next: run the voice clone smoke test\n\n\
             ```python\n\
             def check_step_{i}(client):\n\
             \x20   resp = client.post(\"/run\", json={{\"step\": {i}, \"text\": \"hello world\"}})\n\
             \x20   assert resp.status_code == 200, resp.text\n\
             \x20   return resp.json()[\"output\"][\"audio_url\"]\n\
             ```\n\n\
             | check | status | ms |\n\
             |-------|--------|----|\n\
             | health | ok | {} |\n\
             | clone | ok | {} |\n\n",
            100 + i,
            10 + i,
            900 + i,
        );
    }
    s
}

/// CPU time of the pager (and its descendants) over a window, from `ps` cumulative `time`.
struct CpuMeter {
    pid: u32,
    start: Instant,
    root0: f64,
    tree0: f64,
}

impl CpuMeter {
    fn start(pid: u32) -> Self {
        let (root0, tree0) = cpu_secs(pid).unwrap_or((0.0, 0.0));
        Self {
            pid,
            start: Instant::now(),
            root0,
            tree0,
        }
    }

    /// `(pager cpu %, pager+descendants cpu %)` of one core over the window; `-1` when `ps` failed.
    fn finish(self) -> (f64, f64) {
        let wall = self.start.elapsed().as_secs_f64();
        match cpu_secs(self.pid) {
            Some((root, tree)) if wall > 0.0 => (
                100.0 * (root - self.root0) / wall,
                100.0 * (tree - self.tree0) / wall,
            ),
            _ => (-1.0, -1.0),
        }
    }
}

/// `(root, root + descendants)` cumulative CPU seconds.
fn cpu_secs(root: u32) -> Option<(f64, f64)> {
    let out = Command::new("ps")
        .args(["-A", "-o", "pid=,ppid=,time="])
        .stderr(Stdio::null())
        .output()
        .ok()?;
    let text = String::from_utf8_lossy(&out.stdout);
    let rows: Vec<(u32, u32, f64)> = text
        .lines()
        .filter_map(|l| {
            let mut it = l.split_whitespace();
            Some((
                it.next()?.parse().ok()?,
                it.next()?.parse().ok()?,
                parse_ps_time(it.next()?)?,
            ))
        })
        .collect();
    let root_secs = rows.iter().find(|r| r.0 == root)?.2;
    let mut tree = vec![root];
    let mut total = 0.0;
    let mut i = 0;
    while i < tree.len() {
        let p = tree[i];
        for r in &rows {
            if r.0 == p {
                total += r.2;
            }
            if r.1 == p && !tree.contains(&r.0) {
                tree.push(r.0);
            }
        }
        i += 1;
    }
    Some((root_secs, total))
}

/// `ps` `time`: `[[dd-]hh:]mm:ss.ss`.
fn parse_ps_time(s: &str) -> Option<f64> {
    let (days, rest) = match s.split_once('-') {
        Some((d, r)) => (d.parse::<f64>().ok()?, r),
        None => (0.0, s),
    };
    let mut secs = 0.0;
    for part in rest.split(':') {
        secs = secs * 60.0 + part.parse::<f64>().ok()?;
    }
    Some(days * 86_400.0 + secs)
}

/// macOS only: `sample <pid> 5 -file <out>` in the background when [`SAMPLE_ENV`] is set.
fn start_sampler(pid: u32) -> Result<Option<(std::process::Child, PathBuf)>> {
    let Some(out) = std::env::var_os(SAMPLE_ENV).map(PathBuf::from) else {
        return Ok(None);
    };
    if !cfg!(target_os = "macos") {
        eprintln!("long_session: {SAMPLE_ENV} is macOS-only; skipping");
        return Ok(None);
    }
    if let Some(parent) = out.parent().filter(|p| !p.as_os_str().is_empty()) {
        std::fs::create_dir_all(parent)?;
    }
    // `sample` exits by itself after SAMPLE_SECS and the stream phase waits for it; ProcessScope is a
    // production-pager concept.
    #[allow(clippy::disallowed_methods)]
    let child = Command::new("sample")
        .arg(pid.to_string())
        .arg(SAMPLE_SECS.to_string())
        .arg("-file")
        .arg(Path::new(&out))
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .context("spawn macOS `sample`")?;
    Ok(Some((child, out)))
}

fn ms(d: Duration) -> f64 {
    d.as_secs_f64() * 1000.0
}

fn bool_f(b: bool) -> f64 {
    if b { 1.0 } else { 0.0 }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sentinel_skips_markdown_and_caps_length() {
        assert_eq!(
            sentinel_from_message(
                "## Heading\n\nStill waiting on you. The approval is live:\n\n**x**"
            )
            .as_deref(),
            Some("Still waiting on you. The approval is")
        );
        assert_eq!(sentinel_from_message("**bold** only"), None);
    }

    #[test]
    fn ps_time_formats() {
        assert_eq!(parse_ps_time("0:01.50"), Some(1.5));
        assert_eq!(parse_ps_time("2:03.00"), Some(123.0));
        assert_eq!(parse_ps_time("1:00:00.00"), Some(3600.0));
        assert_eq!(parse_ps_time("1-00:00:01.00"), Some(86_401.0));
    }

    #[test]
    fn stream_response_starts_with_sentinel() {
        assert!(build_stream_response(2).starts_with(STREAM_SENTINEL));
    }
}
