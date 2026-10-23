//! The Remote panel (`/remote`): opening it, the work it asks for, and opening the sessions it picks.

use super::queue::push_and_page_flip;
use super::router::dispatch;
use crate::app::actions::{Action, Effect};
use crate::app::agent::AgentId;
use crate::app::app_view::{ActiveView, AppView};
use crate::remote_panel::tui::{Account, Applied};
use crate::remote_panel::{RemotePanel, Request, Response};
use crate::scrollback::block::RenderBlock;
use crate::views::modal::ActiveModal;

/// Opens the panel over the active session and asks for the list. Signed out, it says how to sign in instead.
pub(super) fn dispatch_show_remote_panel(app: &mut AppView, at_projects: bool) -> Vec<Effect> {
    let ActiveView::Agent(agent_id) = app.active_view else {
        return vec![];
    };
    let Some(agent) = app.agents.get_mut(&agent_id) else {
        return vec![];
    };
    let Some(account) = Account::load() else {
        push_and_page_flip(
            &mut agent.scrollback,
            RenderBlock::system(crate::remote_cmd::status_text()),
        );
        return vec![];
    };
    let (panel, request) = RemotePanel::open(account, at_projects);
    agent.active_modal = Some(ActiveModal::Remote {
        state: Box::new(panel),
    });
    vec![Effect::RemotePanel { agent_id, request }]
}

/// Work the open panel asked for; nothing once it has closed.
pub(super) fn dispatch_remote_panel_request(app: &mut AppView, request: Request) -> Vec<Effect> {
    let ActiveView::Agent(agent_id) = app.active_view else {
        return vec![];
    };
    match app.agents.get(&agent_id).map(|agent| &agent.active_modal) {
        Some(Some(ActiveModal::Remote { .. })) => vec![Effect::RemotePanel { agent_id, request }],
        _ => vec![],
    }
}

/// Closes the panel and opens the session the way `/resume` opens another computer's row.
pub(super) fn dispatch_remote_open_session(
    app: &mut AppView,
    session_id: String,
    cwd: Option<String>,
) -> Vec<Effect> {
    if let ActiveView::Agent(agent_id) = app.active_view
        && let Some(agent) = app.agents.get_mut(&agent_id)
        && matches!(agent.active_modal, Some(ActiveModal::Remote { .. }))
    {
        agent.active_modal = None;
    }
    super::session::load::dispatch_daemon_session_pick(app, session_id, cwd.unwrap_or_default())
}

/// The agent's answer reaches the panel that asked, if it is still open.
pub(super) fn dispatch_remote_panel_response(
    app: &mut AppView,
    agent_id: AgentId,
    response: Response,
) -> Vec<Effect> {
    let applied = match app
        .agents
        .get_mut(&agent_id)
        .and_then(|agent| agent.active_modal.as_mut())
    {
        Some(ActiveModal::Remote { state }) => state.apply(response),
        _ => return vec![],
    };
    match applied {
        Applied::Nothing => vec![],
        Applied::Request(request) => vec![Effect::RemotePanel { agent_id, request }],
        Applied::Open {
            session_id,
            cwd,
            toast,
        } => {
            if let Some(agent) = app.agents.get_mut(&agent_id) {
                agent.active_modal = None;
            }
            // Said on the new session's view, which the open switches to (a toast stays with the view it was shown on).
            let effects = dispatch(Action::RemoteOpenSession { session_id, cwd }, app);
            app.show_toast(&toast);
            effects
        }
    }
}

/// `x.ai/remote/sessions_changed`: every open panel takes the new list. Returns whether the active view changed.
pub(in crate::app) fn remote_sessions_changed(
    app: &mut AppView,
    payload: &serde_json::Value,
) -> bool {
    let active = match app.active_view {
        ActiveView::Agent(agent_id) => Some(agent_id),
        _ => None,
    };
    let mut changed = false;
    for (agent_id, agent) in &mut app.agents {
        if let Some(ActiveModal::Remote { state }) = agent.active_modal.as_mut()
            && state.list_changed(payload)
            && active == Some(*agent_id)
        {
            changed = true;
        }
    }
    changed
}
