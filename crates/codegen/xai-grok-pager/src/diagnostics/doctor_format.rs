//! In-TUI `/doctor` report formatting.

use unicode_width::UnicodeWidthStr;
use xai_grok_i18n::{tl, tlf};

use super::{
    DataControlFact, DiagnosticReport, FindingDisposition, NewlineFact, RuntimeFact, VoiceFacts,
};
use crate::clipboard::{ClipboardDelivery, NativeClipboardPreflight};
use crate::host::{DisplayServer, HostOs};
use crate::terminal::{MultiplexerKind, TerminalName};

/// Columns a row's label takes: the longest English label, `data-control`.
const LABEL_WIDTH: usize = 12;

/// One row of the report. The label is padded by the columns it takes on screen, so the values
/// line up when a label is in a script that is two columns wide per character.
fn push_row(out: &mut String, label: &str, value: &str) {
    let padding = LABEL_WIDTH.saturating_sub(label.width()) + 1;
    out.push_str(&format!("  {label}{}{value}\n", " ".repeat(padding)));
}

pub fn format_doctor(report: &DiagnosticReport) -> String {
    let facts = &report.facts;
    let mut out = String::new();
    out.push_str(&format!("{}\n", tl("Environment")));
    // The names are strum attributes, which cannot carry a marker: the one that is a word is here
    let terminal = match facts.terminal {
        TerminalName::Unknown => tl("Unknown").to_owned(),
        name => name.to_string(),
    };
    push_row(&mut out, tl("terminal"), &terminal);
    if let RuntimeFact::Available(xtversion) = &facts.xtversion {
        push_row(&mut out, "xtversion", xtversion);
    }
    let multiplexer = match facts.multiplexer {
        MultiplexerKind::Undetected => tl("None detected").to_owned(),
        kind => kind.to_string(),
    };
    push_row(&mut out, tl("multiplexer"), &multiplexer);
    if let Some(byobu) = facts.byobu {
        push_row(&mut out, "byobu", &byobu.to_string());
    }
    push_row(
        &mut out,
        "ssh",
        if facts.ssh { tl("yes") } else { tl("no") },
    );
    let color_level = match &facts.color.level {
        RuntimeFact::Available(level) => Some(*level),
        RuntimeFact::NoReply | RuntimeFact::Unavailable => None,
    };
    if let Some(color_level) = color_level {
        push_row(&mut out, tl("color"), color_level.as_ref());
    }
    if color_level.is_some() && facts.color.available_themes.len() == facts.color.total_themes {
        push_row(&mut out, tl("themes"), tl("all"));
    } else if color_level.is_some() {
        let themes = facts
            .color
            .available_themes
            .iter()
            .map(|theme| theme.display_name())
            .collect::<Vec<_>>()
            .join(", ");
        push_row(
            &mut out,
            tl("themes"),
            &format!(
                "{}/{}: {themes}",
                facts.color.available_themes.len(),
                facts.color.total_themes
            ),
        );
    }
    if let Some(keyboard) = &facts.keyboard {
        let rescue = if keyboard.os == HostOs::Macos {
            tl("OS rescue active")
        } else {
            tl("OS rescue unavailable on this platform")
        };
        push_row(
            &mut out,
            tl("keyboard"),
            &format!("{} ({rescue})", keyboard.modifier_delivery.label()),
        );
    }
    if let Some(newline) = &facts.newline {
        let detail = match newline {
            NewlineFact::Vte {
                version: Some(version),
            } => tlf(
                "VTE {version}; need >= 8200 for Shift+Enter",
                &[("version", version)],
            ),
            NewlineFact::Vte { version: None } => {
                tl("legacy VTE; need VTE >= 0.82 for Shift+Enter").to_owned()
            }
            NewlineFact::XtermJs { terminal } => tlf(
                "{terminal}: xterm.js can't distinguish Shift+Enter",
                &[("terminal", terminal)],
            ),
            NewlineFact::NoKittyKeyboardProtocol => {
                tl("no Kitty keyboard protocol; Shift+Enter == Enter").to_owned()
            }
        };
        push_row(&mut out, tl("newline"), &format!("Alt+Enter ({detail})"));
    }

    let clipboard = &facts.clipboard;
    let native = match clipboard.native_preflight {
        NativeClipboardPreflight::LocalAvailable => {
            format!("{} ({})", tl("local"), clipboard.native_tool)
        }
        NativeClipboardPreflight::RemoteOnly if clipboard.container_no_display => {
            format!("{} ({})", tl("container"), clipboard.native_tool)
        }
        NativeClipboardPreflight::RemoteOnly => {
            format!("{} ({})", tl("remote"), clipboard.native_tool)
        }
        NativeClipboardPreflight::Unavailable => tl("unavailable").to_owned(),
        NativeClipboardPreflight::Disabled => tl("off").to_owned(),
    };
    out.push_str(&format!("\n{}\n", tl("Clipboard")));
    push_row(&mut out, tl("native"), &native);
    push_row(
        &mut out,
        "tmux",
        if clipboard.tmux_route {
            tl("on")
        } else {
            tl("off")
        },
    );
    push_row(
        &mut out,
        "osc 52",
        if clipboard.osc52_route {
            tl(clipboard.osc52_capability.label())
        } else {
            tl("off")
        },
    );
    push_row(
        &mut out,
        "wrap",
        if clipboard.wrap_sink {
            tl("on")
        } else {
            tl("off")
        },
    );
    if clipboard.display_server == DisplayServer::Wayland {
        push_row(
            &mut out,
            "data-control",
            if clipboard.data_control == DataControlFact::Available {
                tl("on")
            } else {
                tl("off")
            },
        );
    }
    let status = match clipboard.delivery {
        ClipboardDelivery::Confirmed => tl("confirmed"),
        ClipboardDelivery::Unverified => tl("unverified"),
        ClipboardDelivery::Failed => tl("unavailable"),
    };
    push_row(&mut out, tl("status"), status);

    if let Some(voice) = &facts.voice {
        out.push_str(&format!("\n{}\n", tl("Voice")));
        match voice {
            VoiceFacts::Device { name, detail } => {
                push_row(&mut out, tl("microphone"), &format!("{name} ({detail})"));
            }
            VoiceFacts::Missing { .. } => {
                push_row(&mut out, tl("microphone"), tl("none detected"));
            }
        }
    }

    format_findings(report, &mut out);
    out
}

