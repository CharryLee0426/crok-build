//! `/view-plan`: open the current saved plan preview.

use crate::app::actions::Action;
use crate::slash::command::{CommandExecCtx, CommandResult, SlashCommand, slash_meta};
use xai_grok_i18n::tlm;

/// Open the current session plan preview.
pub struct ViewPlanCommand;

impl SlashCommand for ViewPlanCommand {
    slash_meta! {
        name: "view-plan",
        aliases: ["show-plan", "plan-view"],
        description: tlm("View the current plan"),
        usage: "/view-plan",
        session_scoped: true,
    }

    fn run(&self, _ctx: &mut CommandExecCtx, _args: &str) -> CommandResult {
        CommandResult::Action(Action::ShowPlan)
    }
}
