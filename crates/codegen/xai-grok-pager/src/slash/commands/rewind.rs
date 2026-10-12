use crate::app::actions::Action;
use crate::slash::command::{CommandExecCtx, CommandResult, SlashCommand, slash_meta};
use xai_grok_i18n::tlm;

pub struct RewindCommand;

impl SlashCommand for RewindCommand {
    slash_meta! {
        name: "rewind",
        aliases: ["undo"],
        description: tlm("Rewind to a previous turn"),
        usage: "/rewind",
        session_scoped: true,
    }

    fn run(&self, _ctx: &mut CommandExecCtx, _args: &str) -> CommandResult {
        CommandResult::Action(Action::RewindShowPicker)
    }
}
