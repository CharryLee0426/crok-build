//! The Remote panel's state, keys and drawing. It reuses the `/resume` picker's window, search bar and rows, and the
//! `/model` picker's type-to-find model and thinking-level steps.

use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use crossterm::event::{Event, KeyCode, KeyEvent, KeyEventKind, MouseEvent};
use ratatui::buffer::Buffer;
use ratatui::layout::Rect;
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use unicode_width::UnicodeWidthStr;
use xai_grok_i18n::{tl, tlf};

use super::tree::{self, Activity, Computer, Folds, Model, Row, RowKey, RowKind};
use super::{RETRY, REWATCH, Request, Response};
use crate::theme::Theme;
use crate::views::modal_window::{
    self as mw, ModalSizing, ModalWindowConfig, ModalWindowOutcome, ModalWindowState, Shortcut,
};
use crate::views::picker::{
    self, PickerConfig, PickerEntry, PickerOutcome, PickerRow, PickerState, handle_picker_input,
};

/// Each panel opened gets its own number, so answers meant for an earlier one are dropped.
static GENERATION: AtomicU64 = AtomicU64::new(1);

/// How soon a list that could not be read is asked for again.
const ERROR_RETRY: Duration = Duration::from_secs(30);

/// Who is signed in where, for the header; read when the panel opens.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Account {
    pub account: String,
    pub computer: String,
    /// `[remote] enabled`.
    pub enabled: bool,
}

impl Account {
    /// This computer's sign-in, or `None` while it is signed out.
    pub fn load() -> Option<Self> {
        let linked = crok_remote::credentials::load().ok().flatten()?;
        Some(Self {
            account: linked.account.display(),
            computer: linked.device_name,
            enabled: crok_remote::settings::load().enabled,
        })
    }
}

/// What a key or click asks of the app.
#[derive(Debug, PartialEq, Eq)]
pub enum Outcome {
    Unchanged,
    Changed,
    Close,
    Request(Request),
    /// Open this session of another computer here (as `/resume` opens a `relay:` row).
    Open {
        session_id: String,
        cwd: Option<String>,
    },
}

/// What the app does after a response.
#[derive(Debug, PartialEq, Eq)]
pub enum Applied {
    Nothing,
    Request(Request),
    /// The new session started: close the panel, say so, and open it.
    Open {
        session_id: String,
        cwd: Option<String>,
        toast: String,
    },
}

/// Where a new session starts.
#[derive(Clone, Debug, PartialEq, Eq)]
struct Target {
    device_id: String,
    computer: String,
    project: String,
    path: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Stage {
    Model,
    Thinking {
        model: usize,
    },
    /// Waiting for `x.ai/remote/new_session`; a failure goes back to `back`.
    Creating {
        back: Back,
    },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Back {
    Model,
    Thinking { model: usize },
}

/// A choice in the model or thinking-level list.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Pick {
    Default,
    Item(usize),
}

/// The steps of `n`: the model, then the thinking level when the model has levels, then starting it.
struct NewSession {
    target: Target,
    /// `None` until `x.ai/remote/models` answers.
    models: Option<Vec<Model>>,
    error: Option<String>,
    stage: Stage,
    model_picker: PickerState,
    /// The "Default" row and the models the filter finds.
    model_rows: Vec<Pick>,
    thinking_picker: PickerState,
    thinking_rows: Vec<Pick>,
}

impl NewSession {
    fn new(target: Target) -> Self {
        Self {
            target,
            models: None,
            error: None,
            stage: Stage::Model,
            model_picker: PickerState::input_active(),
            model_rows: Vec::new(),
            thinking_picker: PickerState::input_active(),
            thinking_rows: Vec::new(),
        }
    }

    fn model(&self, index: usize) -> Option<&Model> {
        self.models.as_ref()?.get(index)
    }

    fn refilter_models(&mut self) {
        let query = self.model_picker.query().to_lowercase();
        let mut rows = Vec::new();
        if default_matches(&query) {
            rows.push(Pick::Default);
        }
        if let Some(models) = &self.models {
            rows.extend(
                tree::filter_models(models, &query)
                    .into_iter()
                    .map(Pick::Item),
            );
        }
        self.model_rows = rows;
        clamp(&mut self.model_picker, self.model_rows.len());
    }

