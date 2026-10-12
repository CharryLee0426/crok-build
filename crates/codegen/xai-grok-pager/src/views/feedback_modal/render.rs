//! Feedback modal layout and rendering.

use ratatui::buffer::Buffer;
use ratatui::layout::Rect;
use xai_grok_i18n::{tl, tlm};

use super::{
    CANCEL_SHORTCUT_ID, DraftSubmitTerminal, DraftsState, FEEDBACK_TABS, FeedbackModalRender,
    FeedbackModalState, FeedbackModalStep, FeedbackTab, FeedbackTraceChoice,
};
use crate::theme::Theme;
use crate::views::modal_window::{self, ModalSizing, ModalWindowConfig, Shortcut};
use crate::views::prompt_widget::PromptStyle;

/// The labels `xai_grok_feedback`'s taxonomy gives its choices. That crate words them; listing them
/// here keeps them in the catalog, and the rows look up `label()` as they draw it.
const _TAXONOMY_LABELS: &[&str] = &[
    tlm("Bug"),
    tlm("Idea"),
    tlm("Missing capability"),
    tlm("Code edit"),
    tlm("Debug"),
    tlm("Explain"),
    tlm("Plan"),
    tlm("Shell"),
    tlm("Search"),
    tlm("Review"),
    tlm("Other"),
    tlm("Doing the wrong amount of work"),
    tlm("Wrong outputs"),
    tlm("Style"),
    tlm("Overeager"),
    tlm("Stopping early"),
    tlm("Unwanted scope"),
    tlm("Didn't ask for help"),
    tlm("Excessive questions"),
    tlm("Subagent overspawn"),
    tlm("Over correction"),
    tlm("Instruction following"),
    tlm("Overconfidence and hallucination"),
    tlm("Code quality"),
    tlm("Destructive actions"),
    tlm("Context and memory"),
    tlm("Repetition and looping"),
    tlm("Model regression"),
    tlm("Dispute or decline"),
    tlm("Tone or preachiness"),
    tlm("Unclear output"),
];

/// One footer hint: the keys as they are written (empty when the hint is only words), the label
/// in English, whether a click activates it, and the id a click reports.
pub(super) type FooterHint = (&'static str, &'static str, bool, usize);

/// What each hint reads in the footer: `keys label`, the label in the interface language.
fn footer_hint_texts(hints: &[FooterHint]) -> Vec<String> {
    hints
        .iter()
        .map(|&(keys, label, ..)| {
            if keys.is_empty() {
                tl(label).to_owned()
            } else {
                format!("{keys} {}", tl(label))
            }
        })
        .collect()
}

/// The footer shortcuts for `hints`, each borrowing its text from `texts`.
fn footer_shortcuts<'a>(hints: &[FooterHint], texts: &'a [String]) -> Vec<Shortcut<'a>> {
    hints
        .iter()
        .zip(texts)
        .map(|(&(_, _, clickable, id), text)| Shortcut {
            label: text.as_str(),
            clickable,
            id,
        })
        .collect()
}

