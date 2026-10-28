//! The one-line feedback question under a finished turn, and the three choices it offers.

use ratatui::layout::Rect;

use super::{AgentView, QuickFeedbackPrompt};

/// What the user picked on the feedback question.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum QuickFeedbackChoice {
    Good,
    NotSoWell,
    DontShowAgain,
}

impl QuickFeedbackChoice {
    /// The thumbs value sent to the shell; `None` for "don't show again", which sends nothing.
    pub(crate) fn rating(self) -> Option<i8> {
        match self {
            Self::Good => Some(1),
            Self::NotSoWell => Some(-1),
            Self::DontShowAgain => None,
        }
    }

    /// The command shown on the choice, also the slash command that picks it.
    pub(crate) fn command(self) -> &'static str {
        match self {
            Self::Good => "/good",
            Self::NotSoWell => "/not-so-well",
            Self::DontShowAgain => "/dont-show-again",
        }
    }

    /// The three choices, in the order they are drawn and indexed.
    pub(crate) const ALL: [Self; 3] = [Self::Good, Self::NotSoWell, Self::DontShowAgain];
}

impl AgentView {
    /// Shows the feedback question for the turn that just finished.
    pub(crate) fn arm_quick_feedback(&mut self) {
        let turn_index = self.scrollback.turn_count().saturating_sub(1) as u64;
        self.quick_feedback = Some(QuickFeedbackPrompt { turn_index });
        self.quick_feedback_chips.clear();
        self.hovered_quick_feedback_chip = None;
    }

    /// Takes the question down: answered, dismissed, or superseded by the next turn.
    pub(crate) fn clear_quick_feedback(&mut self) {
        self.quick_feedback = None;
        self.quick_feedback_chips.clear();
        self.hovered_quick_feedback_chip = None;
    }

    /// The choice under a screen position.
    pub(crate) fn quick_feedback_chip_at(&self, col: u16, row: u16) -> Option<usize> {
        self.quick_feedback_chips
            .iter()
            .position(|rect| rect.contains((col, row).into()))
    }

    /// Updates the hover highlight; returns whether it changed.
    pub(crate) fn set_hovered_quick_feedback_chip(&mut self, index: Option<usize>) -> bool {
        if self.hovered_quick_feedback_chip == index {
            return false;
        }
        self.hovered_quick_feedback_chip = index;
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::scrollback::block::RenderBlock;

    fn view_with_prompts(count: usize) -> AgentView {
        let mut view = crate::app::agent_view::test_agent_view(
            Some("s1"),
            std::path::PathBuf::from("/tmp"),
        );
        for index in 0..count {
            view.scrollback
                .push_block(RenderBlock::user_prompt(format!("prompt {index}")));
        }
        view
    }

    #[test]
    fn arm_names_the_turn_that_just_finished() {
        let mut view = view_with_prompts(2);
        view.arm_quick_feedback();
        assert_eq!(
            view.quick_feedback.as_ref().map(|p| p.turn_index),
            Some(1),
            "the second prompt is turn index 1"
        );
        view.clear_quick_feedback();
        assert!(view.quick_feedback.is_none());
    }

    #[test]
    fn a_chip_hit_names_its_choice() {
        let mut view = view_with_prompts(1);
        view.arm_quick_feedback();
        view.quick_feedback_chips = vec![
            Rect::new(0, 0, 7, 1),
            Rect::new(8, 0, 14, 1),
            Rect::new(23, 0, 17, 1),
        ];
        assert_eq!(view.quick_feedback_chip_at(1, 0), Some(0));
        assert_eq!(view.quick_feedback_chip_at(9, 0), Some(1));
        assert_eq!(view.quick_feedback_chip_at(24, 0), Some(2));
        assert_eq!(view.quick_feedback_chip_at(100, 0), None);
    }
}