    fn refilter_efforts(&mut self, model: usize) {
        let query = self.thinking_picker.query().to_lowercase();
        let query = query.trim();
        let mut rows = Vec::new();
        if default_matches(query) {
            rows.push(Pick::Default);
        }
        if let Some(model) = self.model(model) {
            rows.extend(
                model
                    .efforts
                    .iter()
                    .enumerate()
                    .filter(|(_, e)| {
                        query.is_empty()
                            || crate::views::session_picker::fuzzy_matches_session(&e.name, query)
                            || crate::views::session_picker::fuzzy_matches_session(&e.id, query)
                    })
                    .map(|(i, _)| Pick::Item(i)),
            );
        }
        self.thinking_rows = rows;
        clamp(&mut self.thinking_picker, self.thinking_rows.len());
    }
}

/// "Default" stays in the list while the filter could name it.
fn default_matches(query: &str) -> bool {
    let query = query.trim();
    query.is_empty()
        || crate::views::session_picker::fuzzy_matches_session(tl("Default"), query)
        || crate::views::session_picker::fuzzy_matches_session("default", query)
}

fn clamp(picker: &mut PickerState, len: usize) {
    picker.selected = picker.selected.min(len.saturating_sub(1));
}

/// The Remote panel.
pub struct RemotePanel {
    generation: u64,
    account: Account,
    window: ModalWindowState,
    /// A list arrived.
    loaded: bool,
    /// The cursor has been put on its first row (a project, when opened by `/remote new`).
    placed: bool,
    signed_in: bool,
    computers: Vec<Computer>,
    folds: Folds,
    rows: Vec<Row>,
    picker: PickerState,
    /// Opened by `/remote new`: the selection starts on a project.
    at_projects: bool,
    /// The list could not be read.
    error: Option<String>,
    /// A one-off line ("… is offline"), gone with the next key.
    notice: Option<String>,
    new: Option<NewSession>,
}

impl RemotePanel {
    /// A panel waiting for its first list, and the request that reads it.
    pub fn open(account: Account, at_projects: bool) -> (Self, Request) {
        let generation = GENERATION.fetch_add(1, Ordering::Relaxed);
        let panel = Self {
            generation,
            account,
            window: ModalWindowState::new(),
            loaded: false,
            placed: false,
            signed_in: false,
            computers: Vec::new(),
            folds: Folds::new(at_projects),
            rows: Vec::new(),
            picker: PickerState::default(),
            at_projects,
            error: None,
            notice: None,
            new: None,
        };
        (panel, Request::Sessions { generation })
    }

    pub fn generation(&self) -> u64 {
        self.generation
    }

    // MARK: The list

    /// The row under the cursor.
    fn selected_row(&self) -> Option<Row> {
        self.rows.get(self.picker.selected).copied()
    }

    fn selected_key(&self) -> Option<RowKey> {
        self.selected_row()?.kind.key(&self.computers)
    }

    fn filtering(&self) -> bool {
        !self.picker.query().trim().is_empty()
    }

    /// Rebuilds the rows and puts the cursor back on `keep` when it is still shown.
    fn rebuild(&mut self, keep: Option<RowKey>) {
        let query = self.picker.query().to_lowercase();
        self.rows = tree::build_rows(&self.computers, &self.folds, &query);
        if let Some(key) = keep
            && let Some(at) = self
                .rows
                .iter()
                .position(|row| row.kind.key(&self.computers).as_ref() == Some(&key))
        {
            self.picker.selected = at;
            return;
        }
        clamp(&mut self.picker, self.rows.len());
    }

    /// A new copy of the list, from a response or from `x.ai/remote/sessions_changed`.
    pub fn set_list(&mut self, payload: &serde_json::Value) {
        let keep = self.selected_key();
        let (signed_in, computers) = tree::parse_sessions(payload);
        self.signed_in = signed_in;
        self.computers = computers;
        self.loaded = true;
        self.rebuild(keep);
        if !self.placed && !self.rows.is_empty() {
            self.placed = true;
            let start = if self.at_projects {
                self.rows.iter().position(|row| {
                    matches!(row.kind, RowKind::Project { c, .. }
                        if self.computers.get(c).is_some_and(|c| c.online))
                })
            } else {
                None
            };
            self.picker.selected = start.unwrap_or(0);
        }
    }

    /// A list pushed by the agent (`x.ai/remote/sessions_changed`). Returns whether it changed anything.
    pub fn list_changed(&mut self, payload: &serde_json::Value) -> bool {
        let (signed_in, computers) = tree::parse_sessions(payload);
        if self.loaded && signed_in == self.signed_in && computers == self.computers {
            return false;
        }
        self.error = None;
        self.set_list(payload);
        true
    }

    /// A response to one of this panel's requests.
    pub fn apply(&mut self, response: Response) -> Applied {
        match response {
            Response::Sessions { generation, result } if generation == self.generation => {
                let delay = match result {
                    Ok(payload) => {
                        self.error = None;
                        self.set_list(&payload);
                        if self.signed_in { REWATCH } else { RETRY }
                    }
                    Err(error) => {
                        self.error = Some(error);
                        ERROR_RETRY
                    }
                };
                Applied::Request(Request::Wait { generation, delay })
            }
            Response::Due { generation } if generation == self.generation => {
                Applied::Request(Request::Sessions { generation })
            }
            Response::Models {
                generation,
                device_id,
                result,
            } if generation == self.generation => {
                let Some(new) = self
                    .new
                    .as_mut()
                    .filter(|new| new.target.device_id == device_id && new.models.is_none())
                else {
                    return Applied::Nothing;
                };
                match result {
                    Ok(payload) => new.models = Some(tree::parse_models(&payload)),
                    Err(error) => {
                        new.models = Some(Vec::new());
                        new.error = Some(error);
                    }
                }
                new.refilter_models();
                Applied::Nothing
            }
            Response::Created { generation, result } if generation == self.generation => {
                let Some(new) = self.new.as_mut() else {
                    return Applied::Nothing;
                };
                let Stage::Creating { back } = new.stage else {
                    return Applied::Nothing;
                };
                match result {
                    Ok(session_id) => {
                        let target = new.target.clone();
                        self.new = None;
                        Applied::Open {
                            session_id,
                            cwd: Some(target.path),
                            toast: tlf(
                                "Started a session in {project} on {computer}.",
                                &[("project", &target.project), ("computer", &target.computer)],
                            ),
                        }
                    }
                    Err(error) => {
                        new.stage = match back {
                            Back::Model => Stage::Model,
                            Back::Thinking { model } => Stage::Thinking { model },
                        };
                        new.error = Some(tlf(
                            "Could not start the session: {error}",
                            &[("error", &error)],
                        ));
                        Applied::Nothing
                    }
                }
            }
            _ => Applied::Nothing,
        }
    }

