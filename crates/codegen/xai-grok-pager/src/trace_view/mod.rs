//! Offline developer trace inspection, shared by the terminal and HTML viewers.

use std::io::Write;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};

pub mod data;
mod html;
pub mod transcript;
pub(crate) mod tui;

#[derive(Debug, Clone, Copy, PartialEq, Eq, clap::ValueEnum)]
pub enum TraceFormat {
    Tui,
    Html,
    Json,
}

#[derive(Debug, Clone, clap::Args)]
#[command(
    after_help = "Examples:\n  crok trace view <session-id>\n  crok trace view ./trace.tar.gz --html --open\n  crok trace view ./session --format html -o trace.html\n  crok trace view ./updates.jsonl --format json -o -\n\nViews are local snapshots. They never upload trace data. HTML includes the recorded\ncontent; review it before sharing. Missing measurements are shown as unavailable."
)]
pub struct TraceViewArgs {
    /// Session ID, session directory, JSON/JSONL file, or exported .tar.gz bundle
    pub source: String,
    /// Presentation format (HTML is a self-contained, offline page)
    #[arg(long, value_enum, default_value = "tui")]
    pub format: TraceFormat,
    /// Shorthand for --format html
    #[arg(long, conflicts_with = "format")]
    pub html: bool,
    /// HTML/JSON destination; use - for stdout (default: $CROK_HOME/trace-exports)
    #[arg(short, long)]
    pub output: Option<PathBuf>,
    /// Open the generated HTML page in the default browser
    #[arg(long)]
    pub open: bool,
}

pub fn run(args: TraceViewArgs) -> Result<()> {
    let format = if args.html {
        TraceFormat::Html
    } else {
        args.format
    };
    anyhow::ensure!(
        format != TraceFormat::Tui || (args.output.is_none() && !args.open),
        "--output and --open require --html or --format html/json"
    );
    anyhow::ensure!(
        !args.open || format == TraceFormat::Html,
        "--open requires HTML output"
    );
    anyhow::ensure!(
        !args.open || args.output.as_deref() != Some(Path::new("-")),
        "--open requires an output file, not stdout"
    );

    let source = resolve_source(&args.source)?;
    let trace = data::load(&source)?;
    if format == TraceFormat::Tui {
        return tui::run(&trace);
    }
    let content = match format {
        TraceFormat::Html => html::render(&trace)?,
        TraceFormat::Json => serde_json::to_string_pretty(&trace)?,
        TraceFormat::Tui => unreachable!(),
    };
    let output = args
        .output
        .unwrap_or_else(|| default_output(&trace.session_id, format));
    if output == Path::new("-") {
        let mut stdout = std::io::stdout().lock();
        stdout.write_all(content.as_bytes())?;
        stdout.write_all(b"\n")?;
        return Ok(());
    }
    let output = PathBuf::from(shellexpand::tilde(&output.to_string_lossy()).as_ref());
    ensure_output_not_input(&source, &output)?;
    write_output(&output, content.as_bytes())?;
    let output = dunce::canonicalize(&output).unwrap_or(output);
    eprintln!("Trace saved to {}", output.display());
    if args.open && !crate::link_opener::open_path(&output) {
        eprintln!(
            "Could not launch a browser. Open {} manually.",
            output.display()
        );
    }
    Ok(())
}

fn resolve_source(source: &str) -> Result<PathBuf> {
    let path = PathBuf::from(shellexpand::tilde(source).as_ref());
    if path.exists() {
        return Ok(path);
    }
    // A missing explicit path should not trigger a session-store lookup.
    if source.contains('/') || source.contains('\\') || source.starts_with('.') {
        anyhow::bail!("Trace input does not exist: {}", path.display());
    }
    crate::trace_cmd::find_session_dir(source)
}

fn ensure_output_not_input(source: &Path, output: &Path) -> Result<()> {
    if !output.exists() {
        return Ok(());
    }
    let output = dunce::canonicalize(output)?;
    let source = dunce::canonicalize(source)?;
    let input_directory = if source.is_dir() {
        Some(source.as_path())
    } else if source
        .file_name()
        .is_some_and(|name| name == "summary.json")
    {
        source.parent()
    } else {
        None
    };
    anyhow::ensure!(
        output != source && !input_directory.is_some_and(|directory| output.starts_with(directory)),
        "Refusing to overwrite an existing file in the input trace; choose a separate report path"
    );
    Ok(())
}