impl FeedbackModalState {
    pub fn render(
        &mut self,
        buf: &mut Buffer,
        area: Rect,
        theme: &Theme,
        compact: bool,
    ) -> Option<FeedbackModalRender> {
        self.window.active_tab = self.active_tab().index();
        if self.active_tab() == FeedbackTab::Drafts {
            return self.render_drafts(buf, area, theme, compact);
        }
        let trace_selected = match &self.step {
            FeedbackModalStep::Trace { selected, .. } => Some(*selected),
            _ => None,
        };
        // The order seeded at open; membership is identical to the payload's.
        let fields = self.field_order.clone();
        let hints: &[FooterHint] = match self.submit_terminal {
            Some(DraftSubmitTerminal::OutcomeUnknown) => Self::UNKNOWN_SUBMIT_SHORTCUTS,
            Some(DraftSubmitTerminal::CleanupFailed) => Self::TERMINAL_SUBMIT_SHORTCUTS,
            None if trace_selected.is_some() => Self::TRACE_SHORTCUTS,
            None if self.enum_picker.is_some() => Self::PICKER_SHORTCUTS,
            None if self.metadata_focus.is_some() => Self::METADATA_SHORTCUTS,
            None if fields.is_empty() => Self::WRITE_SHORTCUTS,
            None => Self::WRITE_SHORTCUTS_WITH_LABELS,
        };
        let hint_texts = footer_hint_texts(hints);
        let shortcuts = footer_shortcuts(hints, &hint_texts);
        let tabs = Self::tab_labels();
        let config = Self::window_config(&tabs, &shortcuts, compact, trace_selected.is_some());
        // Stale label rects must not keep catching clicks after a failed or label-less render.
        self.metadata_row_areas.clear();
        let areas = modal_window::render_modal_window(buf, area, &mut self.window, &config, theme)?;
        if let Some(selected) = trace_selected {
            self.render_trace_step(buf, areas.content, theme, selected);
            // The composer is hidden behind the question, so there is no caret to place.
            return Some(FeedbackModalRender {
                cursor: None,
                post_flush: None,
            });
        }
        let mut content = areas.content;
        // Reserve one full-width row per supplied enum, but only while the composer keeps at
        // least two rows; a too-small render drops the labels, never the draft.
        let label_rows = fields.len() as u16;
        if label_rows > 0 && content.height >= label_rows + 2 {
            self.render_metadata_rows(buf, content, areas.inner_x, theme, &fields);
            content.y += label_rows;
            content.height -= label_rows;
        } else {
            // No rows on screen (absent enums or a too-small render, e.g. after a resize):
            // nothing is focusable, and a lingering focus would only hide the caret.
            self.metadata_focus = None;
        }
        if self.enum_picker.is_some() {
            self.render_enum_picker(buf, content, areas.inner_x, areas.inner_width, theme);
            // The picker's search bar paints its own inverse-video cursor cell; no terminal caret.
            return Some(FeedbackModalRender {
                cursor: None,
                post_flush: None,
            });
        }
        let prompt_result =
            self.composer
                .draw(buf, content, Some(area), &Self::prompt_style(), None, None);
        if let Some(error) = self.error.as_deref()
            && areas.footer.height > 1
        {
            buf.set_string(
                areas.footer.x,
                areas.footer.y,
                tl(error),
                ratatui::style::Style::default().fg(theme.accent_error),
            );
        }
        Some(FeedbackModalRender {
            // The terminal caret is the composer-focus signal; a focused label row hides it.
            cursor: if self.metadata_focus.is_some() {
                None
            } else {
                prompt_result.cursor_pos
            },
            post_flush: prompt_result.post_flush_escapes.map(Into::into),
        })
    }

