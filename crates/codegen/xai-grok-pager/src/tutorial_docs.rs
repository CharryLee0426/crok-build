//! Onboarding tutorial content (embedded markdown).
//!
//! Short, curated topics shown by the `/tutorial` overlay (strictly opt-in; nothing auto-shows).
//! Deliberately separate from [`crate::docs`] (the full how-to guides): these pages are bite-size intros that point at the guides for depth.

/// A compile-time tutorial topic. All fields are `&'static str`.
/// `title` and `blurb` are English, marked for translation; the overlay looks them up where it draws them.
#[derive(Debug)]
pub struct TutorialTopic {
    /// Row title in the topic list.
    pub title: &'static str,
    /// Short right-column blurb in the topic list.
    pub blurb: &'static str,
    /// Embedded markdown page content.
    pub content: &'static str,
    /// Title of the primary how-to guide this page's "Go deeper" points at (must match a [`crate::docs`] title); `d` opens it in the overlay.
    pub go_deeper: Option<&'static str>,
}

macro_rules! topic {
    ($file:literal, $title:expr, $blurb:expr, $go_deeper:expr) => {
        TutorialTopic {
            title: $title,
            blurb: $blurb,
            content: include_str!(concat!("../docs/tutorial/", $file)),
            go_deeper: $go_deeper,
        }
    };
}

/// The tutorial topics, in display order, as a linear flow (the topic screen's `→` advances through them).
/// The flow: what carries over from other tools, send a prompt, feed it context, learn the screen, then the bigger features.
pub static TUTORIAL_TOPICS: &[TutorialTopic] = &[
    topic!(
        "01-coming-from-another-tool.md",
        xai_grok_i18n::tlm("Coming from Claude, Cursor, or Codex?"),
        xai_grok_i18n::tlm("your settings, rules & skills carry over"),
        Some("Project Rules (AGENTS.md)")
    ),
    topic!(
        "02-first-prompt.md",
        xai_grok_i18n::tlm("Your First Prompt"),
        xai_grok_i18n::tlm("send, queue, cancel"),
        Some("Getting Started")
    ),
    topic!(
        "03-attach-and-paste.md",
        xai_grok_i18n::tlm("Attach Files, Images & Paste"),
        xai_grok_i18n::tlm("@files, line ranges, screenshots"),
        Some("Getting Started")
    ),
    topic!(
        "04-navigation.md",
        xai_grok_i18n::tlm("Finding Your Way Around"),
        xai_grok_i18n::tlm("focus, scrollback, panes"),
        Some("Keyboard Shortcuts")
    ),
    topic!(
        "05-slash-commands.md",
        xai_grok_i18n::tlm("Slash Commands"),
        xai_grok_i18n::tlm("/help  /model  /resume  and Ctrl+P"),
        Some("Slash Commands")
    ),
    topic!(
        "06-worktrees.md",
        xai_grok_i18n::tlm("Parallel Work: Worktrees"),
        xai_grok_i18n::tlm("isolated sessions on one repo"),
        Some("Session Management")
    ),
    topic!(
        "07-plan-and-permissions.md",
        xai_grok_i18n::tlm("Plan Mode & Permissions"),
        xai_grok_i18n::tlm("review the approach before it acts"),
        Some("Plan Mode")
    ),
    topic!(
        "08-make-it-yours.md",
        xai_grok_i18n::tlm("Make It Yours"),
        xai_grok_i18n::tlm("just ask: AGENTS.md, memory, themes"),
        Some("Project Rules (AGENTS.md)")
    ),
    topic!(
        "09-where-next.md",
        xai_grok_i18n::tlm("Where to Go Next"),
        xai_grok_i18n::tlm("guides, feedback, and good habits"),
        None
    ),
];

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn topics_are_valid() {
        for t in TUTORIAL_TOPICS {
            assert!(!t.title.is_empty(), "topic has empty title");
            assert!(!t.blurb.is_empty(), "topic {} has empty blurb", t.title);
            assert!(!t.content.is_empty(), "topic {} is empty", t.title);
            assert!(
                t.content.starts_with('#'),
                "topic {} should start with a markdown header",
                t.title
            );
        }
    }

    #[test]
    fn go_deeper_titles_resolve_to_real_guides() {
        // `d` on a topic page opens this guide; a typo'd title would turn the shortcut into a silent no-op
        for t in TUTORIAL_TOPICS {
            if let Some(title) = t.go_deeper {
                assert!(
                    crate::docs::find_doc(title).is_some(),
                    "topic {}: go_deeper {title:?} matches no how-to guide",
                    t.title
                );
            }
        }
    }

    #[test]
    fn topics_have_unique_titles() {
        let mut seen = std::collections::HashSet::new();
        for t in TUTORIAL_TOPICS {
            assert!(seen.insert(t.title), "duplicate topic title: {}", t.title);
        }
    }

    #[test]
    fn topics_stay_bite_size() {
        // The tutorial promises quick reads; keep each page short
        // Bump this limit only after re-checking a page still reads in under a minute
        for t in TUTORIAL_TOPICS {
            let lines = t.content.lines().count();
            assert!(
                lines <= 50,
                "topic {} is {} lines; keep tutorial pages bite-size (≤50)",
                t.title,
                lines
            );
        }
    }
}