    // MARK: Keys

    pub fn key(&mut self, key: &KeyEvent) -> Outcome {
        if key.kind == KeyEventKind::Release {
            return Outcome::Unchanged;
        }
        let had_notice = self.notice.take().is_some();
        let outcome = if key.code == KeyCode::Esc {
            self.escape()
        } else {
            self.event(&Event::Key(*key))
        };
        match outcome {
            Outcome::Unchanged if had_notice => Outcome::Changed,
            other => other,
        }
    }

    pub fn paste(&mut self, text: &str) -> Outcome {
        self.event(&Event::Paste(text.to_owned()))
    }

    pub fn mouse(&mut self, mouse: &MouseEvent) -> Outcome {
        match mw::handle_modal_mouse(&mut self.window, mouse.kind, mouse.column, mouse.row) {
            ModalWindowOutcome::CloseRequested => Outcome::Close,
            ModalWindowOutcome::Unhandled => self.event(&Event::Mouse(*mouse)),
            _ => Outcome::Changed,
        }
    }

    /// Esc clears the filter, else goes back a step, else closes.
    fn escape(&mut self) -> Outcome {
        let Some(new) = self.new.as_mut() else {
            if !self.picker.query().is_empty() {
                let keep = self.selected_key();
                self.picker.set_query("");
                self.picker.search_active = false;
                self.picker.scroll_offset = None;
                self.rebuild(keep);
                return Outcome::Changed;
            }
            return Outcome::Close;
        };
        match new.stage {
            Stage::Thinking { model } => {
                if new.thinking_picker.query().is_empty() {
                    new.stage = Stage::Model;
                    new.error = None;
                } else {
                    new.thinking_picker.set_query("");
                    new.refilter_efforts(model);
                }
            }
            Stage::Model => {
                if new.model_picker.query().is_empty() {
                    self.new = None;
                } else {
                    new.model_picker.set_query("");
                    new.refilter_models();
                }
            }
            // The session may still start; it then shows up in the list.
            Stage::Creating { .. } => self.new = None,
        }
        Outcome::Changed
    }

    fn event(&mut self, event: &Event) -> Outcome {
        if self.new.is_some() {
            return self.new_session_event(event);
        }
        let config = PickerConfig {
            title: None,
            show_search_hint: true,
            expandable: true,
            esc_clears_query: true,
            shortcuts: None,
            pending_hint: None,
            non_selectable: &[],
            non_selectable_clickable: &[],
            shortcuts_area: None,
            tabs: None,
            active_tab: 0,
            filter_label: None,
            filter_key_hint: None,
            filter_active: false,
            header_note: None,
            action_keys: &[('n', "new")],
            disable_search: false,
            compact_bottom_bar: false,
            search_only_on_slash: false,
            vim_normal_first: crate::appearance::cache::load_vim_mode(),
        };
        // ↑/↓ while typing a filter leave the search bar and move on from the row the filter picked (the picker alone
        // would jump to the first row, a computer or project shown only for the match under it).
        if let Event::Key(key) = event
            && self.picker.search_active
            && matches!(key.code, KeyCode::Up | KeyCode::Down)
            && !self.rows.is_empty()
        {
            // With no row shown as selected (↑ from the top went up to the search bar) ↓ comes back to that row and ↑
            // wraps to the end, as in the other pickers.
            let from_search_bar = self.picker.selection_hidden;
            self.picker.search_active = false;
            self.picker.selection_hidden = false;
            self.picker.hovered = None;
            self.picker.scroll_offset = None;
            let last = self.rows.len() - 1;
            let at = self.picker.selected.min(last);
            self.picker.selected = match (key.code, from_search_bar) {
                (KeyCode::Up, true) => last,
                (KeyCode::Up, false) => at.saturating_sub(1),
                (_, true) => at,
                (_, false) => (at + 1).min(last),
            };
            return Outcome::Changed;
        }
        let before = self.selected_key();
        match handle_picker_input(event, &mut self.picker, self.rows.len(), &config) {
            PickerOutcome::Selected(at) => self.activate(at),
            PickerOutcome::Expand(at) => self.expand(at),
            PickerOutcome::Collapse(at) => self.collapse(at),
            PickerOutcome::Action('n') => self.start_new(),
            PickerOutcome::QueryChanged => {
                if self.filtering() {
                    self.rebuild(None);
                    // The first row that matches by itself, not one shown for a match above or below it.
                    self.picker.selected = self.rows.iter().position(|r| r.matched).unwrap_or(0);
                } else {
                    self.rebuild(before);
                }
                Outcome::Changed
            }
            PickerOutcome::Closed => Outcome::Close,
            PickerOutcome::Unchanged => Outcome::Unchanged,
            _ => Outcome::Changed,
        }
    }

