//! The `/git-graph` overlay: the commit graph on the left and the selected commit on the right.
//!
//! Each commit is one line. Lanes are two cells wide; a node's joins to other lanes are drawn on
//! its own line with rounded box-drawing characters, each lane in its own colour.

use std::collections::HashMap;
use std::path::PathBuf;

use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use ratatui::{
    buffer::Buffer,
    layout::{Constraint, Direction, Layout, Rect},
    style::{Color, Modifier, Style},
    text::{Line, Span},
    widgets::{Block, BorderType, Borders, Clear, Paragraph, Widget},
};
use unicode_width::UnicodeWidthStr;

use super::data::{self, Commit, FileStat, GraphData, RefKind, Scope};
use super::layout::Row;
use super::{Request, Response};
use crate::render::line_utils::{truncate_line, truncate_str};
use crate::theme::Theme;

/// Below this width the details replace the list instead of sitting beside it.
const WIDE: u16 = 110;

/// What the host should do after the overlay handled input.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum OverlayOutcome {
    Changed,
    Close,
    /// Run this off the UI thread and hand the response to [`GitGraphOverlay::apply`].
    Request(Request),
}

/// The `/git-graph` overlay. It keeps showing the last graph while a reload runs.
pub struct GitGraphOverlay {
    pub cwd: PathBuf,
    scope: Scope,
    limit: usize,
    generation: u64,
    loading: bool,
    error: Option<String>,
    explorer: Option<Box<Explorer>>,
}

impl GitGraphOverlay {
    /// A new overlay for the repository containing `cwd`, and the request that loads it.
    pub fn open(cwd: PathBuf) -> (Self, Request) {
        let mut overlay = Self {
            cwd,
            scope: Scope::All,
            limit: data::PAGE,
            generation: 0,
            loading: false,
            error: None,
            explorer: None,
        };
        let request = overlay.reload();
        (overlay, request)
    }

    pub fn is_loading(&self) -> bool {
        self.loading
    }

    fn reload(&mut self) -> Request {
        self.generation += 1;
        self.loading = true;
        Request::Load {
            cwd: self.cwd.clone(),
            scope: self.scope,
            limit: self.limit,
            generation: self.generation,
        }
    }

    /// Takes a finished request's result and returns any follow-up work (the selected commit's
    /// files). Results for a superseded load or a different repository are dropped.
    pub fn apply(&mut self, response: Response) -> Option<Request> {
        match response {
            Response::Loaded { generation, result } => {
                if generation != self.generation {
                    return None;
                }
                self.loading = false;
                match result {
                    Ok(data) => {
                        self.error = None;
                        let previous = self.explorer.take();
                        self.explorer = Some(Box::new(Explorer::new(*data, previous)));
                    }
                    Err(error) => self.error = Some(error),
                }
            }
            Response::Files { root, hash, result } => {
                let explorer = self.explorer.as_mut()?;
                if explorer.data.root != root
                    || !matches!(explorer.files.get(&hash), Some(Files::Loading))
                {
                    return None;
                }
                explorer.files.insert(
                    hash,
                    match result {
                        Ok(files) => Files::Ready(files),
                        Err(error) => Files::Failed(error),
                    },
                );
                explorer.detail_key = None;
            }
        }
        self.files_request()
    }

    fn files_request(&mut self) -> Option<Request> {
        self.explorer.as_mut()?.files_request()
    }

    pub fn key(&mut self, key: KeyEvent) -> OverlayOutcome {
        let Some(explorer) = self.explorer.as_mut() else {
            return match key.code {
                KeyCode::Esc | KeyCode::Char('q') => OverlayOutcome::Close,
                KeyCode::Char('r') => OverlayOutcome::Request(self.reload()),
                _ => OverlayOutcome::Changed,
            };
        };
        match explorer.key(key) {
            Command::None => {}
            Command::Close => return OverlayOutcome::Close,
            Command::Reload => return OverlayOutcome::Request(self.reload()),
            Command::ToggleScope => {
                self.scope = self.scope.toggled();
                self.limit = data::PAGE;
                return OverlayOutcome::Request(self.reload());
            }
            Command::LoadMore => {
                self.limit = self.limit.saturating_add(data::PAGE);
                return OverlayOutcome::Request(self.reload());
            }
        }
        self.files_request()
            .map_or(OverlayOutcome::Changed, OverlayOutcome::Request)
    }

    /// Mouse wheel: move through the focused pane.
    pub fn scroll(&mut self, lines: isize) -> Option<Request> {
        let explorer = self.explorer.as_mut()?;
        if explorer.detail_focus {
            explorer.scroll_detail(lines);
        } else {
            explorer.move_selection(lines);
        }
        self.files_request()
    }

    pub fn render(&mut self, area: Rect, buf: &mut Buffer, theme: &Theme) {
        Clear.render(area, buf);
        Block::default()
            .style(Style::default().bg(theme.bg_base).fg(theme.text_primary))
            .render(area, buf);
        match &mut self.explorer {
            Some(explorer) => {
                let status = Status {
                    loading: self.loading,
                    error: self.error.as_deref(),
                };
                explorer.render(area, buf, theme, status);
            }
            None => {
                let text = match &self.error {
                    Some(error) => format!(
                        "Could not read the commit graph.\n\n{}\n\nr retry · Esc close",
                        clean(error)
                    ),
                    None => format!(
                        "Reading the commit graph…\n\n{}",
                        clean(&self.cwd.display().to_string())
                    ),
                };
                Paragraph::new(text)
                    .block(panel(" Git graph ".to_owned(), true, theme))
                    .wrap(ratatui::widgets::Wrap { trim: false })
                    .render(area, buf);
            }
        }
    }
}

#[derive(Clone, Copy)]
struct Status<'a> {
    loading: bool,
    error: Option<&'a str>,
}

enum Files {
    Loading,
    Ready(Vec<FileStat>),
    Failed(String),
}

enum Command {
    None,
    Close,
    Reload,
    ToggleScope,
    LoadMore,
}

struct Explorer {
    data: GraphData,
    /// Unix seconds that relative dates count from.
    now: i64,
    selected: usize,
    offset: usize,
    list_page: usize,
    detail_focus: bool,
    /// Whether the details sit beside the list (set as it renders).
    wide: bool,
    detail_scroll: usize,
    detail_height: usize,
    detail_key: Option<(usize, u16)>,
    detail_lines: Vec<Line<'static>>,
    query: String,
    search_before: String,
    search_origin: usize,
    searching: bool,
    matches: Vec<usize>,
    help: bool,
    files: HashMap<String, Files>,
}

