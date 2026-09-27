//! Read-only, keyboard-first exploration of a recorded agent session.
//!
//! The same explorer runs standalone (`grok trace view`) and as an overlay in the
//! interactive TUI (`/trace`). It opens on the recorded transcript: one timeline
//! lane per entry type, with bar widths taken from recorded execution time.

use std::io::{self, IsTerminal};
use std::path::{Path, PathBuf};
use std::sync::Arc;

use anyhow::{Context, Result, bail};
use crossterm::{
    cursor::{Hide, Show},
    event::{self, Event, KeyCode, KeyEvent, KeyEventKind, KeyModifiers},
    execute,
    terminal::{EnterAlternateScreen, LeaveAlternateScreen, disable_raw_mode, enable_raw_mode},
};
use ratatui::{
    Terminal,
    backend::CrosstermBackend,
    buffer::Buffer,
    layout::{Constraint, Direction, Layout, Rect},
    style::{Color, Modifier, Style},
    text::{Line, Span},
    widgets::{
        Block, BorderType, Borders, Clear, List, ListItem, ListState, Paragraph, StatefulWidget,
        Tabs, Widget,
    },
};
use serde_json::Value;

use super::data::{Encryption, TraceData, TraceEvent, TraceTool};
use super::transcript::{EntryKind, TranscriptEntry};
use crate::theme::Theme;

/// Opens the trace in the terminal without executing tools or modifying the recording.
pub fn run(data: &TraceData) -> Result<()> {
    if !io::stdin().is_terminal() || !io::stdout().is_terminal() {
        bail!(
            "The trace explorer needs an interactive terminal. Use --format html --output trace.html to export a browser view."
        );
    }
    crate::theme::cache::set(crate::theme::cache::resolve_initial_theme_no_osc11());
    let theme = Theme::current();
    let _guard = TerminalGuard::enter()?;
    let mut terminal = Terminal::new(CrosstermBackend::new(io::stdout()))
        .context("Could not initialize the trace terminal")?;
    let mut state = Explorer::new(data);
    loop {
        terminal.draw(|frame| {
            let area = frame.area();
            render(area, frame.buffer_mut(), data, &mut state, &theme);
        })?;
        match event::read().context("Could not read terminal input")? {
            Event::Key(key) if key.kind != KeyEventKind::Release => {
                if (key.code == KeyCode::Char('c') && key.modifiers.contains(KeyModifiers::CONTROL))
                    || state.key(data, key)
                {
                    break;
                }
            }
            Event::Resize(_, _) => {}
            _ => continue,
        }
    }
    Ok(())
}

type PanicHook = dyn Fn(&std::panic::PanicHookInfo<'_>) + Send + Sync + 'static;

/// Restore on both ordinary errors and panics, including this workspace's abort profiles.
struct TerminalGuard {
    previous_hook: Option<Arc<PanicHook>>,
}

impl TerminalGuard {
    fn enter() -> Result<Self> {
        enable_raw_mode().context("Could not enable terminal input")?;
        let previous_hook: Arc<PanicHook> = std::panic::take_hook().into();
        let delegate = Arc::clone(&previous_hook);
        std::panic::set_hook(Box::new(move |info| {
            restore_terminal();
            delegate(info);
        }));
        let guard = Self {
            previous_hook: Some(previous_hook),
        };
        execute!(io::stdout(), EnterAlternateScreen, Hide)
            .context("Could not enter the trace terminal")?;
        Ok(guard)
    }
}

impl Drop for TerminalGuard {
    fn drop(&mut self) {
        restore_terminal();
        // Rust forbids changing hooks while unwinding. In that case the hook has
        // already restored the screen and delegates to the original panic reporter.
        if !std::thread::panicking()
            && let Some(previous) = self.previous_hook.take()
        {
            std::panic::set_hook(Box::new(move |info| previous(info)));
        }
    }
}

fn restore_terminal() {
    let _ = disable_raw_mode();
    let _ = execute!(io::stdout(), Show, LeaveAlternateScreen);
}

/// The `/trace` overlay: a snapshot of the current session, loaded off the UI thread.
pub struct TraceOverlay {
    pub dir: PathBuf,
    load: OverlayLoad,
}

enum OverlayLoad {
    Loading,
    Ready {
        data: Box<TraceData>,
        explorer: Box<Explorer>,
    },
    Failed(String),
}

/// What the host should do after the overlay handled a key.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OverlayOutcome {
    Changed,
    Close,
    /// Take a new snapshot of the (possibly still running) session.
    Reload,
}

impl TraceOverlay {
    pub fn loading(dir: PathBuf) -> Self {
        Self {
            dir,
            load: OverlayLoad::Loading,
        }
    }

    pub fn is_loading(&self) -> bool {
        matches!(self.load, OverlayLoad::Loading)
    }

    pub fn finish(&mut self, result: Result<TraceData, String>) {
        self.load = match result {
            Ok(data) => {
                let explorer = Box::new(Explorer::new(&data));
                OverlayLoad::Ready {
                    data: Box::new(data),
                    explorer,
                }
            }
            Err(error) => OverlayLoad::Failed(error),
        };
    }

    pub fn key(&mut self, key: KeyEvent) -> OverlayOutcome {
        match &mut self.load {
            OverlayLoad::Ready { data, explorer } => {
                if key.code == KeyCode::Char('r') && !explorer.searching && !explorer.help {
                    OverlayOutcome::Reload
                } else if explorer.key(data, key) {
                    OverlayOutcome::Close
                } else {
                    OverlayOutcome::Changed
                }
            }
            OverlayLoad::Loading | OverlayLoad::Failed(_) => match key.code {
                KeyCode::Esc | KeyCode::Char('q') => OverlayOutcome::Close,
                KeyCode::Char('r') => OverlayOutcome::Reload,
                _ => OverlayOutcome::Changed,
            },
        }
    }

    /// Mouse wheel: move through the focused pane.
    pub fn scroll(&mut self, lines: isize) {
        if let OverlayLoad::Ready { explorer, .. } = &mut self.load {
            if explorer.detail_focus {
                explorer.scroll_detail(lines);
            } else {
                explorer.move_selection(lines);
            }
        }
    }

    pub fn render(&mut self, area: Rect, buf: &mut Buffer, theme: &Theme) {
        Clear.render(area, buf);
        match &mut self.load {
            OverlayLoad::Ready { data, explorer } => render(area, buf, data, explorer, theme),
            OverlayLoad::Loading | OverlayLoad::Failed(_) => {
                Block::default()
                    .style(Style::default().bg(theme.bg_base).fg(theme.text_primary))
                    .render(area, buf);
                let text = match &self.load {
                    OverlayLoad::Failed(error) => format!(
                        "Could not read the trace for this session.\n\n{}\n\n{error}\n\nr retry · Esc close",
                        self.dir.display()
                    ),
                    _ => format!("Reading the session trace…\n\n{}", self.dir.display()),
                };
                Paragraph::new(clean(&text))
                    .block(panel(" Trace ".to_owned(), true, theme))
                    .wrap(ratatui::widgets::Wrap { trim: false })
                    .render(area, buf);
            }
        }
    }
}