fn default_output(session_id: &str, format: TraceFormat) -> PathBuf {
    let name: String = session_id
        .chars()
        .take(120)
        .map(|c| {
            if c.is_ascii_alphanumeric() || matches!(c, '-' | '_') {
                c
            } else {
                '_'
            }
        })
        .collect();
    let name = if name.is_empty() { "trace" } else { &name };
    let extension = if format == TraceFormat::Html {
        "html"
    } else {
        "json"
    };
    xai_grok_shell::util::grok_home::grok_home()
        .join("trace-exports")
        .join(format!("{name}.{extension}"))
}

fn write_output(path: &Path, content: &[u8]) -> Result<()> {
    if let Some(parent) = path.parent().filter(|p| !p.as_os_str().is_empty()) {
        std::fs::create_dir_all(parent)
            .with_context(|| format!("Failed to create {}", parent.display()))?;
    }
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create(true).truncate(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options
        .open(path)
        .with_context(|| format!("Failed to write {}", path.display()))?;
    file.write_all(content)
        .context("Failed to write trace visualization")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::app::{Command, PagerArgs};
    use crate::trace_cmd::TraceCommand;
    use clap::Parser;

    #[test]
    fn legacy_export_flags_still_parse() {
        let args = PagerArgs::try_parse_from([
            "grok",
            "trace",
            "session-123",
            "--local",
            "--json",
            "-o",
            "trace.tar.gz",
        ])
        .unwrap();
        let Some(Command::Trace(args)) = args.command else {
            panic!("trace command expected")
        };
        let export = args.into_export().unwrap();
        assert_eq!(export.session_id, "session-123");
        assert!(export.local && export.json);
        assert_eq!(export.output.as_deref(), Some(Path::new("trace.tar.gz")));
    }

    #[test]
    fn view_is_a_local_subcommand() {
        let args = PagerArgs::try_parse_from([
            "grok",
            "trace",
            "view",
            "bundle.tar.gz",
            "--html",
            "--open",
        ])
        .unwrap();
        let Some(Command::Trace(args)) = args.command else {
            panic!("trace command expected")
        };
        let Some(TraceCommand::View(view)) = args.command else {
            panic!("view command expected")
        };
        assert!(view.html && view.open);
        assert_eq!(view.source, "bundle.tar.gz");
    }

    #[test]
    fn invalid_commands_do_not_fall_through_to_upload() {
        for argv in [
            vec!["grok", "trace"],
            vec!["grok", "trace", "view"],
            vec!["grok", "trace", "--local", "view", "s"],
            vec!["grok", "trace", "view", "s", "--format", "invalid"],
        ] {
            assert!(PagerArgs::try_parse_from(argv).is_err());
        }
    }

    #[test]
    fn output_name_cannot_escape_export_directory() {
        let output = default_output("../../bad/id", TraceFormat::Html);
        assert_eq!(output.file_name().unwrap(), "______bad_id.html");
    }

    #[test]
    fn reports_cannot_overwrite_source_records() {
        let dir = tempfile::tempdir().unwrap();
        let summary = dir.path().join("summary.json");
        let events = dir.path().join("events.jsonl");
        std::fs::write(&summary, "{}").unwrap();
        std::fs::write(&events, "{}").unwrap();
        assert!(ensure_output_not_input(&events, &events).is_err());
        assert!(ensure_output_not_input(dir.path(), &summary).is_err());
        assert!(ensure_output_not_input(&summary, &events).is_err());
        assert!(ensure_output_not_input(dir.path(), &dir.path().join("new.html")).is_ok());
    }

    #[test]
    fn write_output_accepts_a_file_in_existing_directory() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("trace.html");
        write_output(&path, b"trace").unwrap();
        assert_eq!(std::fs::read(&path).unwrap(), b"trace");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(
                std::fs::metadata(&path).unwrap().permissions().mode() & 0o777,
                0o600
            );
        }
    }
}
