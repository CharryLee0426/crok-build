//! Remote control in the TUI: `/remote` (status, sign-in, sign-out, on/off) and the footer's link indicator.
//!
//! The work happens in `crok_remote`; the agent's bridge (`xai_grok_shell::remote_control`) picks up a sign-in or
//! sign-out within a few seconds and reports its state with `x.ai/remote/status`.

use std::sync::atomic::{AtomicU8, Ordering};

use crok_remote::api::{Api, LoginStart};
use crok_remote::credentials;
use crok_remote::login::{self, LoginError, LoginRequest};
use crok_remote::settings;
use xai_grok_i18n::{tl, tlf};

use crate::app::actions::TaskResult;
use crate::app::agent::AgentId;

/// The bridge's state as the footer shows it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Indicator {
    Off,
    Connecting,
    Connected,
}

static INDICATOR: AtomicU8 = AtomicU8::new(0);

pub fn indicator() -> Indicator {
    match INDICATOR.load(Ordering::Relaxed) {
        1 => Indicator::Connecting,
        2 => Indicator::Connected,
        _ => Indicator::Off,
    }
}

/// From `x.ai/remote/status` (`{"state": "off" | "connecting" | "connected"}`).
pub fn set_indicator_from(state: &str) {
    let value = match state {
        "connecting" => 1,
        "connected" => 2,
        _ => 0,
    };
    INDICATOR.store(value, Ordering::Relaxed);
}

fn client_label() -> String {
    format!("crok {}", xai_grok_version::full_version())
}

/// `/remote` with no argument.
pub fn status_text() -> String {
    let enabled = settings::load().enabled;
    let Ok(Some(linked)) = credentials::load() else {
        return [
            tl("Remote control is off: this computer is not signed in.").to_string(),
            tl("Sign in with /remote login (or `crok remote login` in a terminal) to follow and steer these sessions from your phone or the web.")
                .to_string(),
        ]
        .join("\n");
    };
    let account = linked.account.display();
    let state = match (enabled, indicator()) {
        (false, _) => tl("turned off ([remote] enabled = false)"),
        (true, Indicator::Connected) => tl("connected"),
        (true, Indicator::Connecting) => tl("connecting…"),
        (true, Indicator::Off) => tl("starting…"),
    };
    let mut lines = vec![
        tlf("Remote control: {state}", &[("state", &state)]),
        format!(
            "  {} {}",
            tl("Account:"),
            if account.is_empty() {
                "—".to_string()
            } else {
                account
            }
        ),
        format!("  {} {}", tl("Computer:"), linked.device_name),
        format!("  {} {}", tl("Relay:"), linked.server),
    ];
    lines.push(tl("Use /remote off to stop sharing, /remote logout to sign out.").to_string());
    lines.join("\n")
}

/// `/remote on` and `/remote off`.
pub fn set_enabled(enabled: bool) -> Result<String, String> {
    settings::save_enabled(enabled).map_err(|error| format!("{error:#}"))?;
    Ok(if enabled {
        tl("Remote control is on: this computer's sessions are shared while it is signed in.")
            .to_string()
    } else {
        tl("Remote control is off: sessions are no longer shared, and phones cannot send prompts here.").to_string()
    })
}

/// `/remote login`, first half: get a code to show. The relay is the built-in one (or `CROK_REMOTE_URL`).
pub async fn login_start(agent_id: AgentId) -> TaskResult {
    let notice = |text: String| TaskResult::RemoteNotice {
        agent_id,
        text,
        toast: None,
    };
    if let Ok(Some(existing)) = credentials::load() {
        let who = existing.account.display();
        return notice(tlf(
            "Already signed in as {account}. Use /remote logout first to switch accounts.",
            &[("account", &who)],
        ));
    }
    let server = settings::server_url(None, None);
    if let Err(error) = settings::validate_url(&server) {
        return notice(format!("{error:#}"));
    }
    let request = LoginRequest {
        server: server.clone(),
        device_name: login::default_device_name(),
        platform: login::platform_label(),
        client: client_label(),
    };
    let api = match Api::new(&server) {
        Ok(api) => api,
        Err(error) => return notice(format!("{error:#}")),
    };
    match login::begin(&api, &request).await {
        Ok(start) => {
            let opened = start
                .verification_url_complete
                .as_deref()
                .is_some_and(login::open_in_browser);
            TaskResult::RemoteLoginCode {
                agent_id,
                request,
                start,
                opened,
            }
        }
        Err(error) => notice(error.to_string()),
    }
}