impl Explorer {
    fn new(data: GraphData, previous: Option<Box<Explorer>>) -> Self {
        let mut explorer = Self {
            data,
            now: chrono::Utc::now().timestamp(),
            selected: 0,
            offset: 0,
            list_page: 1,
            detail_focus: false,
            wide: true,
            detail_scroll: 0,
            detail_height: 0,
            detail_key: None,
            detail_lines: Vec::new(),
            query: String::new(),
            search_before: String::new(),
            search_origin: 0,
            searching: false,
            matches: Vec::new(),
            help: false,
            files: HashMap::new(),
        };
        if let Some(previous) = previous {
            let previous = *previous;
            let hash = previous
                .data
                .commits
                .get(previous.selected)
                .map(|commit| commit.hash.clone());
            explorer.selected = hash
                .and_then(|hash| explorer.data.commits.iter().position(|c| c.hash == hash))
                .unwrap_or(0);
            explorer.offset = previous.offset;
            explorer.detail_focus = previous.detail_focus;
            explorer.wide = previous.wide;
            explorer.query = previous.query;
            if previous.data.root == explorer.data.root {
                // A commit's files never change; the working tree's may have.
                explorer.files = previous.files;
                explorer.files.remove(data::UNCOMMITTED);
                explorer
                    .files
                    .retain(|_, files| !matches!(files, Files::Loading));
            }
            explorer.refresh_matches();
        }
        explorer
    }

    fn selected_commit(&self) -> Option<&Commit> {
        self.data.commits.get(self.selected)
    }

    fn files_request(&mut self) -> Option<Request> {
        if !(self.wide || self.detail_focus) {
            return None;
        }
        let commit = self.data.commits.get(self.selected)?;
        if self.files.contains_key(&commit.hash) {
            return None;
        }
        let request = Request::Files {
            root: self.data.root.clone(),
            hash: commit.hash.clone(),
            parents: commit.parents.clone(),
        };
        self.files.insert(commit.hash.clone(), Files::Loading);
        self.detail_key = None;
        Some(request)
    }

    fn select(&mut self, index: usize) {
        let index = index.min(self.data.commits.len().saturating_sub(1));
        if index != self.selected {
            self.selected = index;
            self.detail_scroll = 0;
            self.detail_key = None;
        }
    }

    fn move_selection(&mut self, amount: isize) {
        let target = self.selected.saturating_add_signed(amount);
        self.select(target);
    }

    fn scroll_detail(&mut self, amount: isize) {
        let max = self.detail_lines.len().saturating_sub(self.detail_height);
        self.detail_scroll = self.detail_scroll.saturating_add_signed(amount).min(max);
    }

    fn refresh_matches(&mut self) {
        let query = self.query.trim().to_lowercase();
        self.matches = if query.is_empty() {
            Vec::new()
        } else {
            self.data
                .commits
                .iter()
                .enumerate()
                .filter(|(_, commit)| matches(commit, &query))
                .map(|(index, _)| index)
                .collect()
        };
    }

    /// The next match after (or, backwards, before) the selection, wrapping around.
    fn jump_to_match(&mut self, from: usize, forward: bool, inclusive: bool) {
        if self.matches.is_empty() {
            return;
        }
        let found = if forward {
            self.matches
                .iter()
                .copied()
                .find(|&index| index > from || (inclusive && index == from))
                .or_else(|| self.matches.first().copied())
        } else {
            self.matches
                .iter()
                .rev()
                .copied()
                .find(|&index| index < from || (inclusive && index == from))
                .or_else(|| self.matches.last().copied())
        };
        if let Some(index) = found {
            self.select(index);
        }
    }

    fn key(&mut self, key: KeyEvent) -> Command {
        if self.help {
            self.help = false;
            return Command::None;
        }
        if self.searching {
            match key.code {
                KeyCode::Esc => {
                    self.query.clone_from(&self.search_before);
                    self.searching = false;
                    self.refresh_matches();
                    self.select(self.search_origin);
                    return Command::None;
                }
                KeyCode::Enter => {
                    self.searching = false;
                    return Command::None;
                }
                KeyCode::Backspace => {
                    self.query.pop();
                }
                KeyCode::Char('u') if key.modifiers.contains(KeyModifiers::CONTROL) => {
                    self.query.clear();
                }
                KeyCode::Char(ch)
                    if !key
                        .modifiers
                        .intersects(KeyModifiers::CONTROL | KeyModifiers::ALT) =>
                {
                    self.query.push(ch);
                }
                _ => return Command::None,
            }
            self.refresh_matches();
            self.jump_to_match(self.search_origin, true, true);
            return Command::None;
        }
        let page = if self.detail_focus {
            self.detail_height
        } else {
            self.list_page
        }
        .max(1) as isize;
        match key.code {
            KeyCode::Char('q') => return Command::Close,
            KeyCode::Esc => {
                if self.query.is_empty() {
                    return Command::Close;
                }
                self.query.clear();
                self.matches.clear();
            }
            KeyCode::Char('?') => self.help = true,
            KeyCode::Char('/') => {
                self.search_before.clone_from(&self.query);
                self.search_origin = self.selected;
                self.searching = true;
            }
            KeyCode::Char('n') => self.jump_to_match(self.selected, true, false),
            KeyCode::Char('N') => self.jump_to_match(self.selected, false, false),
            KeyCode::Char('a') => return Command::ToggleScope,
            KeyCode::Char('r') => return Command::Reload,
            KeyCode::Char('m') if self.data.truncated => return Command::LoadMore,
            KeyCode::Tab | KeyCode::BackTab | KeyCode::Enter => {
                self.detail_focus = !self.detail_focus;
            }
            KeyCode::Char('J') => self.scroll_detail(1),
            KeyCode::Char('K') => self.scroll_detail(-1),
            KeyCode::Down | KeyCode::Char('j') => self.step(1),
            KeyCode::Up | KeyCode::Char('k') => self.step(-1),
            KeyCode::PageDown | KeyCode::Char('d') => self.step(page),
            KeyCode::PageUp | KeyCode::Char('u') => self.step(-page),
            KeyCode::Home | KeyCode::Char('g') => {
                if self.detail_focus {
                    self.detail_scroll = 0;
                } else {
                    self.select(0);
                }
            }
            KeyCode::End | KeyCode::Char('G') => {
                if self.detail_focus {
                    self.scroll_detail(isize::MAX);
                } else {
                    self.select(usize::MAX);
                }
            }
            _ => {}
        }
        Command::None
    }

    fn step(&mut self, amount: isize) {
        if self.detail_focus {
            self.scroll_detail(amount);
        } else {
            self.move_selection(amount);
        }
    }

