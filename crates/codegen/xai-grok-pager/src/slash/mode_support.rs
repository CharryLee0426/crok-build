use crate::app::ScreenMode;
use xai_grok_i18n::{tl, tlf, tlm};

/// What to tell a user who typed a command the current mode cannot run.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Remedy {
    SwitchMode {
        /// Sentence fragment, parenthesized in the refusal: `"minimal is single-session"`.
        why: &'static str,
    },
    /// Imperative clause naming what to do in this mode instead.
    /// Name arrows, `Tab`, or `Ctrl+<letter>`.
    /// `Ctrl+G` is the external editor in minimal and the tasks pane everywhere else, and a bare letter resolves only under vim mode (off by default).
    UseInstead(&'static str),
    AlreadyInMode,
}

/// Which render modes a slash command functions in.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ModeSupport {
    Both,
    FullscreenOnly(Remedy),
    MinimalOnly(Remedy),
}

impl ModeSupport {
    pub(crate) fn supports(self, mode: ScreenMode) -> bool {
        match self {
            Self::Both => true,
            Self::FullscreenOnly(_) => !mode.is_minimal(),
            Self::MinimalOnly(_) => mode.is_minimal(),
        }
    }

    pub(crate) fn refusal(self, token: &str, mode: ScreenMode) -> Option<String> {
        if self.supports(mode) {
            return None;
        }
        let (remedy, current, switch) = match self {
            Self::Both => return None,
            Self::FullscreenOnly(remedy) => (remedy, tlm("minimal"), "/fullscreen"),
            Self::MinimalOnly(remedy) => (remedy, tlm("fullscreen"), "/minimal"),
        };
        let current = tl(current);
        Some(match remedy {
            Remedy::SwitchMode { why } => tlf(
                "/{command} isn't available in {mode} mode ({why}). Run {switch} to switch this session.",
                &[
                    ("command", &token),
                    ("mode", &current),
                    ("why", &tl(why)),
                    ("switch", &switch),
                ],
            ),
            Remedy::UseInstead(instead) => tlf(
                "/{command} isn't available in {mode} mode: {instead}.",
                &[
                    ("command", &token),
                    ("mode", &current),
                    ("instead", &tl(instead)),
                ],
            ),
            Remedy::AlreadyInMode => tlf("You're already in {mode} mode.", &[("mode", &current)]),
        })
    }
}

#[cfg(test)]
#[path = "mode_support_tests.rs"]
mod tests;
