//! The relay's wire shapes (`relay/convex/schema.ts`, `relay/convex/bridge.ts`), as the computer sends and reads them.

use serde::{Deserialize, Serialize};

/// Which crok front end runs this process.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum HostApp {
    Tui,
    Desktop,
    Cli,
}

impl HostApp {
    pub fn as_str(self) -> &'static str {
        match self {
            HostApp::Tui => "tui",
            HostApp::Desktop => "desktop",
            HostApp::Cli => "cli",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum SessionStatus {
    Idle,
    Running,
    /// The agent asked a question or a permission on the computer.
    Waiting,
    Error,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum EventKind {
    User,
    Assistant,
    Thought,
    Tool,
    System,
    Error,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct PlanEntry {
    pub content: String,
    pub status: String,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionUsage {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub input_tokens: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub output_tokens: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cached_tokens: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reasoning_tokens: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cost_usd: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub context_tokens: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub context_window: Option<f64>,
}

/// Fields of a mirrored session. Only the ones set are sent, and the relay writes only those that changed.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionFields {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cwd: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub effort: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub git_branch: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub status: Option<SessionStatus>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub preview: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub preview_kind: Option<EventKind>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub plan: Option<Vec<PlanEntry>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub usage: Option<SessionUsage>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub created_at: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_activity_at: Option<f64>,
}

impl SessionFields {
    pub fn is_empty(&self) -> bool {
        *self == SessionFields::default()
    }

    /// The fields of `next` that differ from `self`, for sending only what changed.
    pub fn changes_to(&self, next: &SessionFields) -> SessionFields {
        fn diff<T: Clone + PartialEq>(old: &Option<T>, new: &Option<T>) -> Option<T> {
            match new {
                Some(value) if old.as_ref() != Some(value) => Some(value.clone()),
                _ => None,
            }
        }
        SessionFields {
            title: diff(&self.title, &next.title),
            cwd: diff(&self.cwd, &next.cwd),
            model: diff(&self.model, &next.model),
            effort: diff(&self.effort, &next.effort),
            git_branch: diff(&self.git_branch, &next.git_branch),
            status: diff(&self.status, &next.status),
            preview: diff(&self.preview, &next.preview),
            preview_kind: diff(&self.preview_kind, &next.preview_kind),
            plan: diff(&self.plan, &next.plan),
            usage: diff(&self.usage, &next.usage),
            created_at: diff(&self.created_at, &next.created_at),
            last_activity_at: diff(&self.last_activity_at, &next.last_activity_at),
        }
    }

    /// Takes every field `other` sets.
    pub fn merge(&mut self, other: SessionFields) {
        macro_rules! take {
            ($($field:ident),*) => { $( if other.$field.is_some() { self.$field = other.$field; } )* };
        }
        take!(
            title,
            cwd,
            model,
            effort,
            git_branch,
            status,
            preview,
            preview_kind,
            plan,
            usage,
            created_at,
            last_activity_at
        );
    }
}

/// One transcript item. The relay updates an existing item with the same `key` in place.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EventInput {
    pub key: String,
    pub kind: EventKind,
    pub text: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tool_kind: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub status: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub origin: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub command_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub from_label: Option<String>,
    /// Unix milliseconds.
    pub at: f64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum CommandType {
    Prompt,
    Cancel,
    Info,
}

/// A command from a phone or the web, as `bridge:inbox` lists it.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct InboxCommand {
    #[serde(rename = "_id")]
    pub id: String,
    pub session_doc_id: String,
    pub session_id: String,
    #[serde(rename = "type")]
    pub kind: CommandType,
    #[serde(default)]
    pub text: Option<String>,
    pub from_label: String,
    /// `web` for a browser, `phone` (or `computer`) for a linked device.
    #[serde(default)]
    pub from_kind: Option<String>,
    pub created_at: f64,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct InboxView {
    pub session_doc_id: String,
    pub session_id: String,
    pub until: f64,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Inbox {
    pub commands: Vec<InboxCommand>,
    pub views: Vec<InboxView>,
    pub server_time: f64,
}

/// A command's outcome.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum CommandOutcome {
    Done,
    Failed,
}

pub fn now_ms() -> f64 {
    chrono::Utc::now().timestamp_millis() as f64
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn changes_hold_only_what_differs() {
        let old = SessionFields {
            title: Some("a".into()),
            status: Some(SessionStatus::Idle),
            ..Default::default()
        };
        let new = SessionFields {
            title: Some("a".into()),
            status: Some(SessionStatus::Running),
            cwd: Some("/x".into()),
            ..Default::default()
        };
        let changes = old.changes_to(&new);
        assert_eq!(changes.title, None);
        assert_eq!(changes.status, Some(SessionStatus::Running));
        assert_eq!(changes.cwd.as_deref(), Some("/x"));
    }

    #[test]
    fn fields_serialize_camel_case_without_nulls() {
        let fields = SessionFields {
            git_branch: Some("main".into()),
            preview_kind: Some(EventKind::Assistant),
            ..Default::default()
        };
        assert_eq!(
            serde_json::to_value(&fields).unwrap(),
            serde_json::json!({"gitBranch": "main", "previewKind": "assistant"})
        );
    }

    #[test]
    fn inbox_parses() {
        let inbox: Inbox = serde_json::from_value(serde_json::json!({
            "commands": [{"_id": "c1", "sessionDocId": "s1", "sessionId": "abc", "type": "prompt",
                          "text": "hi", "fromLabel": "iPhone", "createdAt": 1.0}],
            "views": [{"sessionDocId": "s1", "sessionId": "abc", "until": 5.0}],
            "serverTime": 2.0
        }))
        .unwrap();
        assert_eq!(inbox.commands[0].kind, CommandType::Prompt);
        assert_eq!(inbox.views[0].session_id, "abc");
    }
}
