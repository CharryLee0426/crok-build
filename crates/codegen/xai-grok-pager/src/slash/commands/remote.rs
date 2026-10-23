//! `/remote`: remote control from the TUI. Signed in, no argument (or `open`) opens the Remote panel: the person's
//! other computers with their projects and sessions, to open one or start one there; signed out it says how to sign in.
//! `status` shows the status text; `login` signs this computer in to the built-in relay (a code to approve on the web or
//! from the Crok app), `logout` signs it out, `on` / `off` turn sharing on or off, `new` starts a session on another of
//! the person's computers (with no argument, the panel opens at the project list).

use crate::app::actions::Action;
use crate::slash::command::{CommandExecCtx, CommandResult, SlashCommand, slash_meta};
use xai_grok_i18n::{tl, tlm};

const USAGE_ERROR: &str = tlm(
    "Use /remote, /remote open, /remote status, /remote login, /remote logout, /remote on, /remote off or /remote new",
);

pub struct RemoteCommand;

/// This computer is signed in to remote control.
fn signed_in() -> bool {
    matches!(crok_remote::credentials::load(), Ok(Some(_)))
}

/// The panel, or the sign-in hint while signed out.
fn open_panel(at_projects: bool) -> CommandResult {
    if signed_in() {
        CommandResult::Action(Action::ShowRemotePanel { at_projects })
    } else {
        CommandResult::Message(crate::remote_cmd::status_text())
    }
}

impl SlashCommand for RemoteCommand {
    slash_meta! {
        name: "remote",
        description: tlm("Remote control: follow and steer this computer's sessions from your phone or the web"),
        usage: "/remote [open|status|login|logout|on|off|new [project] [prompt]]",
        arg_placeholder: tlm("open/status/login/logout/on/off/new"),
    }

    fn run(&self, _ctx: &mut CommandExecCtx, args: &str) -> CommandResult {
        let mut words = args.split_whitespace();
        let verb = words.next().map(str::to_ascii_lowercase);
        match verb.as_deref() {
            None | Some("open") => open_panel(false),
            Some("status") => CommandResult::Message(crate::remote_cmd::status_text()),
            Some("login" | "signin" | "sign-in") => CommandResult::Action(Action::RemoteLogin),
            Some("logout" | "signout" | "sign-out") => CommandResult::Action(Action::RemoteLogout),
            Some("new") => {
                let rest = args.trim_start();
                let rest = rest.get(3..).unwrap_or("").trim().to_string();
                if rest.is_empty() && signed_in() {
                    return CommandResult::Action(Action::ShowRemotePanel { at_projects: true });
                }
                CommandResult::Action(Action::RemoteNew(rest))
            }
            Some(word @ ("on" | "off")) => match crate::remote_cmd::set_enabled(word == "on") {
                Ok(text) => CommandResult::Message(text),
                Err(error) => CommandResult::Error(error),
            },
            _ => CommandResult::Error(tl(USAGE_ERROR).to_owned()),
        }
    }
}