fn format_findings(report: &DiagnosticReport, out: &mut String) {
    let issues = report
        .findings
        .iter()
        .filter(|finding| finding.disposition == FindingDisposition::Issue)
        .collect::<Vec<_>>();
    if issues.is_empty() {
        if report.issue_count() == 0 {
            out.push_str(&format!("\n{}\n", tl("No issues found.")));
        } else {
            out.push_str(&format!(
                "\n{}\n",
                tl("An issue is shown in the Clipboard status above.")
            ));
        }
    } else {
        out.push_str(&format!(
            "\n{}\n",
            tlf("Issues ({count})", &[("count", &issues.len())])
        ));
        for finding in issues {
            format_finding(out, finding);
        }
    }

    let recommendations = report
        .findings
        .iter()
        .filter(|finding| finding.disposition == FindingDisposition::Recommendation)
        .collect::<Vec<_>>();
    if !recommendations.is_empty() {
        out.push_str(&format!("\n{}\n", tl("Recommendations")));
        for finding in recommendations {
            format_finding(out, finding);
        }
    }
}

/// A finding keeps its summary and note in English, because `crok doctor --json` prints them as
/// they are stored; they are looked up here, where they are shown.
fn format_finding(out: &mut String, finding: &super::DiagnosticFinding) {
    let marker = match finding.disposition {
        FindingDisposition::Issue => "!",
        FindingDisposition::Recommendation => "i",
    };
    out.push_str(&format!(
        "\n  {marker} {}  {}\n",
        finding.id,
        tl(&finding.message)
    ));
    if let Some(automatic) = finding.automatic_remediation {
        let command = super::human_fix_command(automatic.fix_id)
            .unwrap_or_else(|| automatic.command.to_owned());
        out.push_str(&format!(
            "      {}\n",
            tlf("Automatic setup: `{command}`", &[("command", &command)])
        ));
    }
    if let Some(remediation) = &finding.remediation {
        match (&remediation.config_path, &finding.automatic_remediation) {
            (Some(path), _) => {
                out.push_str(&format!(
                    "      {}\n",
                    tlf(
                        "Add `{fix}` to {path}",
                        &[("fix", &remediation.fix), ("path", path)]
                    )
                ));
            }
            (None, Some(_)) => {
                out.push_str(&format!(
                    "      {}\n",
                    tlf("One-off: `{fix}`", &[("fix", &remediation.fix)])
                ));
            }
            (None, None) => {
                out.push_str(&format!(
                    "      {}\n",
                    tlf("Run: `{fix}`", &[("fix", &remediation.fix)])
                ));
            }
        }
    }
    if let Some(note) = &finding.note {
        out.push_str(&format!(
            "      {}\n",
            tlf("Note: {note}", &[("note", &tl(note))])
        ));
    }
}

#[cfg(test)]
#[path = "doctor_format_tests.rs"]
mod tests;
