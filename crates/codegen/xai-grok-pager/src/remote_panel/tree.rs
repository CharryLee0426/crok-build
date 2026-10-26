//! The Remote panel's data: the person's other computers as `x.ai/remote/sessions` lists them (computers → projects →
//! sessions), with this computer's sessions that other devices started first ("This computer"), the rows the panel
//! shows for them under the fold state and the filter, and the models a computer offers (`x.ai/remote/models`).

use std::collections::HashMap;

use serde_json::Value;
use xai_grok_i18n::tl;

use crate::views::session_picker::fuzzy_matches_session;

fn text(value: &Value, key: &str) -> Option<String> {
    value
        .get(key)
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_owned)
}

fn list<'a>(value: &'a Value, key: &str) -> impl Iterator<Item = &'a Value> {
    value
        .get(key)
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
}

/// One of the person's other computers.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Computer {
    pub device_id: String,
    pub name: String,
    pub online: bool,
    /// When it was last heard from (ms since the epoch): the relay's `lastSeenAt` when the list carries it, else its
    /// newest session's activity.
    pub last_seen_ms: Option<f64>,
    /// In the relay's order.
    pub projects: Vec<Project>,
    /// This computer: its sessions another device started, which open here as its own (by their crok ids).
    pub here: bool,
}

impl Computer {
    pub fn unread(&self) -> u64 {
        self.projects.iter().map(Project::unread).sum()
    }
}

/// A folder of a computer with its sessions.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Project {
    pub name: String,
    pub path: String,
    pub sessions: Vec<Session>,
}

impl Project {
    pub fn unread(&self) -> u64 {
        self.sessions.iter().map(|s| s.unread).sum()
    }
}

/// A session of another computer, opened here by its `relay:` id.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Session {
    pub session_id: String,
    pub title: String,
    pub cwd: String,
    /// `idle`, `running`, `waiting` (a permission request) or `error`.
    pub status: String,
    /// Asked for from some device and not open on its computer yet.
    pub starting: bool,
    pub last_activity_ms: Option<f64>,
    pub unread: u64,
    /// A session of this computer: the device that started it (`iPhone`, `Web`).
    pub from: Option<String>,
}

/// What a session is doing, for its row.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Activity {
    Working,
    NeedsApproval,
    Starting,
}

impl Session {
    pub fn activity(&self) -> Option<Activity> {
        if self.starting {
            return Some(Activity::Starting);
        }
        match self.status.as_str() {
            "running" => Some(Activity::Working),
            "waiting" => Some(Activity::NeedsApproval),
            _ => None,
        }
    }
}

/// One of this computer's sessions that another device started (`here` in `x.ai/remote/sessions`), newest first.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct StartedHere {
    /// Its crok session id.
    pub session_id: String,
    pub title: String,
    pub cwd: String,
    pub project_path: String,
    pub status: String,
    pub last_activity_ms: Option<f64>,
    /// The device that started it.
    pub from: String,
}

pub fn parse_here(payload: &Value) -> Vec<StartedHere> {
    let Some(here) = payload.get("here") else {
        return Vec::new();
    };
    list(here, "sessions")
        .filter_map(|session| {
            let session_id = text(session, "sessionId")?;
            let cwd = text(session, "cwd").unwrap_or_default();
            Some(StartedHere {
                title: text(session, "title").unwrap_or_default(),
                project_path: text(session, "projectPath").unwrap_or_else(|| cwd.clone()),
                cwd,
                status: text(session, "status").unwrap_or_default(),
                last_activity_ms: session.get("lastActivityAt").and_then(Value::as_f64),
                from: session
                    .get("startedFrom")
                    .and_then(|from| text(from, "name"))
                    .unwrap_or_default(),
                session_id,
            })
        })
        .collect()
}

/// "This computer", for the panel: the sessions other devices started here, by project (in the order of their newest
/// session). `None` when there are none.
fn here_computer(payload: &Value) -> Option<Computer> {
    let sessions = parse_here(payload);
    if sessions.is_empty() {
        return None;
    }
    let mut projects: Vec<Project> = Vec::new();
    for session in sessions {
        let path = session.project_path.clone();
        let at = match projects.iter().position(|p| p.path == path) {
            Some(at) => at,
            None => {
                let name = std::path::Path::new(&path)
                    .file_name()
                    .map(|n| n.to_string_lossy().into_owned())
                    .filter(|n| !n.is_empty())
                    .unwrap_or_else(|| path.clone());
                projects.push(Project {
                    name,
                    path,
                    sessions: Vec::new(),
                });
                projects.len() - 1
            }
        };
        if let Some(project) = projects.get_mut(at) {
            project.sessions.push(Session {
                session_id: session.session_id,
                title: session.title,
                cwd: session.cwd,
                status: session.status,
                starting: false,
                last_activity_ms: session.last_activity_ms,
                unread: 0,
                from: (!session.from.is_empty()).then_some(session.from),
            });
        }
    }
    let device_id = payload
        .get("here")
        .and_then(|here| text(here, "deviceId"))
        .unwrap_or_else(|| "here".to_string());
    Some(Computer {
        device_id,
        name: tl("This computer").to_string(),
        online: true,
        last_seen_ms: None,
        projects,
        here: true,
    })
}