    /// Enter (or a click): a session opens; a computer or project folds or unfolds.
    fn activate(&mut self, at: usize) -> Outcome {
        let Some(row) = self.rows.get(at).copied() else {
            return Outcome::Changed;
        };
        if let RowKind::Session { c, p, s } = row.kind {
            let Some(project) = self.computers.get(c).and_then(|c| c.projects.get(p)) else {
                return Outcome::Changed;
            };
            let Some(session) = project.sessions.get(s) else {
                return Outcome::Changed;
            };
            let cwd = if session.cwd.is_empty() {
                project.path.clone()
            } else {
                session.cwd.clone()
            };
            return Outcome::Open {
                session_id: session.session_id.clone(),
                cwd: (!cwd.is_empty()).then_some(cwd),
            };
        }
        if self.filtering() {
            return self.step_into_first_child(at);
        }
        let open = self.folds.is_open(row.kind, &self.computers);
        self.set_open(row.kind, !open);
        Outcome::Changed
    }

    /// → (or e): unfold, or step into an unfolded group.
    fn expand(&mut self, at: usize) -> Outcome {
        let Some(row) = self.rows.get(at).copied() else {
            return Outcome::Unchanged;
        };
        if matches!(row.kind, RowKind::Session { .. }) {
            return Outcome::Unchanged;
        }
        if !self.filtering() && !self.folds.is_open(row.kind, &self.computers) {
            self.set_open(row.kind, true);
            return Outcome::Changed;
        }
        self.step_into_first_child(at)
    }

    /// ← (or E): fold, or step out to the row above in the tree.
    fn collapse(&mut self, at: usize) -> Outcome {
        let Some(row) = self.rows.get(at).copied() else {
            return Outcome::Unchanged;
        };
        let group = !matches!(row.kind, RowKind::Session { .. });
        if group && !self.filtering() && self.folds.is_open(row.kind, &self.computers) {
            self.set_open(row.kind, false);
            return Outcome::Changed;
        }
        let depth = row.kind.depth();
        let parent = self
            .rows
            .get(..at)
            .unwrap_or(&[])
            .iter()
            .rposition(|r| r.kind.depth() < depth);
        match parent {
            Some(parent) => {
                self.picker.selected = parent;
                self.picker.scroll_offset = None;
                Outcome::Changed
            }
            None => Outcome::Unchanged,
        }
    }

    fn step_into_first_child(&mut self, at: usize) -> Outcome {
        let depth = self.rows.get(at).map(|r| r.kind.depth());
        match (depth, self.rows.get(at + 1)) {
            (Some(depth), Some(next)) if next.kind.depth() > depth => {
                self.picker.selected = at + 1;
                self.picker.scroll_offset = None;
                Outcome::Changed
            }
            _ => Outcome::Unchanged,
        }
    }

    fn set_open(&mut self, kind: RowKind, open: bool) {
        let keep = kind.key(&self.computers);
        self.folds.set(kind, &self.computers, open);
        self.rebuild(keep);
    }

    /// `n`: a new session in the selected project (or the selected session's).
    fn start_new(&mut self) -> Outcome {
        let Some((c, p)) = self.selected_row().and_then(|row| row.kind.project()) else {
            self.notice =
                Some(tl("Pick a project, then press n to start a session there.").to_string());
            return Outcome::Changed;
        };
        let Some(computer) = self.computers.get(c) else {
            return Outcome::Unchanged;
        };
        let Some(project) = computer.projects.get(p) else {
            return Outcome::Unchanged;
        };
        if computer.here {
            self.notice = Some(
                tl("This is the computer you are on: start a session here with /new.").to_string(),
            );
            return Outcome::Changed;
        }
        if !computer.online {
            self.notice = Some(tlf(
                "{computer} is offline: nothing can start there until crok or Crok Desktop runs on it.",
                &[("computer", &computer.name)],
            ));
            return Outcome::Changed;
        }
        let target = Target {
            device_id: computer.device_id.clone(),
            computer: computer.name.clone(),
            project: project.name.clone(),
            path: project.path.clone(),
        };
        let request = Request::Models {
            generation: self.generation,
            device_id: target.device_id.clone(),
        };
        let mut new = NewSession::new(target);
        new.refilter_models();
        self.new = Some(new);
        Outcome::Request(request)
    }

