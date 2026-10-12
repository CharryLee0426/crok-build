//! `/compact` takes no arguments.
//! `run` returns `CommandResult::QueueCommand` so the dispatch layer enqueues it as `QueueEntryKind::Command`.

use crate::slash::command::{CommandExecCtx, CommandResult, SlashCommand, slash_meta};
use xai_grok_i18n::{tl, tlm};

const NO_ARGS: &str = tlm("/compact takes no arguments.");

/// Compact the conversation history.
pub struct CompactCommand;

impl SlashCommand for CompactCommand {
    slash_meta! {
        name: "compact",
        description: tlm("Compact conversation history"),
        usage: "/compact",
        session_scoped: true,
    }

    /// Refusing here, before the send path runs, also keeps an edited queue row in place
    /// (`EditedCommandGate` pre-checks this hook).
    fn submission_refusal(&self, args: &str, _voice_owns_prompt: bool) -> Option<&'static str> {
        (!args.trim().is_empty()).then_some(tl(NO_ARGS))
    }

    fn run(&self, _ctx: &mut CommandExecCtx, args: &str) -> CommandResult {
        if args.trim().is_empty() {
            CommandResult::QueueCommand("/compact".to_string())
        } else {
            CommandResult::Error(tl(NO_ARGS).to_string())
        }
    }
}