/// What the TUI shows while it waits for the code to be approved.
pub fn code_text(start: &LoginStart, opened: bool) -> String {
    let mut lines = vec![tl("Sign in to remote control").to_string()];
    if let Some(url) = &start.verification_url_complete {
        lines.push(format!("  {} {url}", tl("Open:")));
    }
    lines.push(format!("  {} {}", tl("Code:"), start.user_code));
    if opened {
        lines.push(tl("Opened the page in your browser. Sign in with GitHub or Google there and approve this computer.").to_string());
    } else if start.verification_url_complete.is_some() {
        lines.push(tl("Open the link on any device, sign in with GitHub or Google, and approve this computer.").to_string());
    } else {
        lines.push(
            tl("Approve the code from the Crok app on your phone: Settings › Link a computer.")
                .to_string(),
        );
    }
    lines.push(tl("Waiting for approval…").to_string());
    lines.join("\n")
}

/// `/remote login`, second half: wait for approval.
pub async fn login_wait(agent_id: AgentId, request: LoginRequest, start: LoginStart) -> TaskResult {
    let api = match Api::new(&request.server) {
        Ok(api) => api,
        Err(error) => {
            return TaskResult::RemoteNotice {
                agent_id,
                text: format!("{error:#}"),
                toast: None,
            };
        }
    };
    match login::wait(&api, &request, &start).await {
        Ok(linked) => {
            let who = linked.account.display();
            TaskResult::RemoteNotice {
                agent_id,
                text: [
                    format!(
                        "✓ {}",
                        tlf(
                            "Signed in as {account}. This computer is “{device}”.",
                            &[("account", &who), ("device", &linked.device_name)],
                        )
                    ),
                    tl("Your sessions here now show up in the Crok app and on the web.")
                        .to_string(),
                ]
                .join("\n"),
                toast: Some(tl("Remote control is on").to_string()),
            }
        }
        Err(error) => {
            let reason = match &error {
                LoginError::Other(error) => format!("{error:#}"),
                other => other.to_string(),
            };
            TaskResult::RemoteNotice {
                agent_id,
                text: tlf(
                    "Remote sign-in did not finish: {reason}",
                    &[("reason", &reason)],
                ),
                toast: None,
            }
        }
    }
}

/// `/remote logout`.
pub async fn logout(agent_id: AgentId) -> TaskResult {
    let text = match credentials::load() {
        Ok(Some(existing)) => {
            if let Ok(api) = Api::new(&existing.server) {
                let _ = tokio::time::timeout(
                    std::time::Duration::from_secs(10),
                    api.logout(&existing.refresh_token),
                )
                .await;
            }
            match credentials::remove() {
                Ok(_) => {
                    tl("Signed out of remote control. This computer no longer shares its sessions.")
                        .to_string()
                }
                Err(error) => format!("{error:#}"),
            }
        }
        Ok(None) => tl("This computer is not signed in to remote control.").to_string(),
        Err(error) => format!("{error:#}"),
    };
    TaskResult::RemoteNotice {
        agent_id,
        text,
        toast: None,
    }
}

/// One project of another computer that `/remote new` can start a session in.
#[derive(Clone, Debug, PartialEq)]
struct RemoteProject {
    device_id: String,
    computer: String,
    name: String,
    path: String,
}