    fn new_session_event(&mut self, event: &Event) -> Outcome {
        let generation = self.generation;
        let Some(new) = self.new.as_mut() else {
            return Outcome::Unchanged;
        };
        let config = PickerConfig {
            title: None,
            show_search_hint: false,
            expandable: false,
            esc_clears_query: false,
            shortcuts: None,
            pending_hint: None,
            non_selectable: &[],
            non_selectable_clickable: &[],
            shortcuts_area: None,
            tabs: None,
            active_tab: 0,
            filter_label: None,
            filter_key_hint: None,
            filter_active: false,
            header_note: None,
            action_keys: &[],
            disable_search: false,
            compact_bottom_bar: false,
            search_only_on_slash: false,
            vim_normal_first: crate::appearance::cache::load_vim_mode(),
        };
        match new.stage {
            Stage::Creating { .. } => Outcome::Unchanged,
            Stage::Model => {
                // Nothing to pick until the list arrives; typing still filters it.
                let count = if new.models.is_some() {
                    new.model_rows.len()
                } else {
                    0
                };
                match handle_picker_input(event, &mut new.model_picker, count, &config) {
                    PickerOutcome::Selected(at) => {
                        let Some(pick) = new.model_rows.get(at).copied() else {
                            return Outcome::Changed;
                        };
                        let model = match pick {
                            Pick::Default => None,
                            Pick::Item(index) => Some(index),
                        };
                        let has_levels = model
                            .and_then(|index| new.model(index))
                            .is_some_and(|m| !m.efforts.is_empty());
                        match model {
                            Some(index) if has_levels => {
                                new.stage = Stage::Thinking { model: index };
                                new.error = None;
                                new.thinking_picker = PickerState::input_active();
                                new.refilter_efforts(index);
                                Outcome::Changed
                            }
                            _ => create(new, generation, model, None, Back::Model),
                        }
                    }
                    PickerOutcome::QueryChanged => {
                        new.refilter_models();
                        Outcome::Changed
                    }
                    PickerOutcome::Closed => {
                        self.new = None;
                        Outcome::Changed
                    }
                    PickerOutcome::Unchanged => Outcome::Unchanged,
                    _ => Outcome::Changed,
                }
            }
            Stage::Thinking { model } => {
                let count = new.thinking_rows.len();
                match handle_picker_input(event, &mut new.thinking_picker, count, &config) {
                    PickerOutcome::Selected(at) => {
                        let effort = match new.thinking_rows.get(at).copied() {
                            Some(Pick::Default) => None,
                            Some(Pick::Item(index)) => new
                                .model(model)
                                .and_then(|m| m.efforts.get(index))
                                .map(|e| e.id.clone()),
                            None => return Outcome::Changed,
                        };
                        create(
                            new,
                            generation,
                            Some(model),
                            effort,
                            Back::Thinking { model },
                        )
                    }
                    PickerOutcome::QueryChanged => {
                        new.refilter_efforts(model);
                        Outcome::Changed
                    }
                    PickerOutcome::Closed => {
                        new.stage = Stage::Model;
                        Outcome::Changed
                    }
                    PickerOutcome::Unchanged => Outcome::Unchanged,
                    _ => Outcome::Changed,
                }
            }
        }
    }

    // MARK: Drawing

    pub fn render(&mut self, area: Rect, buf: &mut Buffer, theme: &Theme, compact: bool) {
        let filtering = match &self.new {
            None => !self.picker.query().is_empty(),
            Some(new) => match new.stage {
                Stage::Model => !new.model_picker.query().is_empty(),
                Stage::Thinking { .. } => !new.thinking_picker.query().is_empty(),
                Stage::Creating { .. } => false,
            },
        };
        let esc = if filtering {
            tl("Esc exit filter")
        } else if self.new.is_some() {
            tl("Esc back")
        } else {
            tl("Esc close")
        };
        let hint = |label: &'static str| Shortcut {
            label,
            clickable: false,
            id: 0,
        };
        let shortcuts: Vec<Shortcut> = match self.new.as_ref().map(|n| n.stage) {
            None => vec![
                hint(tl("↑↓ nav")),
                hint(tl("←→ fold")),
                hint(tl("Enter open")),
                hint(tl("n new")),
                hint(tl("type to filter")),
                hint(esc),
            ],
            Some(Stage::Creating { .. }) => vec![hint(esc)],
            Some(_) => vec![
                hint(tl("↑↓ nav")),
                hint(tl("Enter select")),
                hint(tl("type to filter")),
                hint(esc),
            ],
        };
        let config = ModalWindowConfig {
            title: if self.new.is_some() {
                tl("New session")
            } else {
                tl("Other computers")
            },
            tabs: None,
            shortcuts: &shortcuts,
            sizing: ModalSizing {
                width_pct: 0.75,
                max_width: 140,
                min_width: 56,
                v_margin: 3,
                h_pad: 2,
                v_pad: 1,
                footer_lines: 2,
            }
            .with_compact(compact),
            fold_info: None,
        };
        let Some(mca) = mw::render_modal_window(buf, area, &mut self.window, &config, theme) else {
            return;
        };
        let content = mca.content;
        if content.height < 4 {
            return;
        }
        let (first, second) = self.header_lines(theme);
        let width = content.width;
        put_line(buf, content.x, content.y, width, first, theme);
        put_line(buf, content.x, content.y + 1, width, second, theme);
        let list_area = Rect {
            x: content.x,
            y: content.y + 2,
            width: content.width,
            height: content.height - 2,
        };
        match self.new.as_mut() {
            None => self.render_tree(buf, list_area, &mca, theme),
            Some(new) => render_new_session(new, buf, list_area, &mca, theme),
        }
    }

