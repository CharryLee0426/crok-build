//! `crok logs`: read the unified log (`~/.crok/logs/unified.jsonl`).
//!
//! The agent, the TUI and Crok Desktop all append to that one file. This prints it as one timeline, filtered by
//! severity, writer, session, age or text, and can follow it while a problem is being reproduced.

use std::io::{BufRead, BufReader, IsTerminal, Seek, SeekFrom, Write};
use std::path::Path;
use std::time::Duration;

use anyhow::{Context, Result};
use chrono::{DateTime, Local, Utc};
use serde::Deserialize;

#[derive(Clone, Debug, clap::Args)]
#[command(after_help = "\
Examples:
  crok logs --errors                 warnings and errors, newest last
  crok logs -f --src desktop         follow what Crok Desktop writes
  crok logs --session 01a0e1a1 -n 0  everything logged for one session
  crok logs --since 10m --grep acp.request_failed

A request the agent fails is logged as `acp.request_failed` with the method, the error code and the error's `data`, \
which is where the cause of an \"Internal error\" is. Crok Desktop logs the same failure from its side as \
`acp.request_failed` with `--src desktop`.")]
pub struct LogsArgs {
    /// Show the last N matching entries (0 for all of them)
    #[arg(short = 'n', long, default_value_t = 50)]
    pub lines: usize,
    /// Keep printing entries as they are written
    #[arg(short, long)]
    pub follow: bool,
    /// Least severe level to show
    #[arg(long, value_enum, default_value_t = Level::Debug)]
    pub level: Level,
    /// Warnings and errors only (same as --level warn)
    #[arg(long, conflicts_with = "level")]
    pub errors: bool,
    /// Only entries written by this part of Crok
    #[arg(long, value_enum)]
    pub src: Option<Source>,
    /// Only entries of sessions whose id starts with this
    #[arg(long, value_name = "ID")]
    pub session: Option<String>,
    /// Only entries containing this text, in any letter case
    #[arg(long, value_name = "TEXT")]
    pub grep: Option<String>,
    /// Only entries newer than this, for example 30s, 10m, 2h or 1d
    #[arg(long, value_name = "AGE", value_parser = parse_age)]
    pub since: Option<Duration>,
    /// Print the entries as the JSON lines they are stored as
    #[arg(long)]
    pub json: bool,
    /// Print the log file's path and exit
    #[arg(long)]
    pub path: bool,
}

/// Most severe first, so a level includes everything declared before it.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, clap::ValueEnum)]
pub enum Level {
    Error,
    Warn,
    Info,
    Debug,
}

impl Level {
    fn parse(raw: &str) -> Self {
        match raw {
            "error" => Self::Error,
            "warn" => Self::Warn,
            "info" => Self::Info,
            _ => Self::Debug,
        }
    }

    fn label(self) -> &'static str {
        match self {
            Self::Error => "ERROR",
            Self::Warn => "WARN ",
            Self::Info => "INFO ",
            Self::Debug => "DEBUG",
        }
    }

    fn color(self) -> &'static str {
        match self {
            Self::Error => "\x1b[31m",
            Self::Warn => "\x1b[33m",
            Self::Info => "",
            Self::Debug => "\x1b[2m",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, clap::ValueEnum)]
pub enum Source {
    /// The agent: sessions, tools, model requests
    Agent,
    /// The terminal UI
    Tui,
    /// Crok Desktop
    Desktop,
}

impl Source {
    /// The `src` value entries are stored with.
    fn wire(self) -> &'static str {
        match self {
            Self::Agent => "shell",
            Self::Tui => "grok-pager",
            Self::Desktop => "grok-desktop",
        }
    }

    fn label(wire: &str) -> &str {
        match wire {
            "shell" => "agent",
            "grok-pager" => "tui",
            "grok-desktop" => "desktop",
            other => other,
        }
    }
}

