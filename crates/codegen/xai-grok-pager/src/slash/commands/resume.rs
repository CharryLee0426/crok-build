//! `/resume`: open the session picker overlay to resume a previous session.

use crate::app::actions::Action;
use crate::slash::command::{CommandExecCtx, CommandResult, SlashCommand, slash_meta};
use xai_grok_i18n::tlm;

pub struct ResumeCommand;

impl SlashCommand for ResumeCommand {
    slash_meta! {
        name: "resume",
        description: tlm("Resume a previous session"),
        usage: "/resume",
    }

    fn run(&self, _ctx: &mut CommandExecCtx, _args: &str) -> CommandResult {
        CommandResult::Action(Action::ShowSessionPicker)
    }
}