    /// The header and the line under it: who and where, then what is going on.
    fn header_lines(&self, theme: &Theme) -> (Line<'static>, Line<'static>) {
        let dim = Style::default().fg(theme.gray);
        let sep = Span::styled("  ·  ", Style::default().fg(theme.gray_dim));
        let warn =
            |text: String| Line::from(Span::styled(text, Style::default().fg(theme.warning)));
        if let Some(new) = &self.new {
            let mut first = vec![Span::styled(
                tlf(
                    "New session in {project} on {computer}",
                    &[
                        ("project", &new.target.project),
                        ("computer", &new.target.computer),
                    ],
                ),
                Style::default()
                    .fg(theme.text_primary)
                    .add_modifier(Modifier::BOLD),
            )];
            let model = match new.stage {
                Stage::Thinking { model }
                | Stage::Creating {
                    back: Back::Thinking { model },
                } => new.model(model).map(|m| m.name.clone()),
                _ => None,
            };
            if let Some(model) = model {
                first.push(sep);
                first.push(Span::styled(model, dim));
            }
            let second = if let Some(error) = &new.error {
                warn(error.clone())
            } else {
                Line::from(Span::styled(
                    match new.stage {
                        Stage::Model => tl("Pick model").to_string(),
                        Stage::Thinking { .. } => tl("Pick reasoning effort").to_string(),
                        Stage::Creating { .. } => tlf(
                            "Starting a session on {computer}…",
                            &[("computer", &new.target.computer)],
                        ),
                    },
                    dim,
                ))
            };
            return (Line::from(first), second);
        }
        let (glyph, state, state_style) =
            match (self.account.enabled, crate::remote_cmd::indicator()) {
                (false, _) => ("○", tl("turned off ([remote] enabled = false)"), dim),
                (true, crate::remote_cmd::Indicator::Connected) => (
                    "●",
                    tl("connected"),
                    Style::default().fg(theme.accent_success),
                ),
                (true, crate::remote_cmd::Indicator::Connecting) => ("○", tl("connecting…"), dim),
                (true, crate::remote_cmd::Indicator::Off) => ("○", tl("starting…"), dim),
            };
        let mut first = vec![Span::styled(format!("{glyph} {state}"), state_style)];
        if !self.account.account.is_empty() {
            first.push(sep.clone());
            first.push(Span::styled(
                format!("{} {}", tl("Account:"), self.account.account),
                dim,
            ));
        }
        first.push(sep);
        first.push(Span::styled(
            format!("{} {}", tl("This computer:"), self.account.computer),
            dim,
        ));
        let second = if let Some(notice) = &self.notice {
            warn(notice.clone())
        } else if let Some(error) = &self.error {
            warn(error.clone())
        } else if self.loaded && !self.signed_in {
            Line::from(Span::styled(
                tl("Connecting to the relay…").to_string(),
                dim,
            ))
        } else {
            Line::default()
        };
        (Line::from(first), second)
    }

    fn render_tree(
        &mut self,
        buf: &mut Buffer,
        area: Rect,
        mca: &mw::ModalContentArea,
        theme: &Theme,
    ) {
        let cells: Vec<Cells> = self
            .rows
            .iter()
            .map(|row| {
                tree_cells(
                    row.kind,
                    &self.computers,
                    &self.folds,
                    self.filtering(),
                    theme,
                    area.width,
                )
            })
            .collect();
        let state = &self.picker;
        let entries: Vec<PickerEntry> = cells
            .iter()
            .enumerate()
            .map(|(i, cell)| PickerEntry::Row(cell.row(is_selected(state, i))))
            .collect();
        let loading = !self.loaded && self.error.is_none();
        picker::render_picker_in_modal(
            buf,
            area,
            mca.inner_x,
            mca.inner_width,
            theme,
            &mut self.picker,
            &entries,
            &[],
            loading,
        );
        // Under the search bar and its divider: the list was empty because there is nothing, not because nothing matched.
        if self.loaded && self.computers.is_empty() && !self.filtering() && self.signed_in {
            put_line(
                buf,
                area.x,
                area.y + 2,
                area.width,
                Line::from(Span::styled(
                    format!(
                        "  {}",
                        tl(
                            "No other computers yet: sign in to remote control on another computer with the same account."
                        )
                    ),
                    Style::default().fg(theme.gray_dim),
                )),
                theme,
            );
        }
    }
}