fn parse_age(raw: &str) -> Result<Duration, String> {
    let raw = raw.trim();
    let split = raw.find(|c: char| !c.is_ascii_digit()).unwrap_or(raw.len());
    let (digits, unit) = raw.split_at(split);
    let count: u64 = digits
        .parse()
        .map_err(|_| format!("`{raw}` is not an age: write a number and a unit, like 10m"))?;
    let seconds = match unit {
        "s" => 1,
        "m" | "" => 60,
        "h" => 3600,
        "d" => 86_400,
        _ => return Err(format!("unknown unit `{unit}`: use s, m, h or d")),
    };
    Ok(Duration::from_secs(count.saturating_mul(seconds)))
}

/// The fields of a stored entry this command reads. Lenient on purpose: a line written by a newer build still prints.
#[derive(Deserialize)]
struct Entry {
    ts: String,
    src: String,
    pid: Option<u32>,
    lvl: String,
    sid: Option<String>,
    msg: String,
    ctx: Option<serde_json::Value>,
}

struct Filter {
    level: Level,
    src: Option<&'static str>,
    session: Option<String>,
    grep: Option<String>,
    not_before: Option<DateTime<Utc>>,
}

impl Filter {
    fn new(args: &LogsArgs, now: DateTime<Utc>) -> Self {
        Self {
            level: if args.errors { Level::Warn } else { args.level },
            src: args.src.map(Source::wire),
            session: args.session.clone(),
            grep: args.grep.as_ref().map(|text| text.to_lowercase()),
            not_before: args
                .since
                .and_then(|age| chrono::Duration::from_std(age).ok())
                .map(|age| now - age),
        }
    }

    fn matches(&self, line: &str, entry: &Entry) -> bool {
        if Level::parse(&entry.lvl) > self.level {
            return false;
        }
        if self.src.is_some_and(|src| src != entry.src) {
            return false;
        }
        if let Some(prefix) = &self.session
            && !entry
                .sid
                .as_ref()
                .is_some_and(|sid| sid.starts_with(prefix))
        {
            return false;
        }
        if let Some(not_before) = self.not_before
            && DateTime::parse_from_rfc3339(&entry.ts).is_ok_and(|ts| ts < not_before)
        {
            return false;
        }
        self.grep
            .as_ref()
            .is_none_or(|needle| line.to_lowercase().contains(needle))
    }
}

/// One entry as a line of text: local time, level, writer and pid, session, message, then the context as `key=value`.
fn render(entry: &Entry, color: bool) -> String {
    use std::fmt::Write as _;

    let level = Level::parse(&entry.lvl);
    let time = DateTime::parse_from_rfc3339(&entry.ts)
        .map(|ts| {
            ts.with_timezone(&Local)
                .format("%m-%d %H:%M:%S%.3f")
                .to_string()
        })
        .unwrap_or_else(|_| entry.ts.clone());
    let mut line = String::new();
    let (on, off) = if color && !level.color().is_empty() {
        (level.color(), "\x1b[0m")
    } else {
        ("", "")
    };
    let _ = write!(line, "{time} {on}{}{off} ", level.label());
    let _ = write!(line, "{:<7}", Source::label(&entry.src));
    if let Some(pid) = entry.pid {
        let _ = write!(line, " {pid:<6}");
    }
    if let Some(sid) = &entry.sid {
        let _ = write!(line, " {}", sid.get(..8).unwrap_or(sid));
    }
    let _ = write!(line, " {on}{}{off}", entry.msg);
    if let Some(serde_json::Value::Object(ctx)) = &entry.ctx {
        for (key, value) in ctx {
            match value {
                serde_json::Value::Null => {}
                serde_json::Value::String(text)
                    if !text.is_empty() && !text.contains(char::is_whitespace) =>
                {
                    let _ = write!(line, " {key}={text}");
                }
                other => {
                    let _ = write!(line, " {key}={other}");
                }
            }
        }
    } else if let Some(ctx) = &entry.ctx {
        let _ = write!(line, " {ctx}");
    }
    line
}

