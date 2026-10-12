//! `/config-agents`: open the agents modal.

use crate::app::actions::Action;
use crate::slash::command::{CommandExecCtx, CommandResult, SlashCommand, slash_meta};
use xai_grok_i18n::tlm;

/// Open the agents modal listing all agent definitions.
pub struct ConfigAgentsCommand;

impl SlashCommand for ConfigAgentsCommand {
    slash_meta! {
        name: "config-agents",
        aliases: ["agents"],
        description: tlm("Manage agent definitions"),
        usage: "/config-agents",
    }

    fn run(&self, _ctx: &mut CommandExecCtx, _args: &str) -> CommandResult {
        CommandResult::Action(Action::OpenConfigAgentsModal(None))
    }
}
