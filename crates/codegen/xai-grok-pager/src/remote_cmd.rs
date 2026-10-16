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