/// Load a session directory for the overlay; errors are shown in the overlay.
pub fn load_session(dir: &Path) -> Result<TraceData, String> {
    super::data::load(dir).map_err(|error| format!("{error:#}"))
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
enum View {
    /// The recorded conversation.
    #[default]
    Transcript,
    /// Every raw record, including phase changes and streamed chunks.
    Records,
}

impl View {
    fn name(self) -> &'static str {
        match self {
            Self::Transcript => "Transcript",
            Self::Records => "All records",
        }
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
enum Filter {
    #[default]
    All,
    Kind(EntryKind),
    Messages,
    Reasoning,
    Tools,
    Errors,
    Lifecycle,
}

const TRANSCRIPT_FILTERS: [Filter; 7] = [
    Filter::All,
    Filter::Kind(EntryKind::System),
    Filter::Kind(EntryKind::User),
    Filter::Kind(EntryKind::Reasoning),
    Filter::Kind(EntryKind::Assistant),
    Filter::Kind(EntryKind::Tool),
    Filter::Errors,
];

const RECORD_FILTERS: [Filter; 6] = [
    Filter::All,
    Filter::Messages,
    Filter::Reasoning,
    Filter::Tools,
    Filter::Errors,
    Filter::Lifecycle,
];

impl Filter {
    fn next(self, view: View) -> Self {
        let cycle: &[Self] = match view {
            View::Transcript => &TRANSCRIPT_FILTERS,
            View::Records => &RECORD_FILTERS,
        };
        let position = cycle.iter().position(|filter| *filter == self);
        cycle
            .get(position.map_or(0, |position| (position + 1) % cycle.len()))
            .copied()
            .unwrap_or_default()
    }

    fn name(self) -> &'static str {
        match self {
            Self::All => "All types",
            Self::Kind(kind) => kind.lane_label(),
            Self::Messages => "Messages",
            Self::Reasoning => "Reasoning",
            Self::Tools => "Tools",
            Self::Errors => "Errors",
            Self::Lifecycle => "Lifecycle",
        }
    }

    fn matches_entry(self, entry: &TranscriptEntry) -> bool {
        match self {
            Self::Kind(kind) => entry.kind == kind,
            Self::Errors => entry.is_error(),
            _ => true,
        }
    }

    fn matches_event(self, event: &TraceEvent) -> bool {
        let kind = event.kind.to_lowercase();
        match self {
            Self::All | Self::Kind(_) => true,
            Self::Messages => {
                ["user", "assistant", "message", "prompt"]
                    .iter()
                    .any(|label| kind.contains(label))
                    && !kind.contains("reason")
                    && !kind.contains("think")
            }
            Self::Reasoning => kind.contains("reason") || kind.contains("think"),
            Self::Tools => kind.contains("tool") || event.tool_call_id.is_some(),
            Self::Errors => is_error(event),
            Self::Lifecycle => [
                "session",
                "turn",
                "usage",
                "status",
                "system",
                "config",
                "permission",
            ]
            .iter()
            .any(|label| kind.contains(label)),
        }
    }
}

const TAB_NAMES: [&str; 5] = ["Overview", "Detail", "Tool I/O", "Raw JSON", "Artifacts"];

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
enum Scale {
    /// Idle gaps between recorded activity shrink to a sliver.
    #[default]
    Active,
    Wall,
}

const IDLE_GAP_MS: i64 = 2_000;
const MAX_TOOL_ROWS: usize = 2;
const LABEL_WIDTH: u16 = 11;

struct TimelineSpan {
    entry: usize,
    kind: EntryKind,
    row: usize,
    start: f64,
    end: f64,
    /// Fraction of the span spent waiting for the first token.
    wait: f64,
    marker: bool,
    error: bool,
}

/// The transcript projected onto plotted time.
struct TimelineModel {
    spans: Vec<TimelineSpan>,
    /// Plotted positions of removed idle gaps.
    gaps: Vec<f64>,
    end: f64,
    tool_rows: usize,
    active_ms: u64,
}

impl TimelineModel {
    fn build(transcript: &[TranscriptEntry], scale: Scale) -> Option<Self> {
        let timed: Vec<(&TranscriptEntry, i64, i64)> = transcript
            .iter()
            .filter_map(|entry| {
                let start = entry.start_ms?;
                Some((entry, start, entry.end_ms.unwrap_or(start).max(start)))
            })
            .collect();
        let mut intervals: Vec<(i64, i64)> =
            timed.iter().map(|&(_, start, end)| (start, end)).collect();
        intervals.sort_unstable();
        let mut covered: Vec<(i64, i64)> = vec![];
        for (start, end) in intervals {
            match covered.last_mut() {
                Some(last) if start <= last.1 => last.1 = last.1.max(end),
                _ => covered.push((start, end)),
            }
        }
        let origin = covered.first()?.0;
        let active_ms: i64 = covered.iter().map(|(start, end)| end - start).sum();
        let keep = (active_ms as f64 * 0.006).clamp(20.0, IDLE_GAP_MS as f64);
        // (gap start, gap end, time removed before this gap)
        let mut gaps: Vec<(i64, i64, f64)> = vec![];
        if scale == Scale::Active {
            let mut removed = 0.0;
            for pair in covered.windows(2) {
                let &[(_, start), (end, _)] = pair else {
                    continue;
                };
                if end - start > IDLE_GAP_MS {
                    gaps.push((start, end, removed));
                    removed += (end - start) as f64 - keep;
                }
            }
        }
        let project = |time: i64| -> f64 {
            let index = gaps.partition_point(|gap| gap.0 < time);
            let Some(&(start, end, before)) =
                index.checked_sub(1).and_then(|index| gaps.get(index))
            else {
                return (time - origin) as f64;
            };
            if time >= end {
                (time - origin) as f64 - before - ((end - start) as f64 - keep)
            } else {
                (start - origin) as f64 - before
                    + (time - start) as f64 * keep / (end - start) as f64
            }
        };
        // Parallel tool calls stack into rows so no call hides another.
        let mut rows: Vec<usize> = vec![0; timed.len()];
        let mut row_ends: Vec<i64> = vec![];
        let mut tools: Vec<(usize, i64, i64)> = timed
            .iter()
            .enumerate()
            .filter(|(_, (entry, _, _))| entry.kind == EntryKind::Tool)
            .map(|(index, &(_, start, end))| (index, start, end))
            .collect();
        tools.sort_by_key(|&(_, start, end)| (start, end));
        for (index, start, end) in tools {
            let row = row_ends
                .iter()
                .position(|&row_end| row_end <= start)
                .or_else(|| (row_ends.len() < MAX_TOOL_ROWS).then_some(row_ends.len()))
                .or_else(|| {
                    row_ends
                        .iter()
                        .enumerate()
                        .min_by_key(|(_, row_end)| **row_end)
                        .map(|(row, _)| row)
                })
                .unwrap_or(0);
            match row_ends.get_mut(row) {
                Some(row_end) => *row_end = (*row_end).max(end),
                None => row_ends.push(end),
            }
            if let Some(slot) = rows.get_mut(index) {
                *slot = row;
            }
        }
        let spans = timed
            .iter()
            .zip(rows)
            .map(|(&(entry, start, end), row)| TimelineSpan {
                entry: entry.index,
                kind: entry.kind,
                row,
                start: project(start),
                end: project(end),
                wait: entry
                    .wait_ms
                    .filter(|_| end > start)
                    .map_or(0.0, |wait| (wait as f64 / (end - start) as f64).min(1.0)),
                marker: entry.end_ms.is_none() || start == end,
                error: entry.is_error(),
            })
            .collect();
        let end = covered.last().map_or(1.0, |last| project(last.1).max(1.0));
        Some(Self {
            spans,
            gaps: gaps
                .iter()
                .map(|&(start, _, _)| project(start) + keep / 2.0)
                .collect(),
            end,
            tool_rows: row_ends.len().max(1),
            active_ms: u64::try_from(active_ms).unwrap_or(0),
        })
    }

    /// Lane rows plus the axis, excluding the panel border.
    fn rows(&self) -> u16 {
        (4 + self.tool_rows + 1) as u16
    }
}

#[derive(Default)]
pub(crate) struct Explorer {
    view: View,
    /// Indices into the transcript or the raw records, depending on `view`.
    visible: Vec<usize>,
    event_search: Vec<String>,
    entry_search: Vec<String>,
    list: ListState,
    filter: Filter,
    turn: Option<u64>,
    query: String,
    search_before: String,
    searching: bool,
    detail_focus: bool,
    tab: usize,
    scroll: usize,
    viewport_height: usize,
    list_page: usize,
    detail_lines: Vec<String>,
    detail_key: Option<(View, Option<usize>, usize, u16)>,
    help: bool,
    scale: Scale,
    timeline: Option<TimelineModel>,
    /// Visible plotted range when zoomed in.
    zoom: Option<(f64, f64)>,
}

impl Explorer {
    pub(crate) fn new(data: &TraceData) -> Self {
        let mut state = Self {
            view: if data.transcript.is_empty() {
                View::Records
            } else {
                View::Transcript
            },
            event_search: data
                .events
                .iter()
                .map(|event| {
                    format!(
                        "{} {} {} {} {} {}",
                        event.kind,
                        event.title,
                        event.text,
                        event.source,
                        event.status.as_deref().unwrap_or(""),
                        event.raw
                    )
                    .to_lowercase()
                })
                .collect(),
            entry_search: data
                .transcript
                .iter()
                .map(|entry| {
                    let tools = tools_for(data, entry.tool_call_id.as_deref())
                        .map(|tool| format!("{:?} {:?}", tool.input, tool.output))
                        .collect::<Vec<_>>()
                        .join(" ");
                    format!(
                        "{} {} {} {} {} {tools}",
                        entry.kind.label(),
                        entry.title,
                        entry.text,
                        entry.status.as_deref().unwrap_or(""),
                        entry.tool_call_id.as_deref().unwrap_or("")
                    )
                    .to_lowercase()
                })
                .collect(),
            timeline: TimelineModel::build(&data.transcript, Scale::Active),
            tab: 1,
            ..Self::default()
        };
        state.refilter(data);
        state
    }

    fn len(&self, data: &TraceData) -> usize {
        match self.view {
            View::Transcript => data.transcript.len(),
            View::Records => data.events.len(),
        }
    }

    fn turn_of(&self, data: &TraceData, index: usize) -> Option<u64> {
        match self.view {
            View::Transcript => data.transcript.get(index).and_then(|entry| entry.turn),
            View::Records => data.events.get(index).and_then(|event| event.turn),
        }
    }

    fn is_error_at(&self, data: &TraceData, index: usize) -> bool {
        match self.view {
            View::Transcript => data
                .transcript
                .get(index)
                .is_some_and(TranscriptEntry::is_error),
            View::Records => data.events.get(index).is_some_and(is_error),
        }
    }

    fn selected(&self) -> Option<usize> {
        self.list
            .selected()
            .and_then(|index| self.visible.get(index))
            .copied()
    }

    fn selected_entry(&self) -> Option<usize> {
        (self.view == View::Transcript)
            .then(|| self.selected())
            .flatten()
    }

    fn tab_name(&self) -> &'static str {
        TAB_NAMES.get(self.tab).copied().unwrap_or("Detail")
    }

    fn refilter(&mut self, data: &TraceData) {
        let previous = self.selected();
        let query = self.query.to_lowercase();
        let matches_query = |search: &[String], index: usize| {
            query.is_empty() || search.get(index).is_some_and(|text| text.contains(&query))
        };
        self.visible = match self.view {
            View::Transcript => data
                .transcript
                .iter()
                .enumerate()
                .filter(|(index, entry)| {
                    self.filter.matches_entry(entry)
                        && self.turn.is_none_or(|turn| entry.turn == Some(turn))
                        && matches_query(&self.entry_search, *index)
                })
                .map(|(index, _)| index)
                .collect(),
            View::Records => data
                .events
                .iter()
                .enumerate()
                .filter(|(index, event)| {
                    self.filter.matches_event(event)
                        && self.turn.is_none_or(|turn| event.turn == Some(turn))
                        && matches_query(&self.event_search, *index)
                })
                .map(|(index, _)| index)
                .collect(),
        };
        let selected = previous
            .and_then(|previous| self.visible.iter().position(|&index| index == previous))
            .or_else(|| (!self.visible.is_empty()).then_some(0));
        self.list.select(selected);
        self.scroll = 0;
        self.detail_key = None;
    }

    fn select(&mut self, index: usize) {
        if self.visible.is_empty() {
            return;
        }
        self.list.select(Some(index.min(self.visible.len() - 1)));
        self.scroll = 0;
    }

    fn select_item(&mut self, item: usize) {
        if let Some(position) = self.visible.iter().position(|&index| index == item) {
            self.select(position);
        }
    }

    fn move_selection(&mut self, amount: isize) {
        self.select(
            self.list
                .selected()
                .unwrap_or(0)
                .saturating_add_signed(amount),
        );
    }

    fn scroll_detail(&mut self, amount: isize) {
        self.scroll = self
            .scroll
            .saturating_add_signed(amount)
            .min(self.detail_lines.len().saturating_sub(self.viewport_height));
    }

    fn clear_filters(&mut self, data: &TraceData) {
        self.filter = Filter::All;
        self.turn = None;
        self.query.clear();
        self.refilter(data);
    }

    /// Switch lists, keeping the same moment selected where one maps to the other.
    fn toggle_view(&mut self, data: &TraceData) {
        let selected = self.selected();
        let target = match self.view {
            View::Transcript => {
                self.view = View::Records;
                selected
                    .and_then(|index| data.transcript.get(index))
                    .and_then(|entry| entry.event_indices.first().copied())
            }
            View::Records if !data.transcript.is_empty() => {
                self.view = View::Transcript;
                selected.and_then(|event| {
                    data.transcript
                        .iter()
                        .position(|entry| entry.event_indices.contains(&event))
                })
            }
            View::Records => return,
        };
        self.clear_filters(data);
        if let Some(target) = target {
            self.select_item(target);
        }
    }

    fn next_error(&mut self, data: &TraceData) {
        let len = self.len(data);
        if len == 0 {
            return;
        }
        let start = self.selected().map_or(0, |index| index + 1);
        let next = (start..len)
            .chain(0..start.min(len))
            .find(|&index| self.is_error_at(data, index));
        if let Some(index) = next {
            self.clear_filters(data);
            self.select(index);
            self.tab = 1;
        }
    }

    fn next_turn(&mut self, data: &TraceData, forward: bool) {
        let Some(selected) = self.list.selected() else {
            return;
        };
        let turn_at = |position: usize| {
            self.visible
                .get(position)
                .and_then(|&index| self.turn_of(data, index))
        };
        let turn = turn_at(selected);
        let next = if forward {
            (selected + 1..self.visible.len()).find(|&index| turn_at(index) != turn)
        } else {
            (0..selected)
                .rev()
                .find(|&index| turn_at(index) != turn)
                .map(|index| {
                    let target = turn_at(index);
                    (0..=index)
                        .rev()
                        .take_while(|&index| turn_at(index) == target)
                        .last()
                        .unwrap_or(index)
                })
        };
        if let Some(index) = next {
            self.select(index);
        }
    }

    fn zoom(&mut self, factor: f64) {
        let Some(model) = &self.timeline else { return };
        let (start, end) = self.zoom.unwrap_or((0.0, model.end));
        let center = self
            .selected_entry()
            .and_then(|entry| model.spans.iter().find(|span| span.entry == entry))
            .map_or((start + end) / 2.0, |span| (span.start + span.end) / 2.0);
        let span = ((end - start) * factor).max((model.end / 5_000.0).max(5.0));
        self.set_zoom(center - span / 2.0, span);
    }

    fn set_zoom(&mut self, start: f64, span: f64) {
        let Some(model) = &self.timeline else { return };
        self.zoom = (span < model.end * 0.999).then(|| {
            let start = start.clamp(0.0, model.end - span);
            (start, start + span)
        });
    }

    /// Keep the selected entry inside a zoomed timeline.
    fn follow_selection(&mut self) {
        let (Some((start, end)), Some(entry), Some(model)) =
            (self.zoom, self.selected_entry(), &self.timeline)
        else {
            return;
        };
        let Some(span) = model.spans.iter().find(|span| span.entry == entry) else {
            return;
        };
        if span.end < start || span.start > end {
            let width = end - start;
            self.set_zoom(span.start - width * 0.2, width);
        }
    }

    /// Returns true only when the explorer should close.
    pub(crate) fn key(&mut self, data: &TraceData, key: KeyEvent) -> bool {
        if self.help {
            self.help = false;
            return false;
        }
        if self.searching {
            match key.code {
                KeyCode::Esc => {
                    self.query.clone_from(&self.search_before);
                    self.searching = false;
                }
                KeyCode::Enter => self.searching = false,
                KeyCode::Backspace => {
                    self.query.pop();
                }
                KeyCode::Char('u') if key.modifiers.contains(KeyModifiers::CONTROL) => {
                    self.query.clear()
                }
                KeyCode::Char(ch)
                    if !key
                        .modifiers
                        .intersects(KeyModifiers::CONTROL | KeyModifiers::ALT) =>
                {
                    self.query.push(ch)
                }
                _ => return false,
            }
            self.refilter(data);
            return false;
        }
        let page = if self.detail_focus {
            self.viewport_height
        } else {
            self.list_page
        }
        .max(1) as isize;
        match key.code {
            KeyCode::Char('q') => return true,
            KeyCode::Char('?') => self.help = true,
            KeyCode::Char('/') => {
                self.search_before.clone_from(&self.query);
                self.searching = true;
            }
            KeyCode::Esc => {
                if self.query.is_empty() && self.filter == Filter::All && self.turn.is_none() {
                    return true;
                }
                self.clear_filters(data);
            }
            KeyCode::Char('v') => self.toggle_view(data),
            KeyCode::Char('f') => {
                self.filter = self.filter.next(self.view);
                self.refilter(data);
            }
            KeyCode::Char('t') => {
                self.turn = if self.turn.is_some() {
                    None
                } else {
                    self.selected().and_then(|index| self.turn_of(data, index))
                };
                self.refilter(data);
            }
            KeyCode::Char('e') => self.next_error(data),
            KeyCode::Char('[') => self.next_turn(data, false),
            KeyCode::Char(']') => self.next_turn(data, true),
            KeyCode::Char('+' | '=') => self.zoom(0.5),
            KeyCode::Char('-' | '_') => self.zoom(2.0),
            KeyCode::Char('0') => self.zoom = None,
            KeyCode::Char('w') => {
                self.scale = match self.scale {
                    Scale::Active => Scale::Wall,
                    Scale::Wall => Scale::Active,
                };
                self.timeline = TimelineModel::build(&data.transcript, self.scale);
                self.zoom = None;
            }
            KeyCode::Tab | KeyCode::BackTab | KeyCode::Enter => {
                self.detail_focus = !self.detail_focus
            }
            KeyCode::Char('1'..='5') => {
                if let KeyCode::Char(number) = key.code {
                    self.tab = number as usize - '1' as usize;
                }
                self.detail_focus = true;
                self.scroll = 0;
            }
            KeyCode::Left | KeyCode::Char('h') => {
                self.tab = (self.tab + TAB_NAMES.len() - 1) % TAB_NAMES.len();
                self.detail_focus = true;
                self.scroll = 0;
            }
            KeyCode::Right | KeyCode::Char('l') => {
                self.tab = (self.tab + 1) % TAB_NAMES.len();
                self.detail_focus = true;
                self.scroll = 0;
            }
            KeyCode::Char('J') => self.scroll_detail(1),
            KeyCode::Char('K') => self.scroll_detail(-1),
            KeyCode::Down | KeyCode::Char('j') => {
                if self.detail_focus {
                    self.scroll_detail(1);
                } else {
                    self.move_selection(1);
                }
            }
            KeyCode::Up | KeyCode::Char('k') => {
                if self.detail_focus {
                    self.scroll_detail(-1);
                } else {
                    self.move_selection(-1);
                }
            }
            KeyCode::PageDown | KeyCode::Char('d') => {
                if self.detail_focus {
                    self.scroll_detail(page);
                } else {
                    self.move_selection(page);
                }
            }
            KeyCode::PageUp | KeyCode::Char('u') => {
                if self.detail_focus {
                    self.scroll_detail(-page);
                } else {
                    self.move_selection(-page);
                }
            }
            KeyCode::Home | KeyCode::Char('g') => {
                if self.detail_focus {
                    self.scroll = 0;
                } else {
                    self.select(0);
                }
            }
            KeyCode::End | KeyCode::Char('G') => {
                if self.detail_focus {
                    self.scroll = self.detail_lines.len().saturating_sub(self.viewport_height);
                } else {
                    self.select(self.visible.len().saturating_sub(1));
                }
            }
            _ => {}
        }
        false
    }
}