    fn render_drafts(
        &mut self,
        buf: &mut Buffer,
        area: Rect,
        theme: &Theme,
        compact: bool,
    ) -> Option<FeedbackModalRender> {
        let is_searching = matches!(
            self.drafts,
            DraftsState::Browse {
                search_focused: true,
                ..
            }
        );
        let move_label = format!("↑↓/j k {}", tl("move"));
        let search_label = format!("/ {}", tl("search"));
        let open_label = format!("Enter {}", tl("open"));
        let delete_label = format!("d {}", tl("delete"));
        let mut shortcuts = vec![
            Shortcut {
                label: &move_label,
                clickable: false,
                id: 0,
            },
            Shortcut {
                label: &search_label,
                clickable: false,
                id: 0,
            },
            Shortcut {
                label: &open_label,
                clickable: false,
                id: 0,
            },
            Shortcut {
                label: &delete_label,
                clickable: false,
                id: 0,
            },
        ];
        modal_window::push_vim_nav_search_hint(&mut shortcuts, is_searching);
        let tabs = Self::tab_labels();
        let config = Self::window_config(&tabs, &shortcuts, compact, false);
        let areas = modal_window::render_modal_window(buf, area, &mut self.window, &config, theme)?;
        let content = areas.content;
        self.draft_search_area = None;
        self.draft_row_areas.clear();
        let normal = ratatui::style::Style::default().fg(theme.text_secondary);
        let dim = ratatui::style::Style::default().fg(theme.gray);
        if self.discard_confirm.is_some() {
            buf.set_stringn(
                content.x,
                content.y,
                tl("Discard the current Write composition and open the selected draft?"),
                content.width as usize,
                normal,
            );
            buf.set_stringn(
                content.x,
                content.y.saturating_add(2),
                format!("y {}  |  n {}", tl("discard"), tl("cancel")),
                content.width as usize,
                dim,
            );
            return Some(FeedbackModalRender {
                cursor: None,
                post_flush: None,
            });
        }
        if let Some(draft_id) = self.delete_confirm.as_ref() {
            let prompt = if self.metadata.draft_id.as_ref() == Some(draft_id) {
                tl("Delete the stored recovery copy? Your current edits will remain.")
            } else {
                tl("Delete this feedback draft?")
            };
            buf.set_stringn(content.x, content.y, prompt, content.width as usize, normal);
            buf.set_stringn(
                content.x,
                content.y.saturating_add(2),
                if self.draft_delete.is_some() {
                    tl("Deleting…").to_owned()
                } else {
                    format!("y {}  |  n {}", tl("delete"), tl("cancel"))
                },
                content.width as usize,
                dim,
            );
            return Some(FeedbackModalRender {
                cursor: None,
                post_flush: None,
            });
        }
        if let DraftsState::Browse { error, .. } = &self.drafts {
            let header_rows = 2 + usize::from(error.is_some() || self.error.is_some());
            self.update_drafts_viewport((content.height as usize).saturating_sub(header_rows));
        }
        match &self.drafts {
            DraftsState::Unloaded => {
                buf.set_stringn(
                    content.x,
                    content.y,
                    tl("Open Drafts to load saved feedback."),
                    content.width as usize,
                    dim,
                );
            }
            DraftsState::Loading { .. } => {
                buf.set_stringn(
                    content.x,
                    content.y,
                    tl("Loading drafts…"),
                    content.width as usize,
                    dim,
                );
            }
            DraftsState::Browse {
                rows,
                selected_id,
                query,
                search_focused,
                error,
            } => {
                let mut y = content.y;
                if content.height > 0 {
                    self.draft_search_area = Some(Rect::new(content.x, y, content.width, 1));
                    crate::views::picker::render_line_editor_search_bar(
                        buf,
                        content.x,
                        y,
                        content.width,
                        theme,
                        query,
                        *search_focused,
                        true,
                        Some(theme.bg_base),
                    );
                    y = y.saturating_add(1);
                }
                if y < content.bottom() {
                    crate::views::picker::render_divider(
                        buf,
                        content.x,
                        y,
                        content.width,
                        theme,
                        Some(theme.bg_base),
                    );
                    y = y.saturating_add(1);
                }
                if let Some(error) = error.as_ref().or(self.error.as_ref())
                    && y < content.bottom()
                {
                    buf.set_stringn(
                        content.x,
                        y,
                        tl(error),
                        content.width as usize,
                        ratatui::style::Style::default().fg(theme.accent_error),
                    );
                    y = y.saturating_add(1);
                }
                let capacity = content.bottom().saturating_sub(y) as usize;
                let visible: Vec<_> = self.visible_drafts().into_iter().cloned().collect();
                let mut rendered = 0usize;
                for draft in visible
                    .into_iter()
                    .skip(self.drafts_viewport_start)
                    .take(capacity)
                {
                    let is_selected = selected_id.as_ref() == Some(&draft.id);
                    let marker = if is_selected { "❯" } else { " " };
                    let preview = draft
                        .details
                        .lines()
                        .find(|line| !line.trim().is_empty())
                        .unwrap_or(draft.title.as_str());
                    let failure = draft
                        .failure_mode
                        .map(|value| format!(" · {}", tl(value.label())))
                        .unwrap_or_default();
                    let r#type = draft
                        .r#type
                        .map_or(tl("Unclassified"), |value| tl(value.label()));
                    let task = draft
                        .task_category
                        .map_or(tl("Other"), |value| tl(value.label()));
                    let line = format!("{marker} {type} · {task}{failure} · {preview}");
                    let style = if is_selected {
                        ratatui::style::Style::default()
                            .fg(theme.text_primary)
                            .add_modifier(ratatui::style::Modifier::BOLD)
                    } else {
                        normal
                    };
                    buf.set_stringn(content.x, y, line, content.width as usize, style);
                    self.draft_row_areas
                        .push((draft.id.clone(), Rect::new(content.x, y, content.width, 1)));
                    y += 1;
                    rendered += 1;
                }
                if rendered == 0 && y < content.bottom() {
                    let empty = if rows.is_empty() {
                        tl("No drafts.")
                    } else {
                        tl("No matching drafts.")
                    };
                    buf.set_stringn(content.x, y, empty, content.width as usize, dim);
                }
            }
        }
        Some(FeedbackModalRender {
            cursor: None,
            post_flush: None,
        })
    }

