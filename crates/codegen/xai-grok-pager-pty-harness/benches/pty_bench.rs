//! Spawns the real pager binary in a PTY, dispatches named scenarios, and emits aggregated results as JSON.
//! Supports baseline comparison for CI regression detection.
//!
//! ## Typical use
//!
//! Run a single scenario locally:
//! ```bash
//! cargo bench -p xai-grok-pager-pty-harness \
//!   --bench pty_bench -- --scenario scroll-stress
//! ```
//!
//! Resume a long recorded session, scroll it, and stream on top of it (not part of `--all`):
//! ```bash
//! PTY_BENCH_LONG_SESSION_TRACE=~/Downloads/<session-id>.html \
//!   cargo bench -p xai-grok-pager-pty-harness \
//!   --bench pty_bench -- --scenario long-session --binary <pager>
//! ```
//!
//! Run every scenario and write a new baseline:
//! ```bash
//! cargo bench -p xai-grok-pager-pty-harness \
//!   --bench pty_bench -- --all \
//!   --write-baseline benches/pty_baselines/local.json
//! ```
//!
//! Run every scenario in CI and fail on >15% p99 regression:
//! ```bash
//! PAGER_BINARY=./artifacts/grok-${VERSION}-linux-x86_64 \
//!   cargo bench -p xai-grok-pager-pty-harness \
//!   --bench pty_bench -- --all \
//!   --baseline benches/pty_baselines/linux-x86_64.json
//! ```

use std::path::PathBuf;
use std::process::ExitCode;

use anyhow::{Context, Result, bail};
use clap::Parser as ClapParser;
use xai_grok_pager_pty_harness::{
    BenchResults, ContentController, PtyHarness, Scenario, compare_baseline, pager_binary,
    results::{DEFAULT_REGRESSION_THRESHOLD, load_baseline, write_baseline},
};

#[derive(ClapParser, Debug)]
#[command(
    name = "pty-bench",
    about = "PTY benchmark harness for xai-grok-pager",
    long_about = None,
)]
struct Cli {
    /// Run a single scenario by name. Mutually exclusive with --all.
    #[arg(long, value_enum, conflicts_with = "all")]
    scenario: Option<Scenario>,

    /// Run every scenario.
    #[arg(long)]
    all: bool,

    /// Path to the pager binary.
    /// Defaults to auto-resolve (PAGER_BINARY env or a locally-built debug binary).
    #[arg(long)]
    binary: Option<PathBuf>,

    /// Terminal rows.
    #[arg(long, default_value_t = 50)]
    rows: u16,

    /// Terminal columns.
    #[arg(long, default_value_t = 120)]
    cols: u16,

    /// Compare results against a baseline file and exit non-zero on regression (>15% p99 delta by default).
    #[arg(long, value_name = "PATH")]
    baseline: Option<PathBuf>,

    /// Save the current run as a new baseline.
    #[arg(long, value_name = "PATH", conflicts_with = "baseline")]
    write_baseline: Option<PathBuf>,

    /// Regression threshold as a fraction of baseline p99 (0.15 = 15%).
    #[arg(long, default_value_t = DEFAULT_REGRESSION_THRESHOLD)]
    threshold: f64,

    /// Accepted for `cargo bench` compatibility (libtest-style argument).
    /// We ignore it; this isn't a libtest harness.
    #[arg(long, hide = true)]
    #[allow(dead_code)]
    bench: bool,
}

#[tokio::main(flavor = "multi_thread", worker_threads = 2)]
async fn main() -> ExitCode {
    tracing_subscriber::fmt()
        .with_writer(std::io::stderr)
        .init();

    match run().await {
        Ok(code) => code,
        Err(e) => {
            eprintln!("pty-bench failed: {e:#}");
            ExitCode::from(2)
        }
    }
}

async fn run() -> Result<ExitCode> {
    let cli = Cli::parse();

    let binary = match cli.binary {
        // portable_pty resolves a relative program via PATH, not the cwd.
        Some(b) => std::path::absolute(&b)
            .with_context(|| format!("absolutize --binary {}", b.display()))?,
        None => pager_binary().context("resolve pager binary")?,
    };
    let scenarios: Vec<Scenario> = if cli.all {
        Scenario::ALL.to_vec()
    } else if let Some(s) = cli.scenario {
        vec![s]
    } else {
        bail!("specify --scenario <name> or --all");
    };

    tracing::info!(
        binary = %binary.display(),
        rows = cli.rows,
        cols = cli.cols,
        count = scenarios.len(),
        "starting pty-bench run"
    );

    let mut results: Vec<BenchResults> = Vec::with_capacity(scenarios.len());
    for scenario in scenarios {
        tracing::info!(scenario = scenario.as_str(), "running scenario");
        let content = ContentController::start()
            .await
            .context("start ContentController")?;
        let launch = scenario
            .launch(&content)
            .context("prepare scenario fixtures")?;
        let args: Vec<&str> = launch.args.iter().map(String::as_str).collect();
        let mut harness = PtyHarness::spawn_with_content_in_dir(
            &binary,
            cli.rows,
            cli.cols,
            &content,
            &args,
            launch.cwd.as_deref(),
        )
        .context("spawn pager PTY harness")?;

        let res = scenario.run_phases(&mut harness, &content).await;

        // Best-effort cleanup regardless of scenario outcome.
        let _ = harness.quit();

        match res {
            Ok(phases) => {
                for r in phases {
                    tracing::info!(
                        scenario = %r.scenario,
                        frames = r.total_frames,
                        p50_ms = r.p50_ms,
                        p99_ms = r.p99_ms,
                        "scenario complete"
                    );
                    results.push(r);
                }
            }
            Err(e) => {
                tracing::warn!(scenario = scenario.as_str(), error = %e, "scenario failed");
                results.push(BenchResults::from_timings(
                    scenario.as_str(),
                    &[],
                    std::time::Duration::ZERO,
                ));
            }
        }
    }

    // Emit JSON to stdout for downstream consumption.
    let json = serde_json::to_string_pretty(&results).context("serialize results")?;
    println!("{json}");

    if let Some(path) = cli.write_baseline {
        write_baseline(&path, &results)?;
        eprintln!("wrote baseline to {}", path.display());
    }

    if let Some(path) = cli.baseline {
        let baseline = load_baseline(&path)?;
        let regressions = compare_baseline(&results, &baseline, cli.threshold);
        if regressions.is_empty() {
            eprintln!(
                "OK: no scenarios regressed beyond {:.0}% of baseline p99",
                cli.threshold * 100.0
            );
        } else {
            eprintln!(
                "REGRESSION: {} scenario(s) exceeded {:.0}% p99 threshold:",
                regressions.len(),
                cli.threshold * 100.0
            );
            for r in &regressions {
                eprintln!(
                    "  {}: {:.2}ms -> {:.2}ms ({:+.1}%)",
                    r.scenario,
                    r.baseline_p99_ms,
                    r.current_p99_ms,
                    r.pct_delta * 100.0
                );
            }
            return Ok(ExitCode::from(1));
        }
    }

    Ok(ExitCode::SUCCESS)
}