fn tools_for<'a>(data: &'a TraceData, id: Option<&'a str>) -> impl Iterator<Item = &'a TraceTool> {
    data.tools
        .iter()
        .filter(move |tool| id.is_some_and(|id| tool.id == id))
}

fn is_error(event: &TraceEvent) -> bool {
    let status = event.status.as_deref().unwrap_or("").to_lowercase();
    let kind = event.kind.to_lowercase();
    ["error", "fail", "cancel", "reject", "denied"]
        .iter()
        .any(|word| status.contains(word) || kind.contains(word))
}

fn lane_color(kind: EntryKind, theme: &Theme) -> Color {
    match kind {
        EntryKind::System => theme.gray,
        EntryKind::User => theme.accent_user,
        EntryKind::Reasoning => theme.accent_verify,
        EntryKind::Assistant => theme.accent_success,
        EntryKind::Tool => theme.path,
    }
}

fn entry_color(entry: &TranscriptEntry, theme: &Theme) -> Color {
    if entry.is_error() {
        theme.accent_error
    } else {
        lane_color(entry.kind, theme)
    }
}

fn entry_encryption(entry: &TranscriptEntry) -> Encryption {
    if entry.kind == EntryKind::Reasoning {
        entry.encryption
    } else {
        Encryption::None
    }
}