    fn render(&mut self, area: Rect, buf: &mut Buffer, theme: &Theme, status: Status<'_>) {
        if area.width < 30 || area.height < 8 {
            Paragraph::new("Git graph\nResize to at least 30 × 8.\nq exits")
                .style(Style::default().fg(theme.text_primary))
                .render(area, buf);
            return;
        }
        let palette = palette(theme);
        let [header_area, content_area, footer_area] = Layout::default()
            .direction(Direction::Vertical)
            .constraints([
                Constraint::Length(2),
                Constraint::Min(3),
                Constraint::Length(1),
            ])
            .areas(area);
        self.render_header(header_area, buf, theme, status);
        self.wide = area.width >= WIDE;
        if self.wide {
            let [list_area, detail_area] = Layout::default()
                .direction(Direction::Horizontal)
                .constraints([Constraint::Percentage(62), Constraint::Percentage(38)])
                .areas(content_area);
            self.render_list(list_area, buf, theme, &palette);
            self.render_detail(detail_area, buf, theme, &palette);
        } else if self.detail_focus {
            self.render_detail(content_area, buf, theme, &palette);
        } else {
            self.render_list(content_area, buf, theme, &palette);
        }
        let hint = if self.searching {
            " Type to search · Enter keep · Esc cancel · Ctrl-U clear"
        } else if area.width < 80 {
            " ↑↓ move  Tab details  / search  a scope  ? help  q close"
        } else {
            " ↑↓/jk move  Tab details  / search  n/N match  a all/current  m more  r reload  ? help  q close"
        };
        Paragraph::new(hint)
            .style(Style::default().fg(theme.text_secondary))
            .render(footer_area, buf);
        if self.help {
            render_help(area, buf, theme);
        }
    }

    fn render_header(&self, area: Rect, buf: &mut Buffer, theme: &Theme, status: Status<'_>) {
        let data = &self.data;
        let muted = Style::default().fg(theme.text_secondary);
        let repo = data
            .root
            .file_name()
            .map(|name| name.to_string_lossy().into_owned())
            .unwrap_or_else(|| data.root.display().to_string());
        let mut first = vec![
            Span::styled(
                " crok ",
                Style::default()
                    .fg(theme.text_primary)
                    .add_modifier(Modifier::BOLD),
            ),
            Span::styled("/ git graph  ", muted),
            Span::styled(
                clean_line(&repo),
                Style::default()
                    .fg(theme.text_primary)
                    .add_modifier(Modifier::BOLD),
            ),
        ];
        let branch_style = Style::default()
            .fg(lane_color(&palette(theme), 0))
            .add_modifier(Modifier::BOLD);
        match (&data.branch, &data.head) {
            (Some(branch), _) => {
                first.push(Span::styled("  on ", muted));
                first.push(Span::styled(clean_line(branch), branch_style));
            }
            (None, Some(head)) => {
                first.push(Span::styled("  detached at ", muted));
                first.push(Span::styled(
                    head.get(..7).unwrap_or(head).to_owned(),
                    branch_style,
                ));
            }
            (None, None) => first.push(Span::styled("  no commits yet", muted)),
        }
        let commits = data
            .commits
            .iter()
            .filter(|commit| commit.uncommitted.is_none())
            .count();
        let mut second = vec![Span::styled(
            format!(
                " {commits}{} commits · {} branches · {} remote · {} tags · {}",
                if data.truncated { "+" } else { "" },
                data.local_branches,
                data.remote_branches,
                data.tags,
                data.scope.label()
            ),
            muted,
        )];
        if !self.query.is_empty() {
            second.push(Span::styled(
                format!(
                    "   /{} · {} matches",
                    clean_line(&self.query),
                    self.matches.len()
                ),
                Style::default().fg(theme.fuzzy_accent),
            ));
        }
        if status.loading {
            second.push(Span::styled(
                "   reading…",
                Style::default().fg(theme.running),
            ));
        }
        if let Some(error) = status.error {
            second.push(Span::styled(
                format!("   {}", clean_line(error)),
                Style::default().fg(theme.accent_error),
            ));
        }
        let width = area.width as usize;
        Paragraph::new(vec![
            truncate_line(Line::from(first), width),
            truncate_line(Line::from(second), width),
        ])
        .render(area, buf);
    }

    fn render_list(&mut self, area: Rect, buf: &mut Buffer, theme: &Theme, palette: &[Color]) {
        let count = self.data.commits.len();
        let title = format!(
            " Commits · {}/{} ",
            if count == 0 { 0 } else { self.selected + 1 },
            count
        );
        let block = panel(title, !self.detail_focus, theme);
        let inner = block.inner(area);
        block.render(area, buf);
        if inner.height == 0 || inner.width < 4 {
            return;
        }
        self.list_page = inner.height as usize;
        if count == 0 {
            Paragraph::new(if self.data.scope == Scope::Current {
                "No commits yet.\na shows every branch."
            } else {
                "No commits yet."
            })
            .style(Style::default().fg(theme.text_secondary))
            .render(inner, buf);
            return;
        }
        let page = self.list_page;
        self.offset = self
            .offset
            .min(self.selected)
            .max((self.selected + 1).saturating_sub(page))
            .min(count.saturating_sub(page));
        let width = inner.width as usize;
        let graph_width = (self.data.lanes * 2)
            .saturating_sub(1)
            .clamp(1, (width / 2).max(1));
        for (line, index) in (self.offset..count.min(self.offset + page)).enumerate() {
            let y = inner.y + line as u16;
            let row_area = Rect::new(inner.x, y, inner.width, 1);
            if index == self.selected {
                buf.set_style(row_area, Style::default().bg(theme.bg_highlight));
            }
            let line = self.row_line(index, width, graph_width, theme, palette);
            buf.set_line(inner.x, y, &line, inner.width);
        }
    }

    fn row_line(
        &self,
        index: usize,
        width: usize,
        graph_width: usize,
        theme: &Theme,
        palette: &[Color],
    ) -> Line<'static> {
        let (Some(commit), Some(row)) = (self.data.commits.get(index), self.data.rows.get(index))
        else {
            return Line::default();
        };
        let mut spans = graph_spans(row, commit, graph_width, theme, palette);
        spans.push(Span::raw(" "));

        let muted = Style::default().fg(theme.text_secondary);
        let mut right: Vec<Span<'static>> = Vec::new();
        if commit.uncommitted.is_none() {
            if width >= 70 {
                right.push(Span::styled(
                    format!("{:<14}", truncate_str(&clean_line(&commit.author), 14)),
                    muted,
                ));
                right.push(Span::raw("  "));
            }
            if width >= 50 {
                right.push(Span::styled(
                    format!("{:>4}", ago(self.now, commit.time)),
                    muted,
                ));
            }
            if width >= 60 {
                right.push(Span::raw("  "));
                right.push(Span::styled(
                    commit.short().to_owned(),
                    Style::default().fg(theme.gray),
                ));
            }
        }
        let right_width: usize = right.iter().map(|span| span.content.width()).sum();
        let budget = width
            .saturating_sub(graph_width + 1)
            .saturating_sub(right_width + usize::from(right_width > 0));