    /// Rows past the content height are not drawn; the disclosure wraps before the choices.
    fn render_trace_step(
        &self,
        buf: &mut Buffer,
        content: Rect,
        theme: &Theme,
        selected: FeedbackTraceChoice,
    ) {
        if content.width == 0 {
            return;
        }
        let width = content.width as usize;
        let bottom = content.y.saturating_add(content.height);
        let mut y = content.y;
        let line = |buf: &mut Buffer, y: &mut u16, text: &str, style: ratatui::style::Style| {
            if *y < bottom {
                buf.set_stringn(content.x, *y, text, width, style);
                *y += 1;
            }
        };
        line(
            buf,
            &mut y,
            self.trace_prompt(),
            ratatui::style::Style::default().fg(theme.text_primary),
        );
        let disclosure = ratatui::text::Line::styled(
            tl(
                "One archive of this session is sent with this report only. Nothing is turned on for future sessions.",
            ),
            ratatui::style::Style::default().fg(theme.gray),
        );
        for wrapped in crate::render::wrapping::word_wrap_line(&disclosure, width) {
            if y >= bottom {
                break;
            }
            buf.set_line(content.x, y, &wrapped, content.width);
            y += 1;
        }
        line(buf, &mut y, "", ratatui::style::Style::default());
        for (index, choice) in FeedbackTraceChoice::ALL.into_iter().enumerate() {
            let (marker, style) = if choice == selected {
                (
                    "\u{276F}",
                    ratatui::style::Style::default()
                        .fg(theme.text_primary)
                        .add_modifier(ratatui::style::Modifier::BOLD),
                )
            } else {
                (" ", ratatui::style::Style::default().fg(theme.gray))
            };
            line(
                buf,
                &mut y,
                &format!("{marker} {}. {}", index + 1, tl(choice.label())),
                style,
            );
        }
        if let Some(error) = &self.error {
            line(buf, &mut y, "", ratatui::style::Style::default());
            line(
                buf,
                &mut y,
                tl(error),
                ratatui::style::Style::default().fg(theme.accent_error),
            );
        }
    }

    pub(super) fn prompt_style() -> PromptStyle {
        PromptStyle {
            show_prefix: false,
            placeholder_when_focused: true,
            placeholder_override: Some(tl("Tell us what happened")),
            // Chips only: the fullscreen preview overlay would paint over the modal.
            image_preview: false,
            ..PromptStyle::overlay()
        }
    }

    const WRITE_SHORTCUTS: &[FooterHint] = &[
        ("Enter", tlm("submit"), false, 0),
        ("Esc", tlm("cancel"), true, CANCEL_SHORTCUT_ID),
    ];

    const UNKNOWN_SUBMIT_SHORTCUTS: &[FooterHint] = &[("Esc", tlm("close"), false, 0)];

    const TERMINAL_SUBMIT_SHORTCUTS: &[FooterHint] = &[("Esc", tlm("close"), false, 0)];

    /// Same as [`Self::WRITE_SHORTCUTS`] plus the label-row hint; shown only when enums were supplied.
    const WRITE_SHORTCUTS_WITH_LABELS: &[FooterHint] = &[
        ("Enter", tlm("submit"), false, 0),
        ("↑/Tab", tlm("labels"), false, 0),
        ("Esc", tlm("cancel"), true, CANCEL_SHORTCUT_ID),
    ];

    // Esc while a label row is focused returns to the composer, so no cancel hint here.
    const METADATA_SHORTCUTS: &[FooterHint] = &[
        ("↑↓", tlm("move"), false, 0),
        ("←→", tlm("value"), false, 0),
        ("Enter", tlm("edit"), false, 0),
        ("Tab", tlm("done"), false, 0),
    ];

    // Not clickable: a click must not confirm a consent choice, and Esc here backs out instead of cancelling.
    const TRACE_SHORTCUTS: &[FooterHint] = &[
        ("Enter", tlm("select"), false, 0),
        ("Esc", tlm("back"), false, 2),
    ];

    /// The tab labels in the interface language, in [`FEEDBACK_TABS`] order.
    pub(super) fn tab_labels() -> Vec<&'static str> {
        FEEDBACK_TABS.iter().copied().map(tl).collect()
    }

    pub(super) fn window_config<'a>(
        tabs: &'a [&'a str],
        shortcuts: &'a [Shortcut<'a>],
        compact: bool,
        trace_step: bool,
    ) -> ModalWindowConfig<'a> {
        let mut sizing = ModalSizing::large().with_compact(compact);
        if trace_step {
            sizing.v_margin = sizing.v_margin.min(3);
        }
        ModalWindowConfig {
            title: tl("Feedback"),
            tabs: Some(tabs),
            shortcuts,
            sizing,
            fold_info: None,
        }
    }
}