fn event_encryption(event: &TraceEvent) -> Encryption {
    if super::data::is_reasoning_kind(&event.kind) {
        event.encryption
    } else {
        Encryption::None
    }
}

fn encryption_label(encryption: Encryption) -> &'static str {
    match encryption {
        Encryption::None => "no",
        Encryption::Partial => "summary only (full reasoning is encrypted)",
        Encryption::Full => "yes (readable reasoning is unavailable)",
    }
}

fn encrypted_title(title: &str, encryption: Encryption) -> String {
    match encryption {
        Encryption::None => title.to_owned(),
        Encryption::Partial => format!("🔒 {title} · summary"),
        Encryption::Full => format!("🔒 {title}"),
    }
}

fn event_color(event: &TraceEvent, theme: &Theme) -> Color {
    if is_error(event) {
        return theme.accent_error;
    }
    if Filter::Tools.matches_event(event) {
        return theme.path;
    }
    if Filter::Reasoning.matches_event(event) {
        return theme.accent_verify;
    }
    if event.kind.contains("user") {
        return theme.accent_user;
    }
    if event.kind.contains("assistant") {
        return theme.accent_success;
    }
    theme.accent_system
}

fn panel(title: String, focused: bool, theme: &Theme) -> Block<'static> {
    Block::default()
        .title(title)
        .borders(Borders::ALL)
        .border_type(BorderType::Rounded)
        .border_style(Style::default().fg(if focused {
            theme.selection_border
        } else {
            theme.gray_dim
        }))
        .style(Style::default().bg(theme.bg_base).fg(theme.text_primary))
}

pub(crate) fn render(
    area: Rect,
    buf: &mut Buffer,
    data: &TraceData,
    state: &mut Explorer,
    theme: &Theme,
) {
    Block::default()
        .style(Style::default().bg(theme.bg_base).fg(theme.text_primary))
        .render(area, buf);
    if area.width < 24 || area.height < 8 {
        Paragraph::new("Trace explorer\nResize to at least 24 × 8.\nq exits").render(area, buf);
        return;
    }
    let lanes_height = state
        .timeline
        .as_ref()
        .filter(|_| area.height >= 24)
        .map_or(0, |model| model.rows() + 2);
    let [
        header_area,
        lanes_area,
        search_area,
        content_area,
        footer_area,
    ] = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Length(2),
            Constraint::Length(lanes_height),
            Constraint::Length(1),
            Constraint::Min(3),
            Constraint::Length(1),
        ])
        .areas(area);
    render_header(header_area, buf, data, state, theme);
    if lanes_height > 0 {
        state.follow_selection();
        render_lanes(lanes_area, buf, data, state, theme);
    }
    render_search(search_area, buf, data, state, theme);
    let compact = area.width < 90;
    if compact {
        if state.detail_focus {
            render_detail(content_area, buf, data, state, theme);
        } else {
            render_list(content_area, buf, data, state, theme);
        }
    } else {
        let [list_area, detail_area] = Layout::default()
            .direction(Direction::Horizontal)
            .constraints([Constraint::Percentage(40), Constraint::Percentage(60)])
            .areas(content_area);
        render_list(list_area, buf, data, state, theme);
        render_detail(detail_area, buf, data, state, theme);
    }
    let hint = if state.searching {
        " Type to search · Enter apply · Esc cancel · Ctrl-U clear"
    } else if area.width < 70 {
        " q close  / search  Tab view  ? help"
    } else if area.width < 110 {
        " ↑↓ navigate  Tab focus  v records  +/- zoom  / search  e error  ? help  q close"
    } else {
        " ↑↓/jk navigate  Tab focus  1–5 views  v transcript/records  +/-/0 zoom  w scale  / search  f filter  e error  ? help  q close"
    };
    Paragraph::new(hint)
        .style(Style::default().fg(theme.text_secondary))
        .render(footer_area, buf);
    if state.help {
        render_help(area, buf, theme);
    }
}

fn render_header(area: Rect, buf: &mut Buffer, data: &TraceData, state: &Explorer, theme: &Theme) {
    let summary = &data.summary;
    let first = Line::from(vec![
        Span::styled(
            " crok ",
            Style::default()
                .fg(theme.text_primary)
                .add_modifier(Modifier::BOLD),
        ),
        Span::styled("/ trace  ", Style::default().fg(theme.text_secondary)),
        Span::styled(
            clean(&data.title),
            Style::default()
                .fg(theme.text_primary)
                .add_modifier(Modifier::BOLD),
        ),
    ]);
    let muted = Style::default().fg(theme.text_secondary);
    let mut second = if data.transcript.is_empty() {
        vec![Span::styled(
            format!(
                " {} turns   {} records   {} tools   ",
                summary.turn_count, summary.event_count, summary.tool_count
            ),
            muted,
        )]
    } else {
        let tools = data
            .transcript
            .iter()
            .filter(|entry| entry.kind == EntryKind::Tool)
            .count();
        vec![Span::styled(
            format!(
                " {} entries   {} turns   {tools} tool calls   ",
                data.transcript.len(),
                summary.turn_count
            ),
            muted,
        )]
    };
    let errors = match state.view {
        View::Transcript => data
            .transcript
            .iter()
            .filter(|entry| entry.is_error())
            .count(),
        View::Records => summary.error_count,
    };
    second.push(Span::styled(
        format!("{errors} errors"),
        Style::default().fg(if errors > 0 {
            theme.accent_error
        } else {
            theme.text_secondary
        }),
    ));
    if let Some(model) = &state.timeline {
        second.push(Span::styled(
            format!("   {} active", duration(Some(model.active_ms))),
            muted,
        ));
    }
    second.push(Span::styled(
        format!("   {} recorded", duration(summary.duration_ms)),
        muted,
    ));
    if let Some(tokens) = summary.total_tokens {
        second.push(Span::styled(
            format!("   {tokens} tokens"),
            Style::default().fg(theme.accent_model),
        ));
    }
    if !data.warnings.is_empty() {
        second.push(Span::styled(
            format!("   {} notes", data.warnings.len()),
            Style::default().fg(theme.warning),
        ));
    }
    Paragraph::new(vec![first, Line::from(second)]).render(area, buf);
}

/// One row per transcript type; each bar spans the entry's recorded execution time.
fn render_lanes(area: Rect, buf: &mut Buffer, data: &TraceData, state: &Explorer, theme: &Theme) {
    let Some(model) = &state.timeline else { return };
    let (start, end) = state.zoom.unwrap_or((0.0, model.end));
    let mut title = format!(
        " Timeline · {} · {} active ",
        match state.scale {
            Scale::Active => "active time",
            Scale::Wall => "wall clock",
        },
        duration(Some(model.active_ms))
    );
    if state.zoom.is_some() {
        title.push_str("· zoomed (0 resets) ");
    }
    let block = panel(title, false, theme);
    let inner = block.inner(area);
    block.render(area, buf);
    if inner.width <= LABEL_WIDTH + 4 || inner.height == 0 {
        return;
    }
    let track_x = inner.x + LABEL_WIDTH;
    let width = inner.width - LABEL_WIDTH;
    let lane_top = |kind: EntryKind| -> u16 {
        match kind {
            EntryKind::System => 0,
            EntryKind::User => 1,
            EntryKind::Reasoning => 2,
            EntryKind::Assistant => 3,
            EntryKind::Tool => 4,
        }
    };
    let rows = model.rows().min(inner.height);
    let axis_row = model.rows() - 1;
    for kind in EntryKind::ALL {
        let top = lane_top(kind);
        let rows_for_lane = if kind == EntryKind::Tool {
            model.tool_rows as u16
        } else {
            1
        };
        let label_row = top + (rows_for_lane - 1) / 2;
        if label_row < rows {
            buf.set_stringn(
                inner.x + 1,
                inner.y + label_row,
                kind.lane_label(),
                LABEL_WIDTH as usize - 2,
                Style::default().fg(lane_color(kind, theme)),
            );
        }
    }
    let column = |time: f64| (time - start) / (end - start).max(f64::EPSILON) * f64::from(width);
    let dim = Style::default().fg(theme.gray_dim);
    for &gap in &model.gaps {
        let x = column(gap).floor();
        if x < 0.0 || x >= f64::from(width) {
            continue;
        }
        for row in 0..axis_row.min(rows) {
            buf.set_string(track_x + x as u16, inner.y + row, "┊", dim);
        }
    }
    let selected = state.selected_entry();
    let filtered: Option<std::collections::HashSet<usize>> = (state.view == View::Transcript
        && state.visible.len() != data.transcript.len())
    .then(|| state.visible.iter().copied().collect());
    // The selected bar draws last so an overlapping bar never hides it.
    let mut order: Vec<&TimelineSpan> = model.spans.iter().collect();
    order.sort_by_key(|span| Some(span.entry) == selected);
    for span in order {
        let row = lane_top(span.kind) + span.row as u16;
        if row >= rows.min(axis_row) {
            continue;
        }
        let (x0, x1) = (column(span.start), column(span.end));
        // An instant at the very end of the range still gets the last column.
        if x1 < 0.0 || x0 > f64::from(width) {
            continue;
        }
        let first = (x0.floor().max(0.0) as u16).min(width - 1);
        let last = if span.marker {
            first + 1
        } else {
            (x1.ceil() as u16).clamp(first + 1, width)
        };
        let wait_end = x0 + (x1 - x0) * span.wait;
        let color = if Some(span.entry) == selected {
            theme.text_primary
        } else if filtered
            .as_ref()
            .is_some_and(|visible| !visible.contains(&span.entry))
        {
            theme.gray_dim
        } else if span.error {
            theme.accent_error
        } else {
            lane_color(span.kind, theme)
        };
        for x in first..last.min(width) {
            let symbol = if span.marker {
                "┃"
            } else if span.wait > 0.0 && f64::from(x) + 0.5 < wait_end {
                "░"
            } else {
                "█"
            };
            buf.set_string(
                track_x + x,
                inner.y + row,
                symbol,
                Style::default().fg(color),
            );
        }
    }
    if axis_row < rows {
        render_axis(buf, track_x, inner.y + axis_row, width, start, end, dim);
    }
}

