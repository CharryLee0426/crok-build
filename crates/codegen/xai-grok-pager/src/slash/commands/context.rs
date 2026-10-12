//! `/context`: show detailed context usage (instant, not queued).

use crate::app::actions::Action;
use crate::slash::command::{CommandExecCtx, CommandResult, SlashCommand, slash_meta};
use xai_grok_i18n::{tl, tlm};

/// Show context usage breakdown (progress bar, token categories, stats).
pub struct ContextCommand;

impl SlashCommand for ContextCommand {
    slash_meta! {
        name: "context",
        description: tlm("View context usage"),
        usage: "/context",
        session_scoped: true,
    }

    fn run(&self, ctx: &mut CommandExecCtx, _args: &str) -> CommandResult {
        if ctx.session_id.is_none() {
            return CommandResult::Error(tl("No active session").to_string());
        }

        CommandResult::Action(Action::ShowContextInfo)
    }
}
