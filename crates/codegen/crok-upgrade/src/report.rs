//! What the command says: lines for a terminal, or one JSON object per line for Crok Desktop.

use std::io::{IsTerminal, Write};
use std::time::Instant;

pub struct Reporter {
    json: bool,
    progress_tty: bool,
    progress_shown: bool,
    last_progress: Option<(Instant, u64)>,
}

impl Reporter {
    pub fn new(json: bool) -> Self {
        Self {
            json,
            progress_tty: !json && std::io::stderr().is_terminal(),
            progress_shown: false,
            last_progress: None,
        }
    }

    /// A machine-readable event; silent in text mode.
    pub fn event(&mut self, value: serde_json::Value) {
        if !self.json {
            return;
        }
        let mut stdout = std::io::stdout().lock();
        let _ = serde_json::to_writer(&mut stdout, &value);
        let _ = stdout.write_all(b"\n");
        let _ = stdout.flush();
    }

    /// A line for the person at the terminal; silent in JSON mode.
    pub fn text(&mut self, line: impl AsRef<str>) {
        if self.json {
            return;
        }
        self.end_progress();
        println!("{}", line.as_ref());
    }

    /// A phase change, in both modes.
    pub fn status(&mut self, phase: &str, line: impl AsRef<str>) {
        if self.json {
            self.event(serde_json::json!({ "event": "status", "phase": phase, "message": line.as_ref() }));
        } else {
            self.text(line);
        }
    }

    /// Download progress, throttled so the stream stays small.
    pub fn progress(&mut self, received: u64, total: Option<u64>) {
        let now = Instant::now();
        let due = match self.last_progress {
            None => true,
            Some((at, last)) => {
                received == total.unwrap_or(u64::MAX)
                    || now.duration_since(at).as_millis() >= 250
                    || received.saturating_sub(last) >= 4 << 20
            }
        };
        if !due {
            return;
        }
        self.last_progress = Some((now, received));
        if self.json {
            self.event(serde_json::json!({ "event": "progress", "bytes": received, "total": total }));
        } else if self.progress_tty {
            let line = match total {
                Some(total) if total > 0 => format!(
                    "\r  {:>3}%  {} of {}",
                    received * 100 / total,
                    megabytes(received),
                    megabytes(total)
                ),
                _ => format!("\r  {}", megabytes(received)),
            };
            let mut stderr = std::io::stderr().lock();
            let _ = write!(stderr, "{line}\x1b[K");
            let _ = stderr.flush();
            self.progress_shown = true;
        }
    }

    pub fn end_progress(&mut self) {
        if self.progress_shown {
            let mut stderr = std::io::stderr().lock();
            let _ = stderr.write_all(b"\n");
            let _ = stderr.flush();
            self.progress_shown = false;
        }
        self.last_progress = None;
    }
}

fn megabytes(bytes: u64) -> String {
    format!("{:.1} MB", bytes as f64 / (1024.0 * 1024.0))
}