/// What to print for one stored line, or `None` when the filter drops it.
/// A line that is not an entry (a torn write, a hand edit) prints as it is, unless a filter is narrowing the output.
fn output_for(line: &str, filter: &Filter, json: bool, color: bool) -> Option<String> {
    let line = line.trim_end();
    if line.is_empty() {
        return None;
    }
    match serde_json::from_str::<Entry>(line) {
        Ok(entry) => filter.matches(line, &entry).then(|| {
            if json {
                line.to_owned()
            } else {
                render(&entry, color)
            }
        }),
        Err(_) => {
            let unfiltered = filter.level == Level::Debug
                && filter.src.is_none()
                && filter.session.is_none()
                && filter.not_before.is_none()
                && filter.grep.is_none();
            unfiltered.then(|| line.to_owned())
        }
    }
}

pub fn run(args: LogsArgs) -> Result<()> {
    let path = xai_grok_telemetry::unified_log::path();
    let mut out = std::io::stdout().lock();
    if args.path {
        return Ok(crate::util::ignore_broken_pipe(writeln!(
            out,
            "{}",
            path.display()
        ))?);
    }
    let color = !args.json && std::io::stdout().is_terminal();
    let filter = Filter::new(&args, Utc::now());

    let mut offset = 0;
    if path.exists() {
        let text =
            std::fs::read(&path).with_context(|| format!("cannot read {}", path.display()))?;
        offset = text.len() as u64;
        let text = String::from_utf8_lossy(&text);
        let shown: Vec<String> = text
            .lines()
            .filter_map(|line| output_for(line, &filter, args.json, color))
            .collect();
        let skip = match args.lines {
            0 => 0,
            n => shown.len().saturating_sub(n),
        };
        for line in shown.iter().skip(skip) {
            if writeln!(out, "{line}").is_err() {
                return Ok(());
            }
        }
    } else if !args.follow {
        eprintln!(
            "Nothing has been logged yet: {} does not exist.",
            path.display()
        );
        return Ok(());
    }

    if args.follow {
        follow(&path, offset, &filter, args.json, color, &mut out)?;
    }
    Ok(())
}