/// The `x.ai/remote/sessions` payload (also the `x.ai/remote/sessions_changed` notification's): whether this computer
/// is signed in, and its other computers in the relay's order, after this computer when other devices started
/// sessions on it.
pub fn parse_sessions(payload: &Value) -> (bool, Vec<Computer>) {
    let signed_in = payload.get("signedIn").and_then(Value::as_bool) == Some(true);
    let others = list(payload, "computers").filter_map(|computer| {
        let device_id = text(computer, "deviceId")?;
        let projects: Vec<Project> = list(computer, "projects")
            .filter_map(|project| {
                let path = text(project, "path")?;
                let sessions = list(project, "sessions")
                    .filter_map(|session| {
                        let session_id = text(session, "sessionId")?;
                        Some(Session {
                            session_id,
                            title: text(session, "title").unwrap_or_default(),
                            cwd: text(session, "cwd").unwrap_or_default(),
                            status: text(session, "status").unwrap_or_default(),
                            starting: session.get("starting").and_then(Value::as_bool)
                                == Some(true),
                            last_activity_ms: session.get("lastActivityAt").and_then(Value::as_f64),
                            unread: session.get("unread").and_then(Value::as_u64).unwrap_or(0),
                            from: None,
                        })
                    })
                    .collect();
                Some(Project {
                    name: text(project, "name").unwrap_or_else(|| path.clone()),
                    path,
                    sessions,
                })
            })
            .collect();
        let newest = projects
            .iter()
            .flat_map(|p| &p.sessions)
            .filter_map(|s| s.last_activity_ms)
            .fold(None, |newest: Option<f64>, at| {
                Some(newest.map_or(at, |n| n.max(at)))
            });
        Some(Computer {
            name: text(computer, "deviceName").unwrap_or_else(|| device_id.clone()),
            device_id,
            online: computer.get("online").and_then(Value::as_bool) == Some(true),
            last_seen_ms: computer
                .get("lastSeenAt")
                .and_then(Value::as_f64)
                .or(newest),
            projects,
            here: false,
        })
    });
    let computers = here_computer(payload).into_iter().chain(others).collect();
    (signed_in, computers)
}

/// A row's identity, which outlives a refresh of the list: the fold state and the selection are kept by it.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum RowKey {
    Computer(String),
    Project { device_id: String, path: String },
    Session(String),
}

/// A row of the tree, by position in [`Computer`]s.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RowKind {
    Computer { c: usize },
    Project { c: usize, p: usize },
    Session { c: usize, p: usize, s: usize },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Row {
    pub kind: RowKind,
    /// The row itself matches the filter (not only a row above or below it).
    pub matched: bool,
}

impl RowKind {
    pub fn computer(self) -> usize {
        match self {
            Self::Computer { c } | Self::Project { c, .. } | Self::Session { c, .. } => c,
        }
    }

    /// The project of a project row or of a session row.
    pub fn project(self) -> Option<(usize, usize)> {
        match self {
            Self::Computer { .. } => None,
            Self::Project { c, p } | Self::Session { c, p, .. } => Some((c, p)),
        }
    }

    pub fn depth(self) -> u8 {
        match self {
            Self::Computer { .. } => 0,
            Self::Project { .. } => 1,
            Self::Session { .. } => 2,
        }
    }

    pub fn key(self, computers: &[Computer]) -> Option<RowKey> {
        let computer = computers.get(self.computer())?;
        Some(match self {
            Self::Computer { .. } => RowKey::Computer(computer.device_id.clone()),
            Self::Project { p, .. } => RowKey::Project {
                device_id: computer.device_id.clone(),
                path: computer.projects.get(p)?.path.clone(),
            },
            Self::Session { p, s, .. } => RowKey::Session(
                computer
                    .projects
                    .get(p)?
                    .sessions
                    .get(s)?
                    .session_id
                    .clone(),
            ),
        })
    }
}

/// Which computers and projects are open. Online computers start open and offline ones folded; projects start open,
/// or folded when the panel opens at the project list (`/remote new`).
#[derive(Clone, Debug, Default)]
pub struct Folds {
    chosen: HashMap<RowKey, bool>,
    projects_folded: bool,
}

impl Folds {
    pub fn new(projects_folded: bool) -> Self {
        Self {
            chosen: HashMap::new(),
            projects_folded,
        }
    }

    pub fn is_open(&self, kind: RowKind, computers: &[Computer]) -> bool {
        let default = match kind {
            RowKind::Computer { c } => computers.get(c).is_some_and(|c| c.online),
            RowKind::Project { .. } => !self.projects_folded,
            RowKind::Session { .. } => return false,
        };
        kind.key(computers)
            .and_then(|key| self.chosen.get(&key).copied())
            .unwrap_or(default)
    }

