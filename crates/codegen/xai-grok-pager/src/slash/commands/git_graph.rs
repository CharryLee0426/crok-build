//! `/git-graph`: browse the repository's commit graph without leaving the TUI.
//!
//! Opens a full-screen, read-only view of the history around the session's working directory:
//! every branch in its own coloured lane, merges and forks joined with rounded lines, and the
//! selected commit's message and changed files beside it.

use crate::app::actions::Action;
use crate::slash::command::{CommandExecCtx, CommandResult, SlashCommand, slash_meta};
use crate::slash::{ModeSupport, Remedy};

/// Open the commit graph for the current session's repository.
pub struct GitGraphCommand;

impl SlashCommand for GitGraphCommand {
    slash_meta! {
        name: "git-graph",
        aliases: ["graph", "gitgraph"],
        description: "Browse the commit graph: branches, merges, and history",
        usage: "/git-graph",
        mode_support: ModeSupport::FullscreenOnly(Remedy::SwitchMode {
            why: "the git graph needs the full screen",
        }),
    }

    fn run(&self, _ctx: &mut CommandExecCtx, _args: &str) -> CommandResult {
        CommandResult::Action(Action::ShowGitGraph)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::slash::commands::builtin_commands;
    use crate::slash::registry::CommandRegistry;

    #[test]
    fn registered_with_its_aliases() {
        let registry = CommandRegistry::new(builtin_commands());
        for name in ["git-graph", "graph", "gitgraph"] {
            let command = registry
                .get(name)
                .unwrap_or_else(|| panic!("/{name} is registered"));
            assert_eq!(command.name(), "git-graph");
        }
    }

    #[test]
    fn opens_the_graph() {
        let models = crate::acp::model_state::ModelState::default();
        let bundle = crate::app::bundle::BundleState {
            has_cache: false,
            version: String::new(),
            personas: Vec::new(),
            roles: Vec::new(),
            agents: Vec::new(),
            skills: Vec::new(),
            persona_details: Vec::new(),
            role_details: Vec::new(),
        };
        let mut ctx = CommandExecCtx {
            models: &models,
            session_id: None,
            bundle_state: &bundle,
            screen_mode: crate::app::ScreenMode::Fullscreen,
            billing_surface_visible: true,
            usage_command_visible: true,
            pager_state: crate::settings::PagerLocalSnapshot::default(),
        };
        assert!(matches!(
            GitGraphCommand.run(&mut ctx, ""),
            CommandResult::Action(Action::ShowGitGraph)
        ));
    }
}