fn render_axis(buf: &mut Buffer, x: u16, y: u16, width: u16, start: f64, end: f64, style: Style) {
    const STEPS: [f64; 22] = [
        1.0, 2.0, 5.0, 10.0, 20.0, 50.0, 100.0, 200.0, 500.0, 1e3, 2e3, 5e3, 1e4, 15e3, 3e4, 6e4,
        12e4, 3e5, 6e5, 18e5, 36e5, 72e5,
    ];
    let span = (end - start).max(1.0);
    let step = STEPS
        .iter()
        .copied()
        .find(|step| span / step <= f64::from(width) / 12.0)
        .unwrap_or(144e5);
    let mut next_free = 0u16;
    let mut value = (start / step).ceil() * step;
    while value <= end {
        let column = ((value - start) / span * f64::from(width)).round() as u16;
        let label = axis_label(value);
        if column >= next_free && column as usize + label.len() <= width as usize {
            buf.set_string(x + column, y, &label, style);
            next_free = column + label.len() as u16 + 2;
        }
        value += step;
    }
}

fn axis_label(ms: f64) -> String {
    if ms <= 0.0 {
        return "0".to_owned();
    }
    if ms < 1_000.0 {
        return format!("{}ms", ms.round());
    }
    let seconds = (ms / 100.0).round() / 10.0;
    if seconds < 60.0 {
        return format!("{seconds}s");
    }
    let minutes = (seconds / 60.0).floor();
    let rest = (seconds - minutes * 60.0).round();
    if minutes < 60.0 {
        return if rest > 0.0 {
            format!("{minutes}m{rest}s")
        } else {
            format!("{minutes}m")
        };
    }
    format!("{}h{}m", (minutes / 60.0).floor(), minutes % 60.0)
}

fn render_search(area: Rect, buf: &mut Buffer, data: &TraceData, state: &Explorer, theme: &Theme) {
    let turn = state
        .turn
        .map_or_else(String::new, |turn| format!(" · turn {turn}"));
    let prefix = format!(
        " {} · {}{turn} · {}/{}  ",
        state.view.name(),
        state.filter.name(),
        state.visible.len(),
        state.len(data)
    );
    let search = if state.searching {
        format!("/{}▏", clean(&state.query))
    } else if state.query.is_empty() {
        match state.view {
            View::Transcript => " / to search the transcript · v all records".to_owned(),
            View::Records => " / to search record text and raw fields · v transcript".to_owned(),
        }
    } else {
        format!("/{}", clean(&state.query))
    };
    Paragraph::new(Line::from(vec![
        Span::styled(prefix, Style::default().fg(theme.accent_system)),
        Span::styled(
            search,
            Style::default().fg(if state.searching {
                theme.fuzzy_accent
            } else {
                theme.text_secondary
            }),
        ),
    ]))
    .style(Style::default().bg(theme.bg_light))
    .render(area, buf);
}

fn render_list(
    area: Rect,
    buf: &mut Buffer,
    data: &TraceData,
    state: &mut Explorer,
    theme: &Theme,
) {
    let title = format!(
        " {} · {}/{} ",
        state.view.name(),
        state.list.selected().map_or(0, |index| index + 1),
        state.visible.len()
    );
    let block = panel(title, !state.detail_focus, theme);
    state.list_page = (block.inner(area).height as usize / 2).max(1);
    if state.visible.is_empty() {
        let message = if state.len(data) == 0 {
            match state.view {
                View::Transcript => "No transcript was recorded.\nv shows all raw records.",
                View::Records => "No records.",
            }
        } else {
            "No matching entries.\nEsc clears all filters."
        };
        Paragraph::new(message).block(block).render(area, buf);
        return;
    }
    let selected = state.list.selected().unwrap_or(0);
    let offset = state
        .list
        .offset()
        .min(selected)
        .max(selected.saturating_sub(state.list_page - 1));
    *state.list.offset_mut() = offset;
    let origin = data
        .transcript
        .iter()
        .filter_map(|entry| entry.start_ms)
        .min();
    // Build only the viewport, even for recordings with tens of thousands of records.
    let items: Vec<ListItem<'_>> = state
        .visible
        .iter()
        .enumerate()
        .skip(offset)
        .take(state.list_page)
        .filter_map(|(position, &index)| {
            let turn = state.turn_of(data, index);
            let turn_marker = position == 0
                || state
                    .visible
                    .get(position - 1)
                    .and_then(|&previous| state.turn_of(data, previous))
                    != turn;
            let turn = turn.map_or_else(|| "—".to_owned(), |turn| turn.to_string());
            let marker = if turn_marker { "┌ " } else { "  " };
            let lines = match state.view {
                View::Transcript => {
                    let entry = data.transcript.get(index)?;
                    let color = entry_color(entry, theme);
                    let timing = match (entry.start_ms, origin) {
                        (Some(start), Some(origin)) => {
                            let offset = u64::try_from(start - origin).ok();
                            match entry.duration_ms().filter(|&ms| ms > 0) {
                                Some(ms) => {
                                    format!("+{}  Δ {}", duration(offset), duration(Some(ms)))
                                }
                                None => format!("+{}", duration(offset)),
                            }
                        }
                        _ => "untimed".to_owned(),
                    };
                    vec![
                        Line::from(vec![
                            Span::styled(
                                format!(
                                    "{} {:<9} ",
                                    if entry.is_error() { "!" } else { "●" },
                                    entry.kind.label()
                                ),
                                Style::default().fg(color),
                            ),
                            Span::styled(
                                encrypted_title(&clean(&entry.title), entry_encryption(entry)),
                                Style::default().fg(color).add_modifier(Modifier::BOLD),
                            ),
                            Span::styled(
                                format!("  {}", preview(&entry.text)),
                                Style::default().fg(theme.text_secondary),
                            ),
                        ]),
                        Line::from(Span::styled(
                            format!("  {marker}T{turn}  {timing}"),
                            Style::default().fg(theme.text_secondary),
                        )),
                    ]
                }
                View::Records => {
                    let event = data.events.get(index)?;
                    let status = if is_error(event) { "!" } else { "·" };
                    vec![
                        Line::from(vec![
                            Span::styled(
                                format!("{status} {:04} ", event.index),
                                Style::default().fg(event_color(event, theme)),
                            ),
                            Span::styled(
                                encrypted_title(&clean(&event.title), event_encryption(event)),
                                Style::default()
                                    .fg(event_color(event, theme))
                                    .add_modifier(Modifier::BOLD),
                            ),
                        ]),
                        Line::from(Span::styled(
                            format!(
                                "       {marker}T{turn}  {}  {}",
                                clean(&event.kind),
                                event.duration_ms.map_or_else(
                                    || format!("+{}", duration(event.elapsed_ms)),
                                    |ms| format!("Δ {}", duration(Some(ms)))
                                )
                            ),
                            Style::default().fg(theme.text_secondary),
                        )),
                    ]
                }
            };
            Some(ListItem::new(lines))
        })
        .collect();
    let mut window = ListState::default().with_selected(Some(selected - offset));
    StatefulWidget::render(
        List::new(items)
            .block(block)
            .highlight_style(Style::default().bg(theme.bg_highlight))
            .highlight_symbol("› "),
        area,
        buf,
        &mut window,
    );
}