    pub fn set(&mut self, kind: RowKind, computers: &[Computer], open: bool) {
        if let Some(key) = kind.key(computers) {
            self.chosen.insert(key, open);
        }
    }
}

/// The rows to show. Without a filter the tree follows the fold state; with one (`query` lowercased) it shows the
/// rows that match, by title, project, folder or computer, with the rows above them, everything unfolded.
pub fn build_rows(computers: &[Computer], folds: &Folds, query: &str) -> Vec<Row> {
    let query = query.trim();
    let mut rows = Vec::new();
    let row = |kind, matched| Row { kind, matched };
    for (c, computer) in computers.iter().enumerate() {
        if query.is_empty() {
            rows.push(row(RowKind::Computer { c }, false));
            if !folds.is_open(RowKind::Computer { c }, computers) {
                continue;
            }
            for (p, project) in computer.projects.iter().enumerate() {
                rows.push(row(RowKind::Project { c, p }, false));
                if !folds.is_open(RowKind::Project { c, p }, computers) {
                    continue;
                }
                rows.extend(
                    (0..project.sessions.len()).map(|s| row(RowKind::Session { c, p, s }, false)),
                );
            }
            continue;
        }
        let computer_matches = fuzzy_matches_session(&computer.name, query);
        let mut below = Vec::new();
        for (p, project) in computer.projects.iter().enumerate() {
            let project_matches = fuzzy_matches_session(&project.name, query)
                || fuzzy_matches_session(&project.path, query);
            let sessions: Vec<Row> = project
                .sessions
                .iter()
                .enumerate()
                .filter_map(|(s, session)| {
                    let matched = fuzzy_matches_session(&session.title, query)
                        || fuzzy_matches_session(&session.cwd, query);
                    (matched || project_matches || computer_matches)
                        .then(|| row(RowKind::Session { c, p, s }, matched))
                })
                .collect();
            if project_matches || computer_matches || !sessions.is_empty() {
                below.push(row(RowKind::Project { c, p }, project_matches));
                below.extend(sessions);
            }
        }
        if computer_matches || !below.is_empty() {
            rows.push(row(RowKind::Computer { c }, computer_matches));
            rows.extend(below);
        }
    }
    rows
}

/// A thinking level a model offers.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Effort {
    /// What `x.ai/remote/new_session` takes.
    pub id: String,
    pub name: String,
    pub description: String,
    /// The model uses this level unless told otherwise.
    pub default: bool,
}

/// A model another computer can run.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Model {
    pub id: String,
    pub name: String,
    pub description: String,
    pub efforts: Vec<Effort>,
}

/// The `x.ai/remote/models` payload: `availableModels` in the agent's shape, else `models` in the relay's. Empty while
/// the computer is offline or has not published a list.
pub fn parse_models(payload: &Value) -> Vec<Model> {
    let agent_shape: Vec<Model> = list(payload, "availableModels")
        .filter_map(|model| {
            let id = text(model, "modelId")?;
            let efforts = model
                .get("_meta")
                .map(|meta| {
                    list(meta, "reasoningEfforts")
                        .filter_map(|effort| {
                            let id = text(effort, "id")?;
                            Some(Effort {
                                name: text(effort, "label")
                                    .or_else(|| text(effort, "name"))
                                    .unwrap_or_else(|| id.clone()),
                                description: text(effort, "description").unwrap_or_default(),
                                default: effort.get("default").and_then(Value::as_bool)
                                    == Some(true),
                                id,
                            })
                        })
                        .collect()
                })
                .unwrap_or_default();
            Some(Model {
                name: text(model, "name").unwrap_or_else(|| id.clone()),
                description: text(model, "description").unwrap_or_default(),
                efforts,
                id,
            })
        })
        .collect();
    if !agent_shape.is_empty() {
        return agent_shape;
    }
    list(payload, "models")
        .filter_map(|model| {
            let id = text(model, "id")?;
            let default = text(model, "defaultEffort");
            let efforts = list(model, "efforts")
                .filter_map(|effort| {
                    let id = text(effort, "id")?;
                    Some(Effort {
                        name: text(effort, "name").unwrap_or_else(|| id.clone()),
                        description: text(effort, "description").unwrap_or_default(),
                        default: default.as_deref() == Some(id.as_str()),
                        id,
                    })
                })
                .collect();
            Some(Model {
                name: text(model, "name").unwrap_or_else(|| id.clone()),
                description: text(model, "description").unwrap_or_default(),
                efforts,
                id,
            })
        })
        .collect()
}

/// The models `query` (lowercased) finds, by name, id or description, as indexes into `models`.
pub fn filter_models(models: &[Model], query: &str) -> Vec<usize> {
    let query = query.trim();
    models
        .iter()
        .enumerate()
        .filter(|(_, m)| {
            query.is_empty()
                || fuzzy_matches_session(&m.name, query)
                || fuzzy_matches_session(&m.id, query)
                || fuzzy_matches_session(&m.description, query)
        })
        .map(|(i, _)| i)
        .collect()
}