/// Starts the session with what was picked; `back` is where a failure returns to.
fn create(
    new: &mut NewSession,
    generation: u64,
    model: Option<usize>,
    effort: Option<String>,
    back: Back,
) -> Outcome {
    let model_id = model
        .and_then(|index| new.model(index))
        .map(|m| m.id.clone());
    new.stage = Stage::Creating { back };
    new.error = None;
    Outcome::Request(Request::Create {
        generation,
        device_id: new.target.device_id.clone(),
        path: new.target.path.clone(),
        model: model_id,
        effort,
    })
}

fn is_selected(state: &PickerState, at: usize) -> bool {
    !state.selection_hidden
        && (state.hovered == Some(at) || (state.hovered.is_none() && at == state.selected))
}

/// Writes `line` over one row of the panel, clearing what was there.
fn put_line(buf: &mut Buffer, x: u16, y: u16, width: u16, line: Line<'_>, theme: &Theme) {
    let base = Style::default().bg(theme.bg_base);
    buf.set_style(Rect::new(x, y, width, 1), base);
    buf.set_string(x, y, " ".repeat(width as usize), base);
    let mut at = x;
    let end = x + width;
    for span in line.spans {
        if at >= end {
            break;
        }
        let room = (end - at) as usize;
        let text = crate::util::truncate_to_width(&span.content, room);
        let style = base.patch(span.style);
        buf.set_string(at, y, text.as_ref(), style);
        at += text.width() as u16;
    }
}

/// One row's texts, owned so the picker rows can borrow them.
struct Cells {
    label: String,
    badge: String,
    badge_color: Option<Color>,
    right: String,
    indent: u8,
    collapsible: bool,
    expanded: bool,
    dimmed: bool,
}

impl Cells {
    fn row(&self, selected: bool) -> PickerRow<'_> {
        PickerRow {
            label: &self.label,
            right_label: &self.right,
            selected,
            expanded: self.expanded,
            fields: &[],
            description_lines: &[],
            summary_lines: &[],
            dimmed: self.dimmed,
            indent: self.indent,
            badge: &self.badge,
            badge_color: self.badge_color,
            collapsible: self.collapsible,
            underline_last_desc: false,
        }
    }

    fn plain(label: String, right: String) -> Self {
        Self {
            label,
            badge: String::new(),
            badge_color: None,
            right,
            indent: 0,
            collapsible: false,
            expanded: false,
            dimmed: false,
        }
    }
}

fn time_ago(ms: Option<f64>) -> Option<String> {
    let at = chrono::DateTime::from_timestamp_millis(ms? as i64)?;
    Some(
        crate::views::session_picker::format_time_ago(at)
            .trim_start()
            .to_string(),
    )
}

fn unread_text(count: u64) -> String {
    tlf("{count} unread", &[("count", &count)])
}

fn tree_cells(
    kind: RowKind,
    computers: &[Computer],
    folds: &Folds,
    filtering: bool,
    theme: &Theme,
    width: u16,
) -> Cells {
    let open = filtering || folds.is_open(kind, computers);
    let Some(computer) = computers.get(kind.computer()) else {
        return Cells::plain(String::new(), String::new());
    };
    match kind {
        RowKind::Computer { .. } => {
            let (badge, color) = if computer.here {
                (tl("started from other devices").to_string(), theme.gray)
            } else if computer.online {
                (format!("● {}", tl("online")), theme.accent_success)
            } else {
                let seen = time_ago(computer.last_seen_ms)
                    .map(|time| tlf("last seen {time}", &[("time", &time)]))
                    .unwrap_or_else(|| tl("offline").to_string());
                (seen, theme.gray)
            };
            let unread = computer.unread();
            Cells {
                label: computer.name.clone(),
                badge,
                badge_color: Some(color),
                right: if unread > 0 {
                    unread_text(unread)
                } else {
                    String::new()
                },
                indent: 0,
                collapsible: true,
                expanded: open,
                dimmed: !computer.online,
            }
        }
        RowKind::Project { p, .. } => {
            let Some(project) = computer.projects.get(p) else {
                return Cells::plain(String::new(), String::new());
            };
            let count = project.sessions.len();
            let sessions = if count == 1 {
                tl("1 session").to_string()
            } else {
                tlf("{count} sessions", &[("count", &count)])
            };
            // The folder, shortened, when it says more than the name; never more than a third of the row.
            let badge = if project.path == project.name {
                String::new()
            } else {
                let folder = crate::util::display_location_path(&project.path);
                crate::util::truncate_to_width(&folder, (width / 3) as usize).into_owned()
            };
            Cells {
                label: project.name.clone(),
                badge,
                badge_color: Some(theme.gray_dim),
                right: sessions,
                indent: 1,
                collapsible: true,
                expanded: open,
                dimmed: !computer.online,
            }
        }
        RowKind::Session { p, s, .. } => {
            let Some(project) = computer.projects.get(p) else {
                return Cells::plain(String::new(), String::new());
            };
            let Some(session) = project.sessions.get(s) else {
                return Cells::plain(String::new(), String::new());
            };
            let (badge, color) = match session.activity() {
                Some(Activity::Working) => (tl("working…").to_string(), Some(theme.running)),
                Some(Activity::NeedsApproval) => {
                    (tl("needs approval").to_string(), Some(theme.warning))
                }
                Some(Activity::Starting) => (tl("starting…").to_string(), Some(theme.gray)),
                None => match &session.from {
                    Some(from) => (tlf("from {device}", &[("device", from)]), Some(theme.gray)),
                    None => (String::new(), None),
                },
            };
            let time = time_ago(session.last_activity_ms).unwrap_or_default();
            let right = match (session.unread, time.is_empty()) {
                (0, _) => time,
                (unread, true) => unread_text(unread),
                (unread, false) => format!("{}  ·  {time}", unread_text(unread)),
            };
            let label = if session.title.is_empty() {
                project.name.clone()
            } else {
                session.title.clone()
            };
            Cells {
                label,
                badge,
                badge_color: color,
                right,
                indent: 2,
                collapsible: false,
                expanded: false,
                dimmed: !computer.online,
            }
        }
    }
}