fn render_detail(
    area: Rect,
    buf: &mut Buffer,
    data: &TraceData,
    state: &mut Explorer,
    theme: &Theme,
) {
    let block = panel(
        format!(
            " {} · {} ",
            state.tab_name(),
            if state.detail_focus {
                "focused"
            } else {
                "Tab to focus"
            }
        ),
        state.detail_focus,
        theme,
    );
    let inner = block.inner(area);
    block.render(area, buf);
    if inner.height == 0 || inner.width == 0 {
        return;
    }
    let [tabs_area, lines_area, scroll_area] = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Length(u16::from(inner.height >= 3)),
            Constraint::Min(0),
            Constraint::Length(u16::from(inner.height >= 5)),
        ])
        .areas(inner);
    let names = if inner.width < 55 {
        vec!["1 Info", "2 Detail", "3 I/O", "4 JSON", "5 Files"]
    } else {
        vec![
            "1 Overview",
            "2 Detail",
            "3 Tool I/O",
            "4 Raw JSON",
            "5 Artifacts",
        ]
    };
    Tabs::new(names)
        .select(state.tab)
        .divider(" ")
        .style(Style::default().fg(theme.text_secondary))
        .highlight_style(
            Style::default()
                .fg(theme.text_primary)
                .bg(theme.bg_highlight)
                .add_modifier(Modifier::BOLD),
        )
        .render(tabs_area, buf);
    let key = (state.view, state.selected(), state.tab, lines_area.width);
    if state.detail_key != Some(key) {
        let content = match state.view {
            View::Transcript => entry_content(data, state.selected(), state.tab),
            View::Records => detail_content(data, state.selected(), state.tab),
        };
        let width = lines_area.width.max(1) as usize;
        // Slice wrapped lines ourselves: Paragraph's u16 scroll would make long tool output unreachable.
        state.detail_lines = clean(&content)
            .lines()
            .flat_map(|line| {
                if line.is_empty() {
                    vec![String::new()]
                } else {
                    textwrap::wrap(line, width)
                        .into_iter()
                        .map(|line| line.into_owned())
                        .collect()
                }
            })
            .collect();
        state.detail_key = Some(key);
    }
    state.viewport_height = lines_area.height as usize;
    state.scroll = state.scroll.min(
        state
            .detail_lines
            .len()
            .saturating_sub(state.viewport_height),
    );
    let lines: Vec<Line<'_>> = state
        .detail_lines
        .iter()
        .skip(state.scroll)
        .take(state.viewport_height)
        .map(|line| Line::raw(line.as_str()))
        .collect();
    Paragraph::new(lines)
        .style(Style::default().fg(theme.text_primary))
        .render(lines_area, buf);
    Paragraph::new(format!(
        " {}–{} / {} lines  ·  J/K scroll",
        if state.detail_lines.is_empty() {
            0
        } else {
            state.scroll + 1
        },
        (state.scroll + state.viewport_height).min(state.detail_lines.len()),
        state.detail_lines.len()
    ))
    .style(Style::default().fg(theme.gray))
    .render(scroll_area, buf);
}

fn artifacts(data: &TraceData) -> String {
    let mut text = format!(
        "RECORDED ARTIFACTS · {}\n\nThese are captured snapshots; files are not executed or opened.\n",
        data.artifacts.len()
    );
    if data.artifacts.is_empty() {
        text.push_str("\nNo artifact snapshots were recorded.\n");
    }
    for artifact in &data.artifacts {
        text.push_str(&format!(
            "\n── {} ──\n{}\n",
            artifact.name,
            display_value(&artifact.content)
        ));
    }
    text
}

fn tool_io<'a>(tools: impl Iterator<Item = &'a TraceTool>) -> Option<String> {
    let sections: Vec<String> = tools.map(|tool| format!(
        "{}\n\nCall ID     {}\nStatus      {}\nTurn        {}\nDuration    {}\nRecords     {}\n\nINPUT\n{}\n\nOUTPUT\n{}",
        tool.name, tool.id, tool.status, optional_number(tool.turn), duration(tool.duration_ms),
        tool.event_indices.iter().map(usize::to_string).collect::<Vec<_>>().join(", "),
        tool.input.as_ref().map_or_else(|| "Not recorded".to_owned(), display_value),
        tool.output.as_ref().map_or_else(|| "Not recorded (the call may be incomplete)".to_owned(), display_value)
    )).collect();
    (!sections.is_empty()).then(|| sections.join("\n\n────────────────────\n\n"))
}

fn clock(ms: Option<i64>) -> String {
    ms.and_then(chrono::DateTime::from_timestamp_millis)
        .map_or_else(
            || "Not recorded".to_owned(),
            |time| time.format("%Y-%m-%d %H:%M:%S%.3f UTC").to_string(),
        )
}

fn entry_content(data: &TraceData, selected: Option<usize>, tab: usize) -> String {
    if tab == 0 {
        return overview(data);
    }
    if tab == 4 {
        return artifacts(data);
    }
    let Some(entry) = selected.and_then(|index| data.transcript.get(index)) else {
        return "No entry selected.\n\nPress Esc to clear filters, or 1 for the session overview."
            .to_owned();
    };
    let records = || {
        entry
            .event_indices
            .iter()
            .filter_map(|&index| data.events.get(index))
    };
    if tab == 3 {
        return records()
            .map(|event| {
                format!(
                    "── {}{} · {} ──\n{}",
                    event.source,
                    event
                        .line
                        .map_or_else(String::new, |line| format!(":{line}")),
                    event.kind,
                    pretty(&event.raw)
                )
            })
            .collect::<Vec<_>>()
            .join("\n\n");
    }
    let tools = tool_io(tools_for(data, entry.tool_call_id.as_deref()));
    if tab == 2 {
        return tools.unwrap_or_else(|| "This entry is not a tool call.\n\nPress f to filter the transcript to tools.\nRaw JSON retains every recorded field.".to_owned());
    }
    let sources = records()
        .map(|event| {
            format!(
                "{}{}",
                event.source,
                event
                    .line
                    .map_or_else(String::new, |line| format!(":{line}"))
            )
        })
        .collect::<Vec<_>>()
        .join(", ");
    let body = match tools {
        Some(tools) => tools,
        None if entry.text.is_empty() => "No text was recorded.".to_owned(),
        None => format!("CONTENT\n{}", entry.text),
    };
    format!(
        "{}\n\nType        {}\nEncrypted   {}\nTurn        {}\nStatus      {}\nStarted     {}\nEnded       {}\nDuration    {}\nFirst token {}\nRecorded in {}\n\n{body}",
        entry.title,
        entry.kind.label(),
        encryption_label(entry_encryption(entry)),
        optional_number(entry.turn),
        entry.status.as_deref().unwrap_or("—"),
        clock(entry.start_ms),
        match (entry.start_ms, entry.end_ms) {
            (Some(_), None) => "No completion recorded".to_owned(),
            (_, end) => clock(end),
        },
        duration(entry.duration_ms()),
        entry.wait_ms.map_or_else(
            || "—".to_owned(),
            |ms| format!("after {}", duration(Some(ms)))
        ),
        sources
    )
}

fn detail_content(data: &TraceData, selected: Option<usize>, tab: usize) -> String {
    if tab == 0 {
        return overview(data);
    }
    if tab == 4 {
        return artifacts(data);
    }
    let Some(event) = selected.and_then(|index| data.events.get(index)) else {
        return "No record selected.\n\nPress Esc to clear filters, or 1 for the session overview."
            .to_owned();
    };
    if tab == 3 {
        return pretty(&event.raw);
    }
    if tab == 2 {
        return tool_io(data.tools.iter().filter(|tool| {
            event.tool_call_id.as_deref() == Some(tool.id.as_str())
                || tool.event_indices.contains(&event.index)
        }))
        .unwrap_or_else(|| "This record has no linked tool call.\n\nPress f to filter the list to tools.\nRaw JSON retains every recorded field.".to_owned());
    }
    format!(
        "{}\n\nRecord      {}\nKind        {}\nEncrypted   {}\nStatus      {}\nTurn        {}\nTimestamp   {}\nElapsed     {}\nDuration    {}\nSource      {}{}\nTool call   {}\n\nCONTENT\n{}",
        event.title,
        event.index,
        event.kind,
        encryption_label(event_encryption(event)),
        event.status.as_deref().unwrap_or("Not recorded"),
        optional_number(event.turn),
        event.timestamp.as_deref().unwrap_or("Not recorded"),
        duration(event.elapsed_ms),
        duration(event.duration_ms),
        event.source,
        event
            .line
            .map_or_else(String::new, |line| format!(":{line}")),
        event.tool_call_id.as_deref().unwrap_or("—"),
        if event.text.is_empty() {
            "No text payload. Inspect Raw JSON for the complete record."
        } else {
            &event.text
        }
    )
}

fn overview(data: &TraceData) -> String {
    let summary = &data.summary;
    let mut text = format!(
        "SESSION\n\nTitle       {}\nSession     {}\nSource      {}\nModel       {}\nDirectory   {}\nCreated     {}\nUpdated     {}\nSchema      {}\n\nTOTALS\n\nTranscript  {} entries\nRecords     {}\nTurns       {}\nTools       {}\nErrors      {}\nDuration    {}\nInput       {} tokens\nOutput      {} tokens\nCached      {} tokens\nTotal       {} tokens\n\nTURN TIMELINE\n",
        data.title,
        data.session_id,
        data.source,
        data.model.as_deref().unwrap_or("Not recorded"),
        data.cwd.as_deref().unwrap_or("Not recorded"),
        data.created_at.as_deref().unwrap_or("Not recorded"),
        data.updated_at.as_deref().unwrap_or("Not recorded"),
        data.schema_version,
        data.transcript.len(),
        summary.event_count,
        summary.turn_count,
        summary.tool_count,
        summary.error_count,
        duration(summary.duration_ms),
        optional_number(summary.input_tokens),
        optional_number(summary.output_tokens),
        optional_number(summary.cached_input_tokens),
        optional_number(summary.total_tokens)
    );
    for turn in &data.turns {
        text.push_str(&format!(
            "\nTurn {} · {} · {} records · {}\n  Model: {}\n  Start: {}\n  End:   {}\n",
            turn.number,
            turn.status.as_deref().unwrap_or("unknown"),
            turn.event_count,
            duration(turn.duration_ms),
            turn.model.as_deref().unwrap_or("Not recorded"),
            turn.started_at.as_deref().unwrap_or("Not recorded"),
            turn.ended_at.as_deref().unwrap_or("Not recorded")
        ));
    }
    text.push_str("\nRECORDING NOTES\n\nOnly recorded information is shown. Missing values are not zero.\nReasoning is available only when included in the recording.\n");
    for warning in &data.warnings {
        text.push_str(&format!("\n• {warning}\n"));
    }
    text
}