        let color = lane_color(palette, row.color);
        let mut left = badges(commit, color, theme);
        let is_match = self.matches.binary_search(&index).is_ok();
        let subject_style = if commit.uncommitted.is_some() {
            Style::default()
                .fg(theme.warning)
                .add_modifier(Modifier::ITALIC)
        } else if is_match {
            Style::default()
                .fg(theme.fuzzy_accent)
                .add_modifier(Modifier::BOLD)
        } else if commit.is_merge() {
            muted
        } else {
            Style::default().fg(theme.text_primary)
        };
        left.push(Span::styled(clean_line(&commit.subject), subject_style));
        let left = truncate_line(Line::from(left), budget);
        let used: usize = left.spans.iter().map(|span| span.content.width()).sum();
        spans.extend(left.spans);
        if right_width > 0 {
            spans.push(Span::raw(" ".repeat(budget.saturating_sub(used) + 1)));
            spans.extend(right);
        }
        Line::from(spans)
    }

    fn render_detail(&mut self, area: Rect, buf: &mut Buffer, theme: &Theme, palette: &[Color]) {
        let title = if self.detail_focus {
            " Commit · focused "
        } else {
            " Commit · Tab to focus "
        };
        let block = panel(title.to_owned(), self.detail_focus, theme);
        let inner = block.inner(area);
        block.render(area, buf);
        if inner.height == 0 || inner.width < 4 {
            return;
        }
        let [lines_area, scroll_area] = Layout::default()
            .direction(Direction::Vertical)
            .constraints([
                Constraint::Min(0),
                Constraint::Length(u16::from(inner.height >= 5)),
            ])
            .areas(inner);
        let key = (self.selected, lines_area.width);
        if self.detail_key != Some(key) {
            self.detail_lines = self.detail_content(lines_area.width as usize, theme, palette);
            self.detail_key = Some(key);
        }
        self.detail_height = lines_area.height as usize;
        self.detail_scroll = self
            .detail_scroll
            .min(self.detail_lines.len().saturating_sub(self.detail_height));
        let lines: Vec<Line<'_>> = self
            .detail_lines
            .iter()
            .skip(self.detail_scroll)
            .take(self.detail_height)
            .cloned()
            .collect();
        Paragraph::new(lines)
            .style(Style::default().fg(theme.text_primary))
            .render(lines_area, buf);
        if scroll_area.height > 0 && self.detail_lines.len() > self.detail_height {
            Paragraph::new(format!(
                " {}–{} / {} lines  ·  J/K scroll",
                self.detail_scroll + 1,
                (self.detail_scroll + self.detail_height).min(self.detail_lines.len()),
                self.detail_lines.len()
            ))
            .style(Style::default().fg(theme.gray))
            .render(scroll_area, buf);
        }
    }

    fn detail_content(&self, width: usize, theme: &Theme, palette: &[Color]) -> Vec<Line<'static>> {
        let Some(commit) = self.selected_commit() else {
            return vec![Line::styled(
                "No commit selected.",
                Style::default().fg(theme.text_secondary),
            )];
        };
        let width = width.max(8);
        let label = Style::default().fg(theme.text_secondary);
        let mut lines: Vec<Line<'static>> = Vec::new();
        let title = if commit.uncommitted.is_some() {
            "Uncommitted changes".to_owned()
        } else {
            clean_line(&commit.subject)
        };
        for part in textwrap::wrap(&title, width) {
            lines.push(Line::styled(
                part.into_owned(),
                Style::default()
                    .fg(theme.text_primary)
                    .add_modifier(Modifier::BOLD),
            ));
        }
        lines.push(Line::default());
        let field = |name: &str, value: Vec<Span<'static>>| {
            let mut spans = vec![Span::styled(format!("{name:<8}"), label)];
            spans.extend(value);
            Line::from(spans)
        };
        if let Some(changed) = commit.uncommitted {
            lines.push(Line::styled(
                format!(
                    "{changed} {} changed in the working tree.",
                    if changed == 1 { "path" } else { "paths" }
                ),
                label,
            ));
            if let Some(head) = commit.parents.first() {
                lines.push(field(
                    "on",
                    vec![Span::styled(
                        head.get(..7).unwrap_or(head).to_owned(),
                        Style::default().fg(theme.command),
                    )],
                ));
            }
        } else {
            lines.push(field(
                "commit",
                vec![Span::styled(
                    commit.hash.clone(),
                    Style::default().fg(theme.command),
                )],
            ));
            if !commit.parents.is_empty() {
                let parents = commit
                    .parents
                    .iter()
                    .map(|parent| parent.get(..7).unwrap_or(parent))
                    .collect::<Vec<_>>()
                    .join(" ");
                lines.push(field(
                    if commit.is_merge() { "merge" } else { "parent" },
                    vec![Span::styled(
                        parents,
                        Style::default().fg(theme.gray_bright),
                    )],
                ));
            }
            lines.push(field(
                "author",
                vec![Span::raw(format!(
                    "{} <{}>",
                    clean_line(&commit.author),
                    clean_line(&commit.email)
                ))],
            ));
            lines.push(field(
                "date",
                vec![Span::raw(format!(
                    "{} ({} ago)",
                    absolute(commit.time),
                    ago(self.now, commit.time)
                ))],
            ));
            if !commit.refs.is_empty() {
                let color = self
                    .data
                    .rows
                    .get(self.selected)
                    .map_or(lane_color(palette, 0), |row| lane_color(palette, row.color));
                lines.push(field("refs", badges(commit, color, theme)));
            }
            let body = clean(&commit.body);
            if !body.trim().is_empty() {
                lines.push(Line::default());
                for line in body.lines() {
                    if line.is_empty() {
                        lines.push(Line::default());
                        continue;
                    }
                    for part in textwrap::wrap(line, width) {
                        lines.push(Line::raw(part.into_owned()));
                    }
                }
            }
        }
        lines.push(Line::default());
        match self.files.get(&commit.hash) {
            None | Some(Files::Loading) => {
                lines.push(Line::styled("Reading changed files…", label));
            }
            Some(Files::Failed(error)) => {
                lines.push(Line::styled(
                    format!("Could not read changed files: {}", clean_line(error)),
                    Style::default().fg(theme.accent_error),
                ));
            }
            Some(Files::Ready(files)) => {
                let added: u64 = files.iter().filter_map(|file| file.added).sum();
                let removed: u64 = files.iter().filter_map(|file| file.removed).sum();
                lines.push(Line::from(vec![
                    Span::styled(
                        format!(
                            "{} {} changed",
                            files.len(),
                            if files.len() == 1 { "file" } else { "files" }
                        ),
                        Style::default().add_modifier(Modifier::BOLD),
                    ),
                    Span::styled(
                        format!("  +{added}"),
                        Style::default().fg(theme.diff_insert_fg),
                    ),
                    Span::styled(
                        format!(" −{removed}"),
                        Style::default().fg(theme.diff_delete_fg),
                    ),
                ]));
                for file in files {
                    let stats = match (file.added, file.removed) {
                        (Some(added), Some(removed)) => vec![
                            Span::styled(
                                format!("{:>6}", format!("+{added}")),
                                Style::default().fg(theme.diff_insert_fg),
                            ),
                            Span::styled(
                                format!("{:>6}", format!("−{removed}")),
                                Style::default().fg(theme.diff_delete_fg),
                            ),
                        ],
                        _ if commit.uncommitted.is_some() => vec![Span::styled(
                            format!("{:>12}", "new"),
                            Style::default().fg(theme.diff_insert_fg),
                        )],
                        _ => vec![Span::styled(format!("{:>12}", "binary"), label)],
                    };
                    let mut spans = stats;
                    spans.push(Span::raw("  "));
                    spans.push(Span::raw(clean_line(&file.path)));
                    lines.push(truncate_line(Line::from(spans), width));
                }
            }
        }
        lines
    }
}

