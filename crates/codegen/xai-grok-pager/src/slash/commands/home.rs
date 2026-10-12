//! `/home`: exit the current session and return to the welcome screen.

use crate::app::actions::Action;
use crate::slash::command::{CommandExecCtx, CommandResult, SlashCommand, slash_meta};
use xai_grok_i18n::tlm;

pub struct HomeCommand;

impl SlashCommand for HomeCommand {
    slash_meta! {
        name: "home",
        aliases: ["welcome"],
        description: tlm("Return to the welcome screen"),
        usage: "/home",
    }

    fn run(&self, _ctx: &mut CommandExecCtx, _args: &str) -> CommandResult {
        CommandResult::Action(Action::ExitSession)
    }
}
