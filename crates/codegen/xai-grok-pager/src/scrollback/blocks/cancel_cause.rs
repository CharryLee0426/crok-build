//! Maps `_meta.cancelTrigger` / `_meta.cancellationCategory` onto cancel-banner copy.
//! Policy categories win; unknown or missing meta is unnamed, never "by user".

use xai_grok_i18n::{tl, tlf};
use xai_grok_shell::session::commands::{
    CancelTrigger, HOOK_DENIED_CATEGORY, MAX_TURNS_REACHED_CATEGORY, PERMISSION_CANCELLED_CATEGORY,
    PERMISSION_REJECTED_CATEGORY,
};

/// Who or what cancelled the turn, for the scrollback banner.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CancelledBy {
    User,
    SessionClosed,
    Shutdown,
    MaxTurns,
    PermissionDenied,
    PermissionDismissed,
    HostInterrupt,
    Unspecified,
}

impl CancelledBy {
    /// `category` first (permission / max-turns / hook), then the wire trigger.
    pub fn from_meta(trigger: Option<&str>, category: Option<&str>) -> Self {
        match category {
            Some(c) if c == PERMISSION_REJECTED_CATEGORY => return Self::PermissionDenied,
            Some(c) if c == PERMISSION_CANCELLED_CATEGORY => return Self::PermissionDismissed,
            Some(c) if c == MAX_TURNS_REACHED_CATEGORY => return Self::MaxTurns,
            Some(c) if c == HOOK_DENIED_CATEGORY => return Self::Unspecified,
            _ => {}
        }
        match trigger {
            Some(t) if CancelTrigger::is_user_gesture_name(t) => Self::User,
            Some("session_close" | "session_delete") => Self::SessionClosed,
            Some("shutdown") => Self::Shutdown,
            Some("host_interrupt") => Self::HostInterrupt,
            _ => Self::Unspecified,
        }
    }

    pub fn phrase(self) -> &'static str {
        match self {
            Self::User => "Turn cancelled by user",
            Self::SessionClosed => "Turn cancelled because the session closed",
            Self::Shutdown => "Turn cancelled because the session shut down",
            Self::MaxTurns => "Turn cancelled after reaching the turn limit",
            Self::PermissionDenied => "Turn cancelled because a permission was denied",
            Self::PermissionDismissed => "Turn cancelled because a permission prompt was dismissed",
            Self::HostInterrupt => "Turn cancelled by the agent host",
            Self::Unspecified => "Turn cancelled",
        }
    }

    /// The cancel banner in the interface language: `phrase()` with the elapsed time when it is known,
    /// and the full stop. One whole sentence per cause, so each language orders and punctuates it.
    pub fn banner(self, elapsed: Option<&str>) -> String {
        let Some(time) = elapsed else {
            return match self {
                Self::User => tl("Turn cancelled by user."),
                Self::SessionClosed => tl("Turn cancelled because the session closed."),
                Self::Shutdown => tl("Turn cancelled because the session shut down."),
                Self::MaxTurns => tl("Turn cancelled after reaching the turn limit."),
                Self::PermissionDenied => tl("Turn cancelled because a permission was denied."),
                Self::PermissionDismissed => {
                    tl("Turn cancelled because a permission prompt was dismissed.")
                }
                Self::HostInterrupt => tl("Turn cancelled by the agent host."),
                Self::Unspecified => tl("Turn cancelled."),
            }
            .to_string();
        };
        match self {
            Self::User => tlf("Turn cancelled by user in {time}.", &[("time", &time)]),
            Self::SessionClosed => tlf(
                "Turn cancelled because the session closed in {time}.",
                &[("time", &time)],
            ),
            Self::Shutdown => tlf(
                "Turn cancelled because the session shut down in {time}.",
                &[("time", &time)],
            ),
            Self::MaxTurns => tlf(
                "Turn cancelled after reaching the turn limit in {time}.",
                &[("time", &time)],
            ),
            Self::PermissionDenied => tlf(
                "Turn cancelled because a permission was denied in {time}.",
                &[("time", &time)],
            ),
            Self::PermissionDismissed => tlf(
                "Turn cancelled because a permission prompt was dismissed in {time}.",
                &[("time", &time)],
            ),
            Self::HostInterrupt => tlf(
                "Turn cancelled by the agent host in {time}.",
                &[("time", &time)],
            ),
            Self::Unspecified => tlf("Turn cancelled in {time}.", &[("time", &time)]),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn user_gestures_are_user() {
        for trigger in ["esc", "ctrl_c", "mouse", "dashboard_stop"] {
            assert_eq!(
                CancelledBy::from_meta(Some(trigger), None),
                CancelledBy::User,
                "{trigger}"
            );
        }
    }

    #[test]
    fn passive_triggers_are_named() {
        assert_eq!(
            CancelledBy::from_meta(Some("session_close"), None),
            CancelledBy::SessionClosed
        );
        assert_eq!(
            CancelledBy::from_meta(Some("session_delete"), None),
            CancelledBy::SessionClosed
        );
        assert_eq!(
            CancelledBy::from_meta(Some("shutdown"), None),
            CancelledBy::Shutdown
        );
        assert_eq!(
            CancelledBy::from_meta(Some("host_interrupt"), None),
            CancelledBy::HostInterrupt
        );
    }

    #[test]
    fn missing_or_unknown_is_unspecified() {
        for trigger in [None, Some("send_now"), Some("gateway_cancel"), Some("nope")] {
            assert_eq!(
                CancelledBy::from_meta(trigger, None),
                CancelledBy::Unspecified,
                "{trigger:?}"
            );
        }
        assert_eq!(
            CancelledBy::from_meta(Some("ctrl_c"), Some(HOOK_DENIED_CATEGORY)),
            CancelledBy::Unspecified
        );
        assert_eq!(
            CancelledBy::from_meta(None, Some("MidTurnAbort")),
            CancelledBy::Unspecified
        );
    }

    #[test]
    fn policy_category_beats_trigger() {
        assert_eq!(
            CancelledBy::from_meta(Some("ctrl_c"), Some(PERMISSION_REJECTED_CATEGORY)),
            CancelledBy::PermissionDenied
        );
        assert_eq!(
            CancelledBy::from_meta(Some("esc"), Some(PERMISSION_CANCELLED_CATEGORY)),
            CancelledBy::PermissionDismissed
        );
        assert_eq!(
            CancelledBy::from_meta(Some("mouse"), Some(MAX_TURNS_REACHED_CATEGORY)),
            CancelledBy::MaxTurns
        );
    }
}