fn duration(value: Option<u64>) -> String {
    match value {
        None => "—".to_owned(),
        Some(ms) if ms < 1_000 => format!("{ms} ms"),
        Some(ms) if ms < 60_000 => format!("{:.2} s", ms as f64 / 1_000.0),
        Some(ms) => format!("{}m {:.1}s", ms / 60_000, (ms % 60_000) as f64 / 1_000.0),
    }
}

fn optional_number(value: Option<u64>) -> String {
    value.map_or_else(|| "Not recorded".to_owned(), |value| value.to_string())
}

fn pretty(value: &Value) -> String {
    serde_json::to_string_pretty(value).unwrap_or_else(|_| value.to_string())
}

fn display_value(value: &Value) -> String {
    value
        .as_str()
        .map(str::to_owned)
        .unwrap_or_else(|| pretty(value))
}

/// A single-line excerpt for list rows.
fn preview(text: &str) -> String {
    let line = clean(text)
        .split_whitespace()
        .take(40)
        .collect::<Vec<_>>()
        .join(" ");
    match line.char_indices().nth(160) {
        Some((end, _)) => format!("{}…", &line[..end]),
        None => line,
    }
}

fn clean(text: &str) -> String {
    // The escape parser treats tabs as controls; expand them first for readable code.
    strip_ansi_escapes::strip_str(text.replace('\t', "    "))
        .chars()
        .filter(|ch| !ch.is_control() || *ch == '\n')
        .collect()
}

fn render_help(area: Rect, buf: &mut Buffer, theme: &Theme) {
    let width = area.width.min(76);
    let height = area.height.min(27);
    let popup = Rect::new(
        area.x + (area.width - width) / 2,
        area.y + (area.height - height) / 2,
        width,
        height,
    );
    Clear.render(popup, buf);
    let help = "READ A TRACE\n\n↑/↓ or j/k     Move in the focused pane\nTab / Enter    Switch list and details\n1–5 or h/l     Switch details view\nv              Transcript / all raw records\n+ / - / 0      Zoom the timeline in / out / reset\nw              Active time / wall clock\n/              Search\nf              Cycle entry type\nt              Toggle selected turn filter\n[ / ]          Previous / next turn\ne              Next error (clears filters)\nEsc            Clear filters, then close\nJ / K          Scroll details from either pane\nPgUp / PgDn    Page in the focused pane\ng / G          First / last entry or detail line\n?              Keyboard help\nq              Close the explorer\n\nTimeline bars span recorded execution time; ░ is the\nwait for the first model token, ┊ a removed idle gap.\nAny key closes help.";
    Paragraph::new(help)
        .block(panel(" Trace explorer · keyboard ".to_owned(), true, theme))
        .style(Style::default().bg(theme.bg_light).fg(theme.text_primary))
        .render(popup, buf);
}

#[cfg(test)]
mod tests {
    use super::Encryption;
    use super::*;
    use ratatui::backend::TestBackend;
    use serde_json::json;

    fn fixture() -> TraceData {
        serde_json::from_value(json!({
            "schema_version": 1, "source": "/tmp/trace", "session_id": "test-session",
            "title": "Find the failing command", "model": "grok", "cwd": "/work",
            "created_at": null, "updated_at": null,
            "summary": {"event_count": 4, "turn_count": 2, "tool_count": 1, "error_count": 1,
                "duration_ms": 1200, "input_tokens": 80, "output_tokens": 20,
                "cached_input_tokens": null, "total_tokens": 100},
            "events": [
                {"index": 0, "source": "agent.jsonl", "line": 1, "kind": "user_message", "title": "User message",
                    "text": "Inspect the build", "turn": 1, "raw": {"secret_field": "needle"}},
                {"index": 1, "source": "agent.jsonl", "line": 2, "kind": "tool_call", "title": "Run shell",
                    "text": "cargo test", "turn": 1, "tool_call_id": "tool-1", "raw": {"command": "cargo test"}},
                {"index": 2, "source": "agent.jsonl", "line": 3, "kind": "tool_result", "title": "Command failed",
                    "text": "missing Cargo.toml", "turn": 1, "tool_call_id": "tool-1", "status": "failed", "raw": {"exit_code": 1}},
                {"index": 3, "source": "agent.jsonl", "line": 4, "kind": "assistant_message", "title": "Assistant",
                    "text": "Use the workspace root", "turn": 2, "raw": {"message": "Use the workspace root"}}
            ],
            "turns": [{"number": 1, "model": "grok", "event_count": 3}, {"number": 2, "event_count": 1}],
            "tools": [{"id": "tool-1", "name": "shell", "turn": 1, "status": "failed",
                "input": {"command": "cargo test"}, "output": {"exit_code": 1, "stderr": "missing Cargo.toml"},
                "duration_ms": 42, "event_indices": [1, 2]}],
            "artifacts": [{"name": "config.json", "content": {"mode": "debug"}}],
            "warnings": ["Reasoning was not recorded"]
        })).expect("valid trace fixture")
    }

    /// The fixture with a timed transcript, including overlapping tool calls.
    fn transcript_fixture() -> TraceData {
        let mut data = fixture();
        let entry = |index: usize,
                     kind: &str,
                     title: &str,
                     turn: u64,
                     start: i64,
                     end: Option<i64>,
                     events: &[usize]| {
            json!({"index": index, "kind": kind, "title": title, "text": format!("{title} text"),
                "turn": turn, "start_ms": start, "end_ms": end, "wait_ms": null,
                "tool_call_id": if kind == "tool" { Some("tool-1") } else { None },
                "status": if kind == "tool" { Some("failed") } else { None },
                "event_indices": events})
        };
        data.transcript = serde_json::from_value(json!([
            entry(0, "system", "System prompt", 1, 1_000, Some(1_000), &[]),
            entry(1, "user", "Prompt", 1, 1_000, Some(1_000), &[0]),
            {"index": 2, "kind": "reasoning", "title": "Reasoning", "text": "think", "turn": 1,
                "start_ms": 1_000, "end_ms": 3_000, "wait_ms": 1_000, "tool_call_id": null,
                "status": null, "encryption": "partial", "event_indices": []},
            entry(3, "tool", "shell", 1, 3_000, Some(4_000), &[1, 2]),
            entry(4, "tool", "shell", 1, 3_500, Some(4_500), &[]),
            entry(5, "assistant", "Assistant", 2, 60_000, Some(62_000), &[3])
        ]))
        .unwrap();
        data
    }

    fn press(state: &mut Explorer, data: &TraceData, code: KeyCode) {
        assert!(!state.key(data, KeyEvent::new(code, KeyModifiers::NONE)));
    }

    #[test]
    fn search_raw_fields_and_restore_cancelled_query() {
        let data = fixture();
        let mut state = Explorer::new(&data);
        press(&mut state, &data, KeyCode::Char('/'));
        for ch in "NEEDLE".chars() {
            press(&mut state, &data, KeyCode::Char(ch));
        }
        assert_eq!(state.visible, vec![0]);
        press(&mut state, &data, KeyCode::Enter);
        press(&mut state, &data, KeyCode::Char('/'));
        press(&mut state, &data, KeyCode::Char('x'));
        assert!(state.visible.is_empty());
        press(&mut state, &data, KeyCode::Esc);
        assert_eq!(state.visible, vec![0]);
        press(&mut state, &data, KeyCode::Esc);
        assert_eq!(state.visible.len(), 4);
        // With nothing left to clear, Esc closes the explorer.
        assert!(state.key(&data, KeyEvent::new(KeyCode::Esc, KeyModifiers::NONE)));
    }

    #[test]
    fn navigation_filters_and_error_jump_keep_selection_valid() {
        let data = fixture();
        let mut state = Explorer::new(&data);
        press(&mut state, &data, KeyCode::Char(']'));
        assert_eq!(state.selected(), Some(3));
        press(&mut state, &data, KeyCode::Char('t'));
        assert_eq!(state.visible, vec![3]);
        press(&mut state, &data, KeyCode::Char('e'));
        assert_eq!(state.selected(), Some(2));
        assert_eq!(state.turn, None);
        assert_eq!(state.visible.len(), 4);
        press(&mut state, &data, KeyCode::Char('['));
        assert_eq!(state.selected(), Some(2)); // No earlier turn in the recording.
        press(&mut state, &data, KeyCode::End);
        press(&mut state, &data, KeyCode::Char('['));
        assert_eq!(state.selected(), Some(0));
        press(&mut state, &data, KeyCode::Char('f'));
        assert_eq!(state.visible, vec![0, 3]);
        press(&mut state, &data, KeyCode::Char('f'));
        assert!(state.visible.is_empty());
        press(&mut state, &data, KeyCode::Down);
        assert_eq!(state.selected(), None);
    }