fn matches(commit: &Commit, query: &str) -> bool {
    commit.hash.starts_with(query)
        || commit.subject.to_lowercase().contains(query)
        || commit.author.to_lowercase().contains(query)
        || commit.email.to_lowercase().contains(query)
        || commit
            .refs
            .iter()
            .any(|reference| reference.name.to_lowercase().contains(query))
}

/// Lane colours from the active theme's accents, without repeats. Some themes make an accent
/// gray (Grok Night's `accent_user`); a gray lane reads as uncoloured, so grays are left out
/// unless the theme has nothing else.
fn palette(theme: &Theme) -> Vec<Color> {
    let mut colors = Vec::new();
    for color in [
        theme.accent_user,
        theme.accent_skill,
        theme.path,
        theme.accent_success,
        theme.accent_verify,
        theme.running,
        theme.accent_plan,
        theme.accent_error,
        theme.accent_remember,
        theme.command,
        theme.accent_model,
    ] {
        if !colors.contains(&color) {
            colors.push(color);
        }
    }
    let vivid: Vec<Color> = colors
        .iter()
        .copied()
        .filter(|&color| is_vivid(color))
        .collect();
    if vivid.is_empty() { colors } else { vivid }
}

/// Whether a colour has enough hue to tell lanes apart.
fn is_vivid(color: Color) -> bool {
    match color {
        Color::Rgb(r, g, b) => r.max(g).max(b) - r.min(g).min(b) >= 48,
        Color::Reset | Color::Black | Color::White | Color::Gray | Color::DarkGray => false,
        _ => true,
    }
}

fn lane_color(palette: &[Color], index: usize) -> Color {
    palette
        .get(index % palette.len().max(1))
        .copied()
        .unwrap_or(Color::Reset)
}

/// Branch and tag labels: local branches filled with the lane's colour, remotes in it, tags gold.
fn badges(commit: &Commit, color: Color, theme: &Theme) -> Vec<Span<'static>> {
    let mut spans = Vec::new();
    let filled = Style::default()
        .fg(theme.bg_base)
        .bg(color)
        .add_modifier(Modifier::BOLD);
    if commit.is_head && !commit.refs.iter().any(|r| r.kind == RefKind::Head) {
        spans.push(Span::styled(
            " HEAD ",
            Style::default()
                .fg(theme.bg_base)
                .bg(theme.warning)
                .add_modifier(Modifier::BOLD),
        ));
        spans.push(Span::raw(" "));
    }
    for reference in &commit.refs {
        let name = clean_line(&reference.name);
        let span = match reference.kind {
            RefKind::Head => Span::styled(format!(" HEAD → {name} "), filled),
            RefKind::Local => Span::styled(format!(" {name} "), filled),
            RefKind::Remote => Span::styled(
                name,
                Style::default().fg(color).add_modifier(Modifier::ITALIC),
            ),
            RefKind::Tag => Span::styled(
                format!("tag:{name}"),
                Style::default()
                    .fg(theme.accent_plan)
                    .add_modifier(Modifier::BOLD),
            ),
        };
        spans.push(span);
        spans.push(Span::raw(" "));
    }
    spans
}

const UP: u8 = 1;
const DOWN: u8 = 2;
const LEFT: u8 = 4;
const RIGHT: u8 = 8;

/// The box-drawing character joining a cell's sides.
fn glyph(sides: u8) -> char {
    match sides {
        0 => ' ',
        s if s == UP | DOWN || s == UP || s == DOWN => '│',
        s if s == LEFT | RIGHT || s == LEFT || s == RIGHT => '─',
        s if s == UP | LEFT => '╯',
        s if s == UP | RIGHT => '╰',
        s if s == DOWN | LEFT => '╮',
        s if s == DOWN | RIGHT => '╭',
        s if s == UP | DOWN | LEFT => '┤',
        s if s == UP | DOWN | RIGHT => '├',
        s if s == DOWN | LEFT | RIGHT => '┬',
        s if s == UP | LEFT | RIGHT => '┴',
        _ => '┼',
    }
}

/// One graph cell: a character and the palette index it is drawn in.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct Cell {
    glyph: char,
    color: Option<usize>,
    node: bool,
}

/// A row's graph, two cells per lane (the lane, then the gap to the next), without the last gap.
fn graph_cells(row: &Row, node: char) -> Vec<Cell> {
    let width = row.width();
    // Each cell's joined sides, and the colour of the first line through it.
    let mut cells: Vec<(u8, Option<usize>)> = vec![(0, None); width * 2];
    let mut add = |x: usize, sides: u8, color: Option<usize>| {
        if let Some((cell_sides, cell_color)) = cells.get_mut(x) {
            *cell_sides |= sides;
            if cell_color.is_none() {
                *cell_color = color;
            }
        }
    };
    for lane in 0..width {
        if row.passes_through(lane) {
            add(lane * 2, UP | DOWN, row.above.get(lane).copied().flatten());
        }
    }
    let column = row.column;
    let mut join = |lane: usize, color: usize, vertical: u8| {
        let (from, to) = (column.min(lane) * 2, column.max(lane) * 2);
        for x in from + 1..to {
            add(x, LEFT | RIGHT, Some(color));
        }
        let toward_node = if lane > column { LEFT } else { RIGHT };
        add(lane * 2, vertical | toward_node, Some(color));
    };
    for edge in &row.merges_in {
        let continues = row.below.get(edge.lane).copied().flatten().is_some();
        join(
            edge.lane,
            edge.color,
            if continues { UP | DOWN } else { UP },
        );
    }
    for edge in &row.branches_out {
        join(edge.lane, edge.color, DOWN);
    }
    cells
        .iter()
        .take((width * 2).saturating_sub(1))
        .enumerate()
        .map(|(x, &(sides, color))| {
            if x == column * 2 {
                Cell {
                    glyph: node,
                    color: Some(row.color),
                    node: true,
                }
            } else {
                Cell {
                    glyph: glyph(sides),
                    color,
                    node: false,
                }
            }
        })
        .collect()
}

fn node_glyph(commit: &Commit) -> char {
    if commit.uncommitted.is_some() {
        '◌'
    } else if commit.is_head {
        '◉'
    } else if commit.is_merge() {
        '○'
    } else {
        '●'
    }
}