/// Print entries as they are appended. The log is trimmed in place when it reaches its size cap, so a file that got
/// shorter is read from its new end rather than from an offset that now points into different lines.
fn follow(
    path: &Path,
    mut offset: u64,
    filter: &Filter,
    json: bool,
    color: bool,
    out: &mut impl Write,
) -> Result<()> {
    let mut pending = String::new();
    loop {
        std::thread::sleep(Duration::from_millis(250));
        let Ok(file) = std::fs::File::open(path) else {
            offset = 0;
            continue;
        };
        let len = file.metadata().map(|meta| meta.len()).unwrap_or(0);
        if len < offset {
            offset = len;
            pending.clear();
            continue;
        }
        if len == offset {
            continue;
        }
        let mut reader = BufReader::new(file);
        reader.seek(SeekFrom::Start(offset))?;
        let mut bytes = Vec::new();
        while reader.read_until(b'\n', &mut bytes)? > 0 {
            offset += bytes.len() as u64;
            pending.push_str(&String::from_utf8_lossy(&bytes));
            bytes.clear();
            // A line without its newline is still being written; keep it for the next pass.
            if !pending.ends_with('\n') {
                break;
            }
            if let Some(line) = output_for(&pending, filter, json, color)
                && writeln!(out, "{line}").is_err()
            {
                return Ok(());
            }
            pending.clear();
        }
        if out.flush().is_err() {
            return Ok(());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const FAILED: &str = r#"{"ts":"2026-10-06T18:05:45.319Z","src":"shell","pid":8903,"ver":"1.0.41","lvl":"error","sid":"01a0e1a1-5542-77f3","msg":"acp.request_failed","ctx":{"code":-32603,"data":"session store: disk I/O error","method":"session/prompt"}}"#;
    const DESKTOP: &str = r#"{"ts":"2026-10-06T18:05:45.400Z","src":"grok-desktop","pid":77,"lvl":"debug","msg":"acp.request","ctx":{"method":"session/prompt","ok":true}}"#;

    fn args() -> LogsArgs {
        LogsArgs {
            lines: 50,
            follow: false,
            level: Level::Debug,
            errors: false,
            src: None,
            session: None,
            grep: None,
            since: None,
            json: false,
            path: false,
        }
    }

    fn now() -> DateTime<Utc> {
        "2026-10-06T18:10:00Z".parse().unwrap()
    }

    fn shown(line: &str, args: &LogsArgs) -> Option<String> {
        output_for(line, &Filter::new(args, now()), args.json, false)
    }

    #[test]
    fn an_entry_renders_as_one_line_with_its_context() {
        let line = shown(FAILED, &args()).unwrap();
        assert!(
            line.contains(" ERROR agent   8903   01a0e1a1 acp.request_failed"),
            "{line}"
        );
        assert!(line.contains(" code=-32603"), "{line}");
        assert!(
            line.contains(r#" data="session store: disk I/O error""#),
            "{line}"
        );
        assert!(line.contains(" method=session/prompt"), "{line}");
    }

    #[test]
    fn filters_narrow_by_level_writer_session_text_and_age() {
        let errors = LogsArgs {
            errors: true,
            ..args()
        };
        assert!(shown(FAILED, &errors).is_some());
        assert!(shown(DESKTOP, &errors).is_none());

        let desktop = LogsArgs {
            src: Some(Source::Desktop),
            ..args()
        };
        assert!(shown(DESKTOP, &desktop).is_some());
        assert!(shown(FAILED, &desktop).is_none());

        let session = LogsArgs {
            session: Some("01a0e1a1".into()),
            ..args()
        };
        assert!(shown(FAILED, &session).is_some());
        assert!(shown(DESKTOP, &session).is_none());

        let grep = LogsArgs {
            grep: Some("DISK i/o".into()),
            ..args()
        };
        assert!(shown(FAILED, &grep).is_some());
        assert!(shown(DESKTOP, &grep).is_none());

        // Both entries are a little over four minutes old.
        let recent = LogsArgs {
            since: Some(Duration::from_secs(60)),
            ..args()
        };
        assert!(shown(FAILED, &recent).is_none());
        let wider = LogsArgs {
            since: Some(Duration::from_secs(600)),
            ..args()
        };
        assert!(shown(FAILED, &wider).is_some());
    }

    #[test]
    fn json_output_is_the_stored_line() {
        let json = LogsArgs {
            json: true,
            ..args()
        };
        assert_eq!(shown(FAILED, &json).as_deref(), Some(FAILED));
    }

    #[test]
    fn a_line_that_is_not_an_entry_prints_only_unfiltered() {
        assert_eq!(shown("not json", &args()).as_deref(), Some("not json"));
        assert!(
            shown(
                "not json",
                &LogsArgs {
                    errors: true,
                    ..args()
                }
            )
            .is_none()
        );
        assert!(shown("  \n", &args()).is_none());
    }

    #[test]
    fn ages_parse_with_a_unit() {
        assert_eq!(parse_age("30s"), Ok(Duration::from_secs(30)));
        assert_eq!(parse_age("10m"), Ok(Duration::from_secs(600)));
        assert_eq!(parse_age("10"), Ok(Duration::from_secs(600)));
        assert_eq!(parse_age("2h"), Ok(Duration::from_secs(7200)));
        assert_eq!(parse_age("1d"), Ok(Duration::from_secs(86_400)));
        assert!(parse_age("soon").is_err());
        assert!(parse_age("5w").is_err());
    }
}
