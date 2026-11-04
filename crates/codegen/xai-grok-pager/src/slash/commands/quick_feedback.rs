//! `/good`, `/not-so-well`, `/dont-show-again`: answer the quick feedback question under the
//! latest reply.

use crate::app::actions::Action;
use crate::slash::command::{CommandExecCtx, CommandResult, SlashCommand, slash_meta};
use xai_grok_i18n::tlm;

fn answer(choice: crate::app::agent_view::QuickFeedbackChoice) -> CommandResult {
    CommandResult::Action(Action::QuickFeedback(choice))
}

pub struct GoodCommand;

impl SlashCommand for GoodCommand {
    slash_meta! {
        name: "good",
        description: tlm("Rate the latest reply as helpful"),
        usage: "/good",
    }

    fn run(&self, _ctx: &mut CommandExecCtx, _args: &str) -> CommandResult {
        answer(crate::app::agent_view::QuickFeedbackChoice::Good)
    }
}

pub struct NotSoWellCommand;

impl SlashCommand for NotSoWellCommand {
    slash_meta! {
        name: "not-so-well",
        aliases: ["bad", "not_so_well"],
        description: tlm("Rate the latest reply as not helpful"),
        usage: "/not-so-well",
    }

    fn run(&self, _ctx: &mut CommandExecCtx, _args: &str) -> CommandResult {
        answer(crate::app::agent_view::QuickFeedbackChoice::NotSoWell)
    }
}

pub struct DontShowAgainCommand;

impl SlashCommand for DontShowAgainCommand {
    slash_meta! {
        name: "dont-show-again",
        aliases: ["dont_show_again", "no-feedback"],
        description: tlm("Stop asking for feedback after replies"),
        usage: "/dont-show-again",
    }

    fn run(&self, _ctx: &mut CommandExecCtx, _args: &str) -> CommandResult {
        answer(crate::app::agent_view::QuickFeedbackChoice::DontShowAgain)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::acp::model_state::ModelState;
    use crate::app::agent_view::QuickFeedbackChoice;

    fn make_ctx(models: &ModelState) -> CommandExecCtx<'_> {
        let bundle = Box::leak(Box::new(crate::app::bundle::BundleState::default()));
        CommandExecCtx {
            models,
            session_id: None,
            bundle_state: bundle,
            screen_mode: crate::app::ScreenMode::Inline,
            billing_surface_visible: true,
            usage_command_visible: true,
            pager_state: crate::settings::PagerLocalSnapshot::default(),
        }
    }

    #[test]
    fn each_command_picks_its_choice() {
        let models = ModelState::default();
        let mut ctx = make_ctx(&models);
        let cases: [(&dyn SlashCommand, QuickFeedbackChoice); 3] = [
            (&GoodCommand, QuickFeedbackChoice::Good),
            (&NotSoWellCommand, QuickFeedbackChoice::NotSoWell),
            (&DontShowAgainCommand, QuickFeedbackChoice::DontShowAgain),
        ];
        for (command, choice) in cases {
            match command.run(&mut ctx, "") {
                CommandResult::Action(Action::QuickFeedback(got)) => assert_eq!(got, choice),
                other => panic!("{} must answer the question, got {other:?}", command.name()),
            }
        }
    }
}