    #[test]
    fn opens_on_the_transcript_and_switches_to_linked_records() {
        let data = transcript_fixture();
        let mut state = Explorer::new(&data);
        assert_eq!(state.view, View::Transcript);
        assert_eq!(state.visible.len(), 6);
        for _ in 0..4 {
            press(&mut state, &data, KeyCode::Char('f'));
        }
        assert_eq!(state.filter, Filter::Kind(EntryKind::Assistant));
        assert_eq!(state.visible, vec![5]);
        press(&mut state, &data, KeyCode::Char('f'));
        assert_eq!(state.visible, vec![3, 4]);
        press(&mut state, &data, KeyCode::Char('v'));
        assert_eq!(state.view, View::Records);
        assert_eq!(state.selected(), Some(1));
        press(&mut state, &data, KeyCode::Char('v'));
        assert_eq!(state.view, View::Transcript);
        assert_eq!(state.selected(), Some(3));
        let detail = entry_content(&data, Some(3), 1);
        assert!(detail.contains("INPUT\n"));
        assert!(detail.contains("missing Cargo.toml"));
        assert!(entry_content(&data, Some(3), 3).contains("agent.jsonl:2"));
        assert!(entry_content(&data, Some(2), 1).contains("First token after 1.00 s"));
    }

    #[test]
    fn timeline_widths_follow_recorded_time_and_idle_gaps_shrink() {
        let data = transcript_fixture();
        let active = TimelineModel::build(&data.transcript, Scale::Active).unwrap();
        let wall = TimelineModel::build(&data.transcript, Scale::Wall).unwrap();
        let width = |model: &TimelineModel, entry: usize| {
            let span = model.spans.iter().find(|span| span.entry == entry).unwrap();
            span.end - span.start
        };
        // Bar widths are execution time in both scales.
        assert_eq!(width(&wall, 2), 2_000.0);
        assert_eq!(width(&active, 2), 2_000.0);
        assert_eq!(width(&active, 5), 2_000.0);
        assert!((active.spans[2].wait - 0.5).abs() < f64::EPSILON);
        // The 55.5 s idle gap before turn 2 is removed from the active scale.
        assert_eq!(wall.end, 61_000.0);
        assert!(active.end < 6_000.0);
        assert_eq!(active.gaps.len(), 1);
        assert_eq!(active.active_ms, 5_500);
        // Overlapping tool calls stack instead of hiding each other.
        assert_eq!(active.tool_rows, 2);
        let rows: Vec<usize> = active
            .spans
            .iter()
            .filter(|span| span.kind == EntryKind::Tool)
            .map(|span| span.row)
            .collect();
        assert_eq!(rows, vec![0, 1]);
        assert!(active.spans[0].marker);
    }

    #[test]
    fn zoom_follows_the_selected_entry() {
        let data = transcript_fixture();
        let mut state = Explorer::new(&data);
        state.select(2);
        press(&mut state, &data, KeyCode::Char('+'));
        press(&mut state, &data, KeyCode::Char('+'));
        let (start, end) = state.zoom.unwrap();
        assert!(start <= 2_000.0 && end >= 0.0);
        state.select(5);
        state.follow_selection();
        let (start, end) = state.zoom.unwrap();
        let span = state
            .timeline
            .as_ref()
            .unwrap()
            .spans
            .iter()
            .find(|span| span.entry == 5)
            .unwrap();
        assert!(span.start >= start && span.start <= end);
        press(&mut state, &data, KeyCode::Char('0'));
        assert!(state.zoom.is_none());
        press(&mut state, &data, KeyCode::Char('w'));
        assert_eq!(state.scale, Scale::Wall);
    }

    #[test]
    fn tool_event_raw_and_artifacts_preserve_debug_data() {
        let mut data = fixture();
        let tool = detail_content(&data, Some(2), 2);
        assert!(tool.contains("INPUT\n"));
        assert!(tool.contains("OUTPUT\n"));
        assert!(tool.contains("cargo test"));
        assert!(tool.contains("missing Cargo.toml"));
        assert!(detail_content(&data, Some(0), 3).contains("needle"));
        assert!(detail_content(&data, Some(0), 4).contains("config.json"));
        assert!(overview(&data).contains("Reasoning was not recorded"));
        assert!(detail_content(&data, Some(2), 1).contains("agent.jsonl:3"));
        data.tools.first_mut().unwrap().output = Some(json!("line one\nline two"));
        assert!(detail_content(&data, Some(2), 2).contains("OUTPUT\nline one\nline two"));
    }

    #[test]
    fn long_details_scroll_beyond_u16_line_limit() {
        let mut state = Explorer {
            detail_lines: vec![String::new(); 70_000],
            viewport_height: 20,
            ..Explorer::default()
        };
        state.scroll_detail(69_000);
        assert_eq!(state.scroll, 69_000);
        state.scroll_detail(isize::MAX);
        assert_eq!(state.scroll, 69_980);
        state.scroll_detail(isize::MIN);
        assert_eq!(state.scroll, 0);
    }

    fn screen(terminal: &Terminal<TestBackend>) -> String {
        terminal
            .backend()
            .buffer()
            .content()
            .iter()
            .map(|cell| cell.symbol())
            .collect()
    }

    fn draw(terminal: &mut Terminal<TestBackend>, data: &TraceData, state: &mut Explorer) {
        terminal
            .draw(|frame| {
                let area = frame.area();
                render(area, frame.buffer_mut(), data, state, &Theme::default());
            })
            .unwrap();
    }

    #[test]
    fn renders_full_and_narrow_terminals_and_empty_traces() {
        let data = fixture();
        for (width, height) in [(120, 32), (60, 18), (24, 8), (10, 3)] {
            let mut terminal = Terminal::new(TestBackend::new(width, height)).unwrap();
            let mut state = Explorer::new(&data);
            draw(&mut terminal, &data, &mut state);
            if width >= 60 {
                assert!(screen(&terminal).contains("All records"));
            }
            state.detail_focus = true;
            state.tab = 2;
            state.select(2);
            draw(&mut terminal, &data, &mut state);
            if width >= 60 {
                assert!(screen(&terminal).contains("tool-1"));
            }
            if width == 24 {
                assert!(screen(&terminal).contains("shell"));
            }
            state.help = true;
            draw(&mut terminal, &data, &mut state);
        }
        let mut data = data;
        data.events.clear();
        let mut terminal = Terminal::new(TestBackend::new(120, 25)).unwrap();
        let mut state = Explorer::new(&data);
        draw(&mut terminal, &data, &mut state);
        assert!(screen(&terminal).contains("No records"));
    }

    #[test]
    fn renders_transcript_lanes() {
        let data = transcript_fixture();
        let mut terminal = Terminal::new(TestBackend::new(120, 32)).unwrap();
        let mut state = Explorer::new(&data);
        draw(&mut terminal, &data, &mut state);
        let text = screen(&terminal);
        for label in [
            "Timeline",
            "System",
            "Reasoning",
            "Assistant",
            "Tools",
            "█",
            "░",
            "┊",
            "🔒",
        ] {
            assert!(text.contains(label), "missing {label}");
        }
        assert!(entry_content(&data, Some(2), 1).contains("Encrypted   summary only"));
        let mut plain = transcript_fixture();
        plain.transcript[2].encryption = Encryption::None;
        let mut plain_terminal = Terminal::new(TestBackend::new(120, 32)).unwrap();
        let mut plain_state = Explorer::new(&plain);
        draw(&mut plain_terminal, &plain, &mut plain_state);
        assert!(!screen(&plain_terminal).contains("🔒"));
        // Short terminals keep the list and details and drop the lanes.
        let mut terminal = Terminal::new(TestBackend::new(80, 20)).unwrap();
        draw(&mut terminal, &data, &mut state);
        assert!(!screen(&terminal).contains("Timeline"));
    }

    #[test]
    fn overlay_loads_closes_and_requests_reload() {
        let mut overlay = TraceOverlay::loading(PathBuf::from("/tmp/session"));
        assert!(overlay.is_loading());
        let key = |code| KeyEvent::new(code, KeyModifiers::NONE);
        assert_eq!(overlay.key(key(KeyCode::Char('r'))), OverlayOutcome::Reload);
        overlay.finish(Err("unreadable".into()));
        let mut buffer = Buffer::empty(Rect::new(0, 0, 80, 24));
        overlay.render(Rect::new(0, 0, 80, 24), &mut buffer, &Theme::default());
        overlay.finish(Ok(transcript_fixture()));
        overlay.render(Rect::new(0, 0, 80, 24), &mut buffer, &Theme::default());
        assert_eq!(overlay.key(key(KeyCode::Down)), OverlayOutcome::Changed);
        overlay.scroll(3);
        assert_eq!(overlay.key(key(KeyCode::Char('r'))), OverlayOutcome::Reload);
        assert_eq!(overlay.key(key(KeyCode::Esc)), OverlayOutcome::Close);
    }

    #[test]
    fn recorded_terminal_sequences_cannot_change_the_terminal() {
        assert_eq!(
            clean("hello\u{1b}[31mred\u{1b}[0m\u{7}\n\tworld"),
            "hellored\n    world"
        );
    }
}
