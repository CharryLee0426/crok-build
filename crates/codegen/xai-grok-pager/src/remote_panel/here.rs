//! Sessions other devices start on this computer (a phone, the web, another computer). Its crok opens them hidden
//! from this TUI, so while the TUI is connected to the relay it keeps `x.ai/remote/sessions {watch: true}` going and
//! says when one starts; `/resume` and the Remote panel ("This computer") open it here. relay/DESIGN.md §5.

use std::collections::HashSet;
use std::time::Duration;

use serde_json::Value;
use xai_grok_i18n::tlf;

use super::tree::{StartedHere, parse_here};

/// How often the watch is renewed (the agent keeps sending changes for ten minutes after it was asked).
pub const REWATCH: Duration = Duration::from_secs(4 * 60);
/// How soon it asks again after the agent could not answer.
pub const RETRY: Duration = Duration::from_secs(30);

/// The watch's state. Each start is a new generation: answers for an older one are dropped, so reconnecting never
/// leaves two loops renewing the watch.
#[derive(Debug, Default)]
pub struct HereWatch {
    generation: u64,
    running: bool,
    /// The sessions seen so far; `None` until the first list, whose sessions are not announced.
    known: Option<HashSet<String>>,
}

impl HereWatch {
    /// The bridge reports its link: on `connected`, the generation of a new watch loop to start (its first ask goes
    /// out at once), unless one runs.
    pub fn link_state(&mut self, state: &str) -> Option<u64> {
        if state != "connected" || self.running {
            return None;
        }
        self.running = true;
        self.generation += 1;
        Some(self.generation)
    }

    /// The answer to a watch loop's ask: what to announce, and when to ask again (`None`: the loop ends, since this
    /// computer is signed out, or a newer loop runs).
    pub fn answered(
        &mut self,
        generation: u64,
        result: &Result<Value, String>,
    ) -> (Vec<String>, Option<Duration>) {
        if generation != self.generation || !self.running {
            return (Vec::new(), None);
        }
        match result {
            Ok(payload) if payload.get("signedIn").and_then(Value::as_bool) == Some(true) => {
                (self.changed(payload), Some(REWATCH))
            }
            Ok(_) => {
                self.running = false;
                (Vec::new(), None)
            }
            Err(_) => (Vec::new(), Some(RETRY)),
        }
    }

    /// A new copy of the list: one line for each session another device started here since the last copy.
    pub fn changed(&mut self, payload: &Value) -> Vec<String> {
        if payload.get("here").is_none() {
            return Vec::new();
        }
        let sessions = parse_here(payload);
        let ids: HashSet<String> = sessions.iter().map(|s| s.session_id.clone()).collect();
        let Some(known) = self.known.replace(ids.clone()) else {
            return Vec::new();
        };
        sessions
            .iter()
            .filter(|session| !known.contains(&session.session_id))
            .map(announcement)
            .collect()
    }
}

fn announcement(session: &StartedHere) -> String {
    let project = std::path::Path::new(&session.project_path)
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_else(|| session.project_path.clone());
    let title = if session.title.is_empty() {
        project.clone()
    } else {
        session.title.clone()
    };
    tlf(
        "{device} started a session in {project}: {title} — /resume or /remote opens it",
        &[
            ("device", &session.from),
            ("project", &project),
            ("title", &title),
        ],
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn list(ids: &[&str]) -> Value {
        let sessions: Vec<Value> = ids
            .iter()
            .map(|id| {
                json!({ "sessionId": id, "title": format!("Task {id}"), "projectPath": "/w/app",
                        "startedFrom": { "kind": "phone", "name": "iPhone", "at": 1.0 } })
            })
            .collect();
        json!({ "signedIn": true, "computers": [], "here": { "deviceId": "me", "sessions": sessions } })
    }

    #[test]
    fn sessions_started_elsewhere_are_announced_once_after_the_first_list() {
        let mut watch = HereWatch::default();
        let generation = watch.link_state("connected").unwrap();
        assert_eq!(watch.link_state("connected"), None, "one loop at a time");
        let (lines, next) = watch.answered(generation, &Ok(list(&["a"])));
        assert!(lines.is_empty(), "what was there before is not news");
        assert_eq!(next, Some(REWATCH));
        let lines = watch.changed(&list(&["b", "a"]));
        assert_eq!(lines.len(), 1);
        assert!(
            lines[0].contains("iPhone") && lines[0].contains("Task b") && lines[0].contains("app")
        );
        assert!(watch.changed(&list(&["b", "a"])).is_empty());
    }

    #[test]
    fn the_loop_ends_signed_out_and_ignores_old_answers() {
        let mut watch = HereWatch::default();
        let first = watch.link_state("connected").unwrap();
        let (_, next) = watch.answered(first, &Ok(json!({ "signedIn": false, "computers": [] })));
        assert_eq!(next, None);
        let second = watch.link_state("connected").unwrap();
        assert_ne!(first, second);
        assert_eq!(watch.answered(first, &Ok(list(&["a"]))).1, None);
        assert_eq!(
            watch.answered(second, &Err("timeout".into())).1,
            Some(RETRY)
        );
    }
}