/// The online computers' projects from `x.ai/remote/sessions`, in the relay's order.
fn remote_projects(payload: &serde_json::Value) -> Vec<RemoteProject> {
    let mut projects = Vec::new();
    for computer in payload
        .get("computers")
        .and_then(serde_json::Value::as_array)
        .into_iter()
        .flatten()
    {
        if computer.get("online").and_then(serde_json::Value::as_bool) != Some(true) {
            continue;
        }
        let device_id = computer.get("deviceId").and_then(serde_json::Value::as_str);
        let name = computer
            .get("deviceName")
            .and_then(serde_json::Value::as_str);
        let (Some(device_id), Some(computer_name)) = (device_id, name) else {
            continue;
        };
        for project in computer
            .get("projects")
            .and_then(serde_json::Value::as_array)
            .into_iter()
            .flatten()
        {
            let Some(path) = project.get("path").and_then(serde_json::Value::as_str) else {
                continue;
            };
            projects.push(RemoteProject {
                device_id: device_id.to_string(),
                computer: computer_name.to_string(),
                name: project
                    .get("name")
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or(path)
                    .to_string(),
                path: path.to_string(),
            });
        }
    }
    projects
}

/// The project `/remote new <which>` names: its number in the list, or a unique (case-insensitive) name prefix, also as
/// `name@computer`.
fn pick_project<'a>(
    projects: &'a [RemoteProject],
    which: &str,
) -> Result<&'a RemoteProject, String> {
    if let Ok(number) = which.parse::<usize>() {
        return number
            .checked_sub(1)
            .and_then(|index| projects.get(index))
            .ok_or_else(|| {
                tlf(
                    "There is no project {number}. Use /remote new to list them.",
                    &[("number", &which)],
                )
            });
    }
    let wanted = which.to_lowercase();
    let (name, computer) = match wanted.split_once('@') {
        Some((name, computer)) => (name.to_string(), Some(computer.to_string())),
        None => (wanted.clone(), None),
    };
    let matches = |exact: bool| -> Vec<&RemoteProject> {
        projects
            .iter()
            .filter(|p| {
                let project = p.name.to_lowercase();
                let named = if exact {
                    project == name
                } else {
                    project.starts_with(&name)
                };
                named
                    && computer
                        .as_ref()
                        .is_none_or(|c| p.computer.to_lowercase().starts_with(c.as_str()))
            })
            .collect()
    };
    let exact = matches(true);
    let found = if exact.is_empty() {
        matches(false)
    } else {
        exact
    };
    match found.as_slice() {
        [one] => Ok(one),
        [] => Err(tlf(
            "No project matches “{query}”. Use /remote new to list them.",
            &[("query", &which)],
        )),
        _ => Err(tlf(
            "“{query}” matches more than one project: use its number.",
            &[("query", &which)],
        )),
    }
}

async fn ext_call(
    tx: &xai_acp_lib::AcpAgentTx,
    method: &str,
    params: serde_json::Value,
) -> Result<serde_json::Value, String> {
    let raw = serde_json::value::to_raw_value(&params).map_err(|error| error.to_string())?;
    let response = xai_acp_lib::acp_send(
        agent_client_protocol::ExtRequest::new(method, raw.into()),
        tx,
    )
    .await
    .map_err(|error| error.message.to_string())?;
    serde_json::from_str(response.0.get()).map_err(|error| error.to_string())
}

