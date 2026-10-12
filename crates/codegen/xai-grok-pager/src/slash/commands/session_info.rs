//! `/session-info`: show current session info (instant, not queued).

use crate::app::actions::Action;
use crate::slash::command::{CommandExecCtx, CommandResult, SlashCommand, slash_meta};
use xai_grok_i18n::{tl, tlm};

/// Show session info (session ID, cwd, model, context usage).
pub struct SessionInfoCommand;

impl SlashCommand for SessionInfoCommand {
    slash_meta! {
        name: "session-info",
        description: tlm("Show session info"),
        usage: "/session-info",
        session_scoped: true,
    }

    fn run(&self, ctx: &mut CommandExecCtx, _args: &str) -> CommandResult {
        if ctx.session_id.is_none() {
            return CommandResult::Error(tl("No active session").to_string());
        }

        CommandResult::Action(Action::ShowSessionInfo)
    }
}