fn render_new_session(
    new: &mut NewSession,
    buf: &mut Buffer,
    area: Rect,
    mca: &mw::ModalContentArea,
    theme: &Theme,
) {
    let (picker_state, cells, loading) = match new.stage {
        Stage::Creating { .. } => (&mut new.model_picker, Vec::new(), true),
        Stage::Model => {
            let cells: Vec<Cells> = new
                .model_rows
                .iter()
                .map(|pick| match pick {
                    Pick::Default => Cells::plain(
                        tl("Default").to_string(),
                        tl("that computer's own choice").to_string(),
                    ),
                    Pick::Item(index) => {
                        let (name, description) = new
                            .models
                            .as_ref()
                            .and_then(|models| models.get(*index))
                            .map(|m| (m.name.clone(), m.description.clone()))
                            .unwrap_or_default();
                        Cells::plain(name, description)
                    }
                })
                .collect();
            let loading = new.models.is_none();
            (&mut new.model_picker, cells, loading)
        }
        Stage::Thinking { model } => {
            let efforts = new
                .models
                .as_ref()
                .and_then(|models| models.get(model))
                .map(|m| m.efforts.clone())
                .unwrap_or_default();
            let default_level = efforts
                .iter()
                .find(|e| e.default)
                .map(|e| e.name.clone())
                .unwrap_or_default();
            let cells: Vec<Cells> = new
                .thinking_rows
                .iter()
                .map(|pick| match pick {
                    Pick::Default => Cells::plain(tl("Default").to_string(), default_level.clone()),
                    Pick::Item(index) => efforts
                        .get(*index)
                        .map(|e| Cells::plain(e.name.clone(), e.description.clone()))
                        .unwrap_or_else(|| Cells::plain(String::new(), String::new())),
                })
                .collect();
            (&mut new.thinking_picker, cells, false)
        }
    };
    let entries: Vec<PickerEntry> = cells
        .iter()
        .enumerate()
        .map(|(i, cell)| PickerEntry::Row(cell.row(is_selected(picker_state, i))))
        .collect();
    picker::render_picker_in_modal(
        buf,
        area,
        mca.inner_x,
        mca.inner_width,
        theme,
        picker_state,
        &entries,
        &[],
        loading,
    );
}

#[cfg(test)]
impl RemotePanel {
    pub(crate) fn rows_for_test(&self) -> Vec<RowKey> {
        self.rows
            .iter()
            .filter_map(|row| row.kind.key(&self.computers))
            .collect()
    }

    pub(crate) fn selected_key_for_test(&self) -> Option<RowKey> {
        self.selected_key()
    }

    pub(crate) fn notice_for_test(&self) -> Option<&str> {
        self.notice.as_deref()
    }

    /// `tree`, `model`, `thinking` or `creating`.
    pub(crate) fn step_for_test(&self) -> &'static str {
        match self.new.as_ref().map(|n| n.stage) {
            None => "tree",
            Some(Stage::Model) => "model",
            Some(Stage::Thinking { .. }) => "thinking",
            Some(Stage::Creating { .. }) => "creating",
        }
    }

    /// The labels of the model or thinking-level rows shown now.
    pub(crate) fn choices_for_test(&self) -> Vec<String> {
        let Some(new) = &self.new else {
            return Vec::new();
        };
        match new.stage {
            Stage::Model => new
                .model_rows
                .iter()
                .map(|pick| match pick {
                    Pick::Default => "Default".to_string(),
                    Pick::Item(index) => {
                        new.model(*index).map(|m| m.id.clone()).unwrap_or_default()
                    }
                })
                .collect(),
            Stage::Thinking { model } => new
                .thinking_rows
                .iter()
                .map(|pick| match pick {
                    Pick::Default => "Default".to_string(),
                    Pick::Item(index) => new
                        .model(model)
                        .and_then(|m| m.efforts.get(*index))
                        .map(|e| e.id.clone())
                        .unwrap_or_default(),
                })
                .collect(),
            Stage::Creating { .. } => Vec::new(),
        }
    }
}
