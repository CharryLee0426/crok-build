//! `/browser-use`, `/computer-use` and `/phone-use`: turn the `browser`, `computer` and `phone` tools on or off.
//!
//! Each saves its `[features]` key (`browser_use`, `computer_use`, `phone_use`) through `Action::SetDeviceFeature`; with no argument
//! the command turns the feature to the opposite of what applies now. Agents latch the key when built, so the change
//! applies to new sessions, as the toast says.

use crate::app::actions::Action;
use crate::slash::command::{CommandExecCtx, CommandResult, SlashCommand, slash_meta};
use xai_grok_i18n::{tl, tlm};
use xai_grok_shell::agent::config::Feature;

const USAGE_ERROR: &str = tlm("Use on or off, or no argument to switch it");

/// `on` / `off` (and their synonyms), or `None` to switch.
fn parse(args: &str) -> Result<Option<bool>, ()> {
    match args.trim().to_ascii_lowercase().as_str() {
        "" | "toggle" => Ok(None),
        "on" | "true" | "yes" | "enable" | "enabled" => Ok(Some(true)),
        "off" | "false" | "no" | "disable" | "disabled" => Ok(Some(false)),
        _ => Err(()),
    }
}

fn run(feature: Feature, ctx: &CommandExecCtx, args: &str) -> CommandResult {
    let Ok(choice) = parse(args) else {
        return CommandResult::Error(tl(USAGE_ERROR).to_owned());
    };
    let current = ctx
        .pager_state
        .device_features
        .get(feature)
        .map(|state| state.resolve().value)
        .unwrap_or(false);
    CommandResult::Action(Action::SetDeviceFeature(
        feature,
        choice.unwrap_or(!current),
    ))
}

pub struct BrowserUseCommand;

impl SlashCommand for BrowserUseCommand {
    slash_meta! {
        name: "browser-use",
        description: tlm("Turn browser use on or off: Crok works in web pages in a browser of its own"),
        usage: "/browser-use [on|off]",
        arg_placeholder: tlm("on/off"),
    }

    fn run(&self, ctx: &mut CommandExecCtx, args: &str) -> CommandResult {
        run(Feature::BrowserUse, ctx, args)
    }
}

pub struct ComputerUseCommand;

impl SlashCommand for ComputerUseCommand {
    slash_meta! {
        name: "computer-use",
        description: tlm("Turn computer use on or off: Crok sees the screen and uses the mouse and keyboard (macOS)"),
        usage: "/computer-use [on|off]",
        arg_placeholder: tlm("on/off"),
    }

    fn run(&self, ctx: &mut CommandExecCtx, args: &str) -> CommandResult {
        run(Feature::ComputerUse, ctx, args)
    }
}

pub struct PhoneUseCommand;

impl SlashCommand for PhoneUseCommand {
    slash_meta! {
        name: "phone-use",
        description: tlm("Turn phone use on or off: Crok uses your iPhone (through iPhone Mirroring) or Android phone (over adb)"),
        usage: "/phone-use [on|off]",
        arg_placeholder: tlm("on/off"),
    }

    fn run(&self, ctx: &mut CommandExecCtx, args: &str) -> CommandResult {
        run(Feature::PhoneUse, ctx, args)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::acp::model_state::ModelState;
    use crate::app::bundle::BundleState;
    use crate::settings::PagerLocalSnapshot;

    fn ctx<'a>(models: &'a ModelState, bundle: &'a BundleState) -> CommandExecCtx<'a> {
        CommandExecCtx {
            models,
            session_id: None,
            bundle_state: bundle,
            screen_mode: crate::app::ScreenMode::Inline,
            billing_surface_visible: true,
            usage_command_visible: true,
            pager_state: PagerLocalSnapshot::default(),
        }
    }

    #[test]
    fn no_argument_switches_and_on_off_set() {
        let (models, bundle) = (ModelState::default(), BundleState::default());
        let mut ctx = ctx(&models, &bundle);
        assert!(matches!(
            BrowserUseCommand.run(&mut ctx, ""),
            CommandResult::Action(Action::SetDeviceFeature(Feature::BrowserUse, true))
        ));
        assert!(matches!(
            ComputerUseCommand.run(&mut ctx, "off"),
            CommandResult::Action(Action::SetDeviceFeature(Feature::ComputerUse, false))
        ));
        assert!(matches!(
            BrowserUseCommand.run(&mut ctx, "maybe"),
            CommandResult::Error(_)
        ));
        // Phone use is on by default, so a bare command turns it off
        assert!(matches!(
            PhoneUseCommand.run(&mut ctx, ""),
            CommandResult::Action(Action::SetDeviceFeature(Feature::PhoneUse, false))
        ));
    }
}