/// Exactly `width` cells of graph, clipped with `…` when the lanes do not fit.
fn graph_spans(
    row: &Row,
    commit: &Commit,
    width: usize,
    theme: &Theme,
    palette: &[Color],
) -> Vec<Span<'static>> {
    let mut cells = graph_cells(row, node_glyph(commit));
    if cells.len() > width {
        cells.truncate(width.saturating_sub(1));
        cells.push(Cell {
            glyph: '…',
            color: None,
            node: false,
        });
    }
    let mut spans: Vec<Span<'static>> = Vec::new();
    let mut current = String::new();
    let mut current_style = Style::default();
    for cell in &cells {
        let style = if cell.node {
            let color = if commit.uncommitted.is_some() {
                theme.warning
            } else {
                lane_color(palette, row.color)
            };
            let style = Style::default().fg(color);
            if commit.is_head {
                style.add_modifier(Modifier::BOLD)
            } else {
                style
            }
        } else {
            match cell.color {
                Some(color) => Style::default().fg(lane_color(palette, color)),
                None => Style::default().fg(theme.gray),
            }
        };
        if style != current_style && !current.is_empty() {
            spans.push(Span::styled(std::mem::take(&mut current), current_style));
        }
        current_style = style;
        current.push(cell.glyph);
    }
    let pad = width.saturating_sub(cells.len());
    current.extend(std::iter::repeat_n(' ', pad));
    if !current.is_empty() {
        spans.push(Span::styled(current, current_style));
    }
    spans
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

fn render_help(area: Rect, buf: &mut Buffer, theme: &Theme) {
    let width = area.width.min(64);
    let height = area.height.min(22);
    let popup = Rect::new(
        area.x + (area.width - width) / 2,
        area.y + (area.height - height) / 2,
        width,
        height,
    );
    Clear.render(popup, buf);
    let help = "READ THE GRAPH\n\n↑/↓ or j/k     Move in the focused pane\nPgUp / PgDn    Page\ng / G          First / last commit\nTab / Enter    Switch list and details\nJ / K          Scroll details from either pane\n/              Search subjects, authors, hashes, refs\nn / N          Next / previous match\na              All branches / current branch\nm              Read more history\nr              Read the graph again\nEsc            Clear the search, then close\nq              Close\n\n● commit  ○ merge  ◉ HEAD  ◌ uncommitted changes\nAny key closes help.";
    Paragraph::new(help)
        .block(panel(" Git graph · keyboard ".to_owned(), true, theme))
        .style(Style::default().bg(theme.bg_light).fg(theme.text_primary))
        .render(popup, buf);
}

/// "now", "5m", "3h", "2d", "4mo", "2y".
fn ago(now: i64, time: i64) -> String {
    let seconds = (now - time).max(0);
    match seconds {
        0..60 => "now".to_owned(),
        60..3_600 => format!("{}m", seconds / 60),
        3_600..86_400 => format!("{}h", seconds / 3_600),
        86_400..2_592_000 => format!("{}d", seconds / 86_400),
        2_592_000..31_536_000 => format!("{}mo", seconds / 2_592_000),
        _ => format!("{}y", seconds / 31_536_000),
    }
}

fn absolute(time: i64) -> String {
    chrono::DateTime::from_timestamp(time, 0)
        .map(|date| {
            date.with_timezone(&chrono::Local)
                .format("%Y-%m-%d %H:%M")
                .to_string()
        })
        .unwrap_or_default()
}

/// Text from git with escape sequences and invisible controls removed; newlines kept.
fn clean(text: &str) -> String {
    strip_ansi_escapes::strip_str(text.replace('\t', "    "))
        .chars()
        .filter(|&ch| ch == '\n' || !crate::render::line_utils::is_unsafe_display_char(ch))
        .collect()
}