/// `/remote new [project] [prompt]`: without a project, lists the projects of the person's other computers that are
/// online; with one, starts a session there (with the prompt, if any) and opens it here.
pub async fn new_session(
    agent_id: AgentId,
    args: String,
    tx: xai_acp_lib::AcpAgentTx,
) -> TaskResult {
    let notice = |text: String| TaskResult::RemoteNotice {
        agent_id,
        text,
        toast: None,
    };
    let payload = match ext_call(&tx, "x.ai/remote/sessions", serde_json::json!({})).await {
        Ok(payload) => payload,
        Err(error) => return notice(error),
    };
    if payload.get("signedIn").and_then(serde_json::Value::as_bool) != Some(true) {
        return notice(
            tl("Sign in with /remote login first: your other computers' sessions come through the relay.").to_string(),
        );
    }
    let projects = remote_projects(&payload);
    if projects.is_empty() {
        return notice(tl("None of your other computers is online with crok running.").to_string());
    }
    let mut words = args.splitn(2, char::is_whitespace);
    let which = words.next().unwrap_or("").trim();
    let prompt = words.next().unwrap_or("").trim();
    if which.is_empty() {
        let mut lines = vec![tl("Projects on your other computers:").to_string()];
        for (index, project) in projects.iter().enumerate() {
            lines.push(format!(
                "  {}. {} · {}  {}",
                index + 1,
                project.name,
                project.computer,
                project.path
            ));
        }
        lines.push(
            tl("Use /remote new <number or name> [prompt] to start a session there.").to_string(),
        );
        return notice(lines.join("\n"));
    }
    let project = match pick_project(&projects, which) {
        Ok(project) => project.clone(),
        Err(error) => return notice(error),
    };
    let mut params = serde_json::json!({ "deviceId": project.device_id, "path": project.path });
    if !prompt.is_empty()
        && let Some(object) = params.as_object_mut()
    {
        object.insert("text".into(), serde_json::json!(prompt));
    }
    match ext_call(&tx, "x.ai/remote/new_session", params).await {
        Ok(created) => match created.get("sessionId").and_then(serde_json::Value::as_str) {
            Some(session_id) => TaskResult::RemoteSessionCreated {
                agent_id,
                session_id: session_id.to_string(),
                text: tlf(
                    "Started a session in {project} on {computer}.",
                    &[("project", &project.name), ("computer", &project.computer)],
                ),
            },
            None => notice(tl("The relay did not start the session.").to_string()),
        },
        Err(error) => notice(tlf(
            "Could not start the session: {error}",
            &[("error", &error)],
        )),
    }
}

#[cfg(test)]
mod new_session_tests {
    use super::*;

    fn projects() -> Vec<RemoteProject> {
        remote_projects(&serde_json::json!({
            "signedIn": true,
            "computers": [
                { "deviceId": "d1", "deviceName": "Office PC", "online": true, "projects": [
                    { "name": "webapp", "path": "/w/webapp" },
                    { "name": "web-docs", "path": "/w/web-docs" },
                ]},
                { "deviceId": "d2", "deviceName": "Old Laptop", "online": false, "projects": [
                    { "name": "webapp", "path": "/old/webapp" },
                ]},
                { "deviceId": "d3", "deviceName": "Mac mini", "online": true, "projects": [
                    { "name": "webapp", "path": "/m/webapp" },
                ]},
            ],
        }))
    }

    #[test]
    fn only_online_computers_are_offered() {
        let list = projects();
        assert_eq!(list.len(), 3);
        assert!(list.iter().all(|p| p.computer != "Old Laptop"));
    }

    #[test]
    fn projects_are_picked_by_number_name_or_name_at_computer() {
        let list = projects();
        assert_eq!(
            pick_project(&list, "2").map(|p| p.path.as_str()),
            Ok("/w/web-docs")
        );
        assert!(pick_project(&list, "9").is_err());
        assert_eq!(
            pick_project(&list, "web-d").map(|p| p.path.as_str()),
            Ok("/w/web-docs")
        );
        // Two computers have a "webapp": ambiguous until the computer is named.
        assert!(pick_project(&list, "webapp").is_err());
        assert_eq!(
            pick_project(&list, "webapp@mac").map(|p| p.path.as_str()),
            Ok("/m/webapp")
        );
        assert!(pick_project(&list, "billing").is_err());
    }
}
