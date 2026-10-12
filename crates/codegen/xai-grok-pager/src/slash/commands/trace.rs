//! `/trace`: explore this session's recorded trace without leaving the TUI.
//!
//! Opens the same explorer as `grok trace view` over the conversation: the recorded
//! transcript on per-type timeline lanes, with tool I/O, raw records, and session files.
//! It reads a snapshot of the session directory; `r` in the explorer takes a new one.

use crate::app::actions::Action;
use crate::slash::command::{CommandExecCtx, CommandResult, SlashCommand, slash_meta};
use crate::slash::{ModeSupport, Remedy};
use xai_grok_i18n::{tl, tlm};

/// Open the trace explorer for the current session.
pub struct TraceCommand;

impl SlashCommand for TraceCommand {
    slash_meta! {
        name: "trace",
        description: tlm("Explore this session's trace: timeline, transcript, and tool I/O"),
        usage: "/trace",
        session_scoped: true,
        mode_support: ModeSupport::FullscreenOnly(Remedy::SwitchMode {
            why: tlm("the trace explorer needs the full screen"),
        }),
    }

    fn run(&self, ctx: &mut CommandExecCtx, _args: &str) -> CommandResult {
        if ctx.session_id.is_none() {
            return CommandResult::Error(tl("No active session to trace").to_string());
        }
        CommandResult::Action(Action::ShowTrace)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::acp::model_state::ModelState;
    use crate::app::bundle::BundleState;
    use crate::settings::PagerLocalSnapshot;

    static DEFAULT_BUNDLE_STATE: BundleState = BundleState {
        has_cache: false,
        version: String::new(),
        personas: Vec::new(),
        roles: Vec::new(),
        agents: Vec::new(),
        skills: Vec::new(),
        persona_details: Vec::new(),
        role_details: Vec::new(),
    };

    fn run(session_id: Option<&agent_client_protocol::SessionId>) -> CommandResult {
        let models = ModelState::default();
        let mut ctx = CommandExecCtx {
            models: &models,
            session_id,
            bundle_state: &DEFAULT_BUNDLE_STATE,
            screen_mode: crate::app::ScreenMode::Fullscreen,
            billing_surface_visible: true,
            usage_command_visible: true,
            pager_state: PagerLocalSnapshot::default(),
        };
        TraceCommand.run(&mut ctx, "")
    }

    #[test]
    fn no_session_errors() {
        match run(None) {
            CommandResult::Error(msg) => assert!(msg.contains("No active session")),
            other => panic!("expected Error, got {other:?}"),
        }
    }

    #[test]
    fn with_session_opens_the_trace() {
        let sid = agent_client_protocol::SessionId::from("s1".to_string());
        assert!(matches!(
            run(Some(&sid)),
            CommandResult::Action(Action::ShowTrace)
        ));
    }
}