/// [`clean`] for one line: newlines become spaces.
fn clean_line(text: &str) -> String {
    clean(&text.replace(['\n', '\r'], " "))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::git_graph::data::GitRef;
    use crate::git_graph::layout;
    use ratatui::Terminal;
    use ratatui::backend::TestBackend;

    fn commit(hash: &str, parents: &str, subject: &str) -> Commit {
        Commit {
            hash: format!("{hash}{}", "0".repeat(40 - hash.len())),
            parents: parents
                .split_whitespace()
                .map(|parent| format!("{parent}{}", "0".repeat(40 - parent.len())))
                .collect(),
            author: "Ada Lovelace".into(),
            email: "ada@example.com".into(),
            time: 1_700_000_000,
            subject: subject.into(),
            ..Commit::default()
        }
    }

    fn graph(mut commits: Vec<Commit>) -> GraphData {
        let rows = layout::layout(commits.iter().map(|commit| {
            (
                commit.hash.as_str(),
                commit.parents.iter().map(String::as_str),
            )
        }));
        if let Some(first) = commits.iter_mut().find(|c| c.uncommitted.is_none()) {
            first.is_head = true;
            first.refs.push(GitRef {
                name: "main".into(),
                kind: RefKind::Head,
            });
        }
        GraphData {
            root: PathBuf::from("/work/repo"),
            branch: Some("main".into()),
            head: commits.first().map(|c| c.hash.clone()),
            lanes: rows.iter().map(Row::width).max().unwrap_or(0),
            rows,
            commits,
            limit: data::PAGE,
            local_branches: 2,
            remote_branches: 1,
            tags: 1,
            ..GraphData::default()
        }
    }

    fn fixture() -> GraphData {
        let mut commits = vec![
            commit("m2", "m1 f2", "Merge branch 'feature'"),
            commit("f2", "f1", "Polish the feature"),
            commit("m1", "m0", "Fix the build"),
            commit("f1", "m0", "Start the feature"),
            commit("m0", "", "Initial commit"),
        ];
        commits[1].refs.push(GitRef {
            name: "feature".into(),
            kind: RefKind::Local,
        });
        commits[1].refs.push(GitRef {
            name: "origin/feature".into(),
            kind: RefKind::Remote,
        });
        commits[4].refs.push(GitRef {
            name: "v1.0".into(),
            kind: RefKind::Tag,
        });
        commits[2].body = "Body line one.\n\nBody \u{1b}[31mline\u{1b}[0m two.".into();
        graph(commits)
    }

    fn ready(data: GraphData) -> GitGraphOverlay {
        let (mut overlay, request) = GitGraphOverlay::open(PathBuf::from("/work/repo"));
        let Request::Load { generation, .. } = request else {
            panic!("expected a load request");
        };
        overlay.apply(Response::Loaded {
            generation,
            result: Ok(Box::new(data)),
        });
        if let Some(explorer) = overlay.explorer.as_mut() {
            explorer.now = 1_700_000_000 + 3 * 3_600;
        }
        overlay
    }

    fn key(code: KeyCode) -> KeyEvent {
        KeyEvent::new(code, KeyModifiers::NONE)
    }

    fn screen(terminal: &Terminal<TestBackend>) -> String {
        let buffer = terminal.backend().buffer();
        let width = buffer.area.width as usize;
        buffer
            .content()
            .chunks(width)
            .map(|row| {
                let line: String = row.iter().map(|cell| cell.symbol()).collect();
                line.trim_end().to_owned()
            })
            .collect::<Vec<_>>()
            .join("\n")
    }

    fn draw(terminal: &mut Terminal<TestBackend>, overlay: &mut GitGraphOverlay) {
        terminal
            .draw(|frame| {
                let area = frame.area();
                overlay.render(area, frame.buffer_mut(), &Theme::default());
            })
            .unwrap();
    }

    fn text(cells: &[Cell]) -> String {
        cells.iter().map(|cell| cell.glyph).collect::<String>()
    }

    #[test]
    fn sides_map_to_rounded_box_characters() {
        assert_eq!(glyph(0), ' ');
        assert_eq!(glyph(UP | DOWN), '│');
        assert_eq!(glyph(LEFT | RIGHT), '─');
        assert_eq!(glyph(UP | LEFT), '╯');
        assert_eq!(glyph(UP | RIGHT), '╰');
        assert_eq!(glyph(DOWN | LEFT), '╮');
        assert_eq!(glyph(DOWN | RIGHT), '╭');
        assert_eq!(glyph(UP | DOWN | LEFT), '┤');
        assert_eq!(glyph(UP | DOWN | RIGHT), '├');
        assert_eq!(glyph(DOWN | LEFT | RIGHT), '┬');
        assert_eq!(glyph(UP | LEFT | RIGHT), '┴');
        assert_eq!(glyph(UP | DOWN | LEFT | RIGHT), '┼');
    }

    #[test]
    fn lane_palettes_leave_out_gray_accents() {
        for theme in [
            Theme::groknight(),
            Theme::grokday(),
            Theme::tokyonight(),
            Theme::rosepine_moon(),
            Theme::oscura_midnight(),
        ] {
            let colors = palette(&theme);
            assert!(colors.len() >= 5, "{colors:?}");
            assert!(colors.iter().all(|&color| is_vivid(color)), "{colors:?}");
        }
        // Grok Night's `accent_user` is a gray, so its first lane takes the next accent.
        let night = Theme::groknight();
        assert!(!is_vivid(night.accent_user));
        assert_eq!(palette(&night).first(), Some(&night.accent_skill));
        assert!(!is_vivid(Color::Rgb(120, 120, 128)));
        assert!(is_vivid(Color::Blue));
    }

    #[test]
    fn rows_draw_merges_branches_and_crossings() {
        let rows = layout::layout(
            [
                ("m", vec!["b", "f"]),
                ("t", vec!["b"]),
                ("f", vec!["a"]),
                ("b", vec!["a"]),
                ("a", vec![]),
            ]
            .iter()
            .map(|(hash, parents)| (*hash, parents.iter().copied())),
        );
        let lines: Vec<String> = rows
            .iter()
            .map(|row| text(&graph_cells(row, '●')).trim_end().to_owned())
            .collect();
        assert_eq!(
            lines,
            vec![
                "●─╮",   // merge opens lane 1 for f
                "│ │ ●", // tip t in a new lane 2
                "│ ● │", // f in lane 1
                "●─┼─╯", // b: t's lane ends here, crossing f's lane
                "●─╯",   // a: f's lane ends here
            ]
        );
    }

    #[test]
    fn a_merge_into_a_waiting_lane_joins_it() {
        let rows = layout::layout(
            [
                ("t", vec!["f"]),
                ("m", vec!["a", "f"]),
                ("f", vec!["a"]),
                ("a", vec![]),
            ]
            .iter()
            .map(|(hash, parents)| (*hash, parents.iter().copied())),
        );
        let second = text(&graph_cells(&rows[1], '○'));
        assert_eq!(second.trim_end(), "├─○");
    }

    #[test]
    fn graph_spans_clip_wide_graphs() {
        let data = fixture();
        let spans = graph_spans(
            &data.rows[0],
            &data.commits[0],
            2,
            &Theme::default(),
            &palette(&Theme::default()),
        );
        let text: String = spans.iter().map(|span| span.content.as_ref()).collect();
        assert_eq!(text, "◉…");
    }

    #[test]
    fn renders_wide_narrow_and_help() {
        let mut overlay = ready(fixture());
        let mut terminal = Terminal::new(TestBackend::new(140, 16)).unwrap();
        draw(&mut terminal, &mut overlay);
        let wide = screen(&terminal);
        for expected in [
            "git graph",
            "repo",
            "on main",
            "5 commits · 2 branches · 1 remote · 1 tags · All branches",
            "HEAD → main",
            " feature ",
            "origin/feature",
            "tag:v1.0",
            "Merge branch 'feature'",
            "Ada Lovelace",
            "3h",
            "Commit · Tab to focus",
            "Reading changed files…",
            "◉─╮",
        ] {
            assert!(wide.contains(expected), "missing {expected:?} in\n{wide}");
        }
        // Narrow terminals show the list, and the details in its place on Tab.
        let mut terminal = Terminal::new(TestBackend::new(72, 14)).unwrap();
        draw(&mut terminal, &mut overlay);
        let narrow = screen(&terminal);
        assert!(narrow.contains("Commits · 1/5"));
        assert!(!narrow.contains("Commit · Tab"));
        assert_eq!(overlay.key(key(KeyCode::Tab)), OverlayOutcome::Changed);
        draw(&mut terminal, &mut overlay);
        assert!(screen(&terminal).contains("Commit · focused"));
        // Help, and a terminal too small to use.
        overlay.key(key(KeyCode::Char('?')));
        draw(&mut terminal, &mut overlay);
        assert!(screen(&terminal).contains("READ THE GRAPH"));
        let mut tiny = Terminal::new(TestBackend::new(20, 5)).unwrap();
        draw(&mut tiny, &mut overlay);
        assert!(screen(&tiny).contains("Resize"));
    }

    #[test]
    fn details_show_metadata_body_and_files_without_escape_sequences() {
        let (mut overlay, Request::Load { generation, .. }) =
            GitGraphOverlay::open(PathBuf::from("/work/repo"))
        else {
            unreachable!()
        };
        let follow = overlay.apply(Response::Loaded {
            generation,
            result: Ok(Box::new(fixture())),
        });
        assert!(
            matches!(follow, Some(Request::Files { ref hash, .. }) if hash.starts_with("m2")),
            "the first commit's files are requested as the graph arrives"
        );
        overlay.key(key(KeyCode::Down));
        let request = overlay.key(key(KeyCode::Down));
        let OverlayOutcome::Request(Request::Files {
            root,
            hash,
            parents,
        }) = request
        else {
            panic!("moving to a new commit requests its files, got {request:?}");
        };
        assert!(hash.starts_with("m1"));
        assert_eq!(parents.len(), 1);
        overlay.apply(Response::Files {
            root,
            hash,
            result: Ok(vec![
                FileStat {
                    path: "src/lib.rs".into(),
                    added: Some(12),
                    removed: Some(3),
                },
                FileStat {
                    path: "logo.png".into(),
                    added: None,
                    removed: None,
                },
            ]),
        });
        let mut terminal = Terminal::new(TestBackend::new(140, 24)).unwrap();
        draw(&mut terminal, &mut overlay);
        let text = screen(&terminal);
        for expected in [
            "Fix the build",
            "commit  m1",
            "parent  m000000",
            "author  Ada Lovelace <ada@example.com>",
            "Body line one.",
            "Body line two.",
            "2 files changed  +12 −3",
            "src/lib.rs",
            "binary  logo.png",
        ] {
            assert!(text.contains(expected), "missing {expected:?} in\n{text}");
        }
        assert!(!text.contains('\u{1b}'));
    }

    #[test]
    fn empty_repositories_and_load_errors_render() {
        let mut overlay = ready(GraphData {
            root: PathBuf::from("/work/empty"),
            ..GraphData::default()
        });
        let mut terminal = Terminal::new(TestBackend::new(120, 12)).unwrap();
        draw(&mut terminal, &mut overlay);
        let text = screen(&terminal);
        assert!(text.contains("No commits yet."), "{text}");
        assert!(text.contains("no commits yet"));

        let (mut overlay, request) = GitGraphOverlay::open(PathBuf::from("/tmp/plain"));
        draw(&mut terminal, &mut overlay);
        assert!(screen(&terminal).contains("Reading the commit graph"));
        let Request::Load { generation, .. } = request else {
            unreachable!()
        };
        overlay.apply(Response::Loaded {
            generation,
            result: Err("Not a git repository: /tmp/plain".into()),
        });
        draw(&mut terminal, &mut overlay);
        let text = screen(&terminal);
        assert!(text.contains("Not a git repository: /tmp/plain"), "{text}");
        assert!(matches!(
            overlay.key(key(KeyCode::Char('r'))),
            OverlayOutcome::Request(Request::Load { .. })
        ));
        assert_eq!(overlay.key(key(KeyCode::Esc)), OverlayOutcome::Close);
    }

    #[test]
    fn navigation_search_and_scope_keys() {
        let mut overlay = ready(fixture());
        let selected = |overlay: &GitGraphOverlay| overlay.explorer.as_ref().unwrap().selected;
        overlay.key(key(KeyCode::Char('G')));
        assert_eq!(selected(&overlay), 4);
        overlay.key(key(KeyCode::Char('g')));
        assert_eq!(selected(&overlay), 0);
        // Incremental search jumps to the first match; n and N cycle.
        overlay.key(key(KeyCode::Char('/')));
        for ch in "feature".chars() {
            overlay.key(key(KeyCode::Char(ch)));
        }
        assert_eq!(selected(&overlay), 0, "the merge subject names the feature");
        overlay.key(key(KeyCode::Enter));
        overlay.key(key(KeyCode::Char('n')));
        assert_eq!(selected(&overlay), 1);
        overlay.key(key(KeyCode::Char('n')));
        assert_eq!(selected(&overlay), 3);
        overlay.key(key(KeyCode::Char('N')));
        assert_eq!(selected(&overlay), 1);
        // Hash prefixes match too.
        overlay.key(key(KeyCode::Char('/')));
        overlay.key(key(KeyCode::Char('u')));
        overlay.key(KeyEvent::new(KeyCode::Char('u'), KeyModifiers::CONTROL));
        for ch in "m0".chars() {
            overlay.key(key(KeyCode::Char(ch)));
        }
        assert_eq!(selected(&overlay), 4);
        // Esc while searching restores the previous query and selection.
        overlay.key(key(KeyCode::Esc));
        assert_eq!(selected(&overlay), 1);
        assert_eq!(overlay.explorer.as_ref().unwrap().query, "feature");
        // Esc clears the search before it closes.
        assert_eq!(overlay.key(key(KeyCode::Esc)), OverlayOutcome::Changed);
        assert_eq!(overlay.key(key(KeyCode::Esc)), OverlayOutcome::Close);

        // a switches scope and reloads; m does nothing unless more history exists.
        let OverlayOutcome::Request(Request::Load {
            scope, generation, ..
        }) = overlay.key(key(KeyCode::Char('a')))
        else {
            panic!("a reloads");
        };
        assert_eq!(scope, Scope::Current);
        assert_eq!(generation, 2);
        assert!(overlay.is_loading());
        assert!(!matches!(
            overlay.key(key(KeyCode::Char('m'))),
            OverlayOutcome::Request(_)
        ));
        // A stale load is ignored; the current one replaces the graph and keeps the selection.
        assert!(
            overlay
                .apply(Response::Loaded {
                    generation: 1,
                    result: Err("stale".into()),
                })
                .is_none()
        );
        assert!(overlay.error.is_none());
        let mut more = fixture();
        more.truncated = true;
        overlay.apply(Response::Loaded {
            generation: 2,
            result: Ok(Box::new(more)),
        });
        assert!(!overlay.is_loading());
        assert_eq!(selected(&overlay), 1);
        let OverlayOutcome::Request(Request::Load { limit, .. }) =
            overlay.key(key(KeyCode::Char('m')))
        else {
            panic!("m reads more history when it is truncated");
        };
        assert_eq!(limit, data::PAGE * 2);
        // The wheel moves the selection.
        overlay.scroll(-1);
        assert_eq!(selected(&overlay), 0);
    }

    #[test]
    fn uncommitted_changes_row_is_drawn_above_head() {
        let mut commits = vec![
            Commit {
                hash: data::UNCOMMITTED.into(),
                parents: vec![format!("c1{}", "0".repeat(38))],
                subject: "Uncommitted changes · 2 files".into(),
                uncommitted: Some(2),
                ..Commit::default()
            },
            commit("c1", "c0", "Second"),
            commit("c0", "", "First"),
        ];
        commits[1].is_head = true;
        let mut overlay = ready(graph(commits));
        let mut terminal = Terminal::new(TestBackend::new(120, 12)).unwrap();
        draw(&mut terminal, &mut overlay);
        let text = screen(&terminal);
        assert!(text.contains("◌ Uncommitted changes · 2 files"), "{text}");
        assert!(text.contains("◉  HEAD → main "), "{text}");
        assert!(text.contains("2 paths changed in the working tree."));
        assert!(
            text.contains(" 2 commits ·"),
            "the uncommitted row is not a commit"
        );
    }

    #[test]
    fn relative_dates_and_cleaning() {
        assert_eq!(ago(100, 100), "now");
        assert_eq!(ago(10_000, 100), "2h");
        assert_eq!(ago(100 + 3 * 86_400, 100), "3d");
        assert_eq!(ago(100 + 65 * 86_400, 100), "2mo");
        assert_eq!(ago(100 + 800 * 86_400, 100), "2y");
        assert_eq!(clean_line("a\u{1b}[2Jb\nc\u{202e}d"), "ab cd");
    }
}
