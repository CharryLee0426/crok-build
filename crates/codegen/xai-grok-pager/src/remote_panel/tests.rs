//! The Remote panel as pure state: the tree, its filter, its keys, and the model and thinking-level steps.

use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use serde_json::{Value, json};

use super::tree::{self, Folds, RowKey, RowKind};
use super::tui::{Account, Applied};
use super::{RETRY, REWATCH, RemotePanel, Request, Response};
use crate::remote_panel::Outcome;

fn list() -> Value {
    json!({
        "signedIn": true,
        "computers": [
            { "deviceId": "d1", "deviceName": "Office PC", "online": true, "projects": [
                { "key": "d1:/w/webapp", "name": "webapp", "path": "/w/webapp", "sessions": [
                    { "sessionId": "relay:a", "title": "Fix the login redirect", "cwd": "/w/webapp",
                      "status": "running", "lastActivityAt": 1.0, "unread": 2 },
                    { "sessionId": "relay:b", "title": "Add billing tests", "cwd": "/w/webapp",
                      "status": "waiting", "lastActivityAt": 2.0, "unread": 0 },
                ]},
                { "key": "d1:/w/docs", "name": "docs", "path": "/w/docs", "sessions": [] },
            ]},
            { "deviceId": "d2", "deviceName": "Old Laptop", "online": false, "projects": [
                { "key": "d2:/old/api", "name": "api", "path": "/old/api", "sessions": [
                    { "sessionId": "relay:c", "title": "Upgrade tokio", "cwd": "/old/api", "status": "idle",
                      "lastActivityAt": 5000.0, "unread": 1 },
                ]},
            ]},
        ],
    })
}

/// Grok Code Fast has thinking levels, Grok 3 Mini none; a long list stands in for a computer with OpenRouter.
fn models(extra: usize) -> Value {
    let mut available = vec![
        json!({ "modelId": "grok-code-fast-1", "name": "Grok Code Fast", "description": "Fast and cheap",
        "_meta": { "supportsReasoningEffort": true, "reasoningEfforts": [
            { "id": "low", "value": "low", "label": "Low", "default": false },
            { "id": "high", "value": "high", "label": "High", "default": true },
        ]}}),
        json!({ "modelId": "grok-3-mini", "name": "Grok 3 Mini",
                "_meta": { "supportsReasoningEffort": false, "reasoningEfforts": [] }}),
    ];
    available.extend((0..extra).map(|i| {
        json!({ "modelId": format!("openrouter/m-{i}"), "name": format!("Router model {i}"),
                "_meta": { "reasoningEfforts": [] }})
    }));
    json!({ "deviceId": "d1", "models": [], "availableModels": available })
}

fn key(code: KeyCode) -> KeyEvent {
    KeyEvent::new(code, KeyModifiers::NONE)
}

fn press(panel: &mut RemotePanel, code: KeyCode) -> Outcome {
    panel.key(&key(code))
}

fn type_text(panel: &mut RemotePanel, text: &str) {
    for c in text.chars() {
        panel.key(&key(KeyCode::Char(c)));
    }
}

fn account() -> Account {
    Account {
        account: "Two Desk Tester".into(),
        computer: "This Mac".into(),
        enabled: true,
    }
}

/// A panel with the list loaded.
fn panel(at_projects: bool) -> RemotePanel {
    let (mut panel, request) = RemotePanel::open(account(), at_projects);
    assert_eq!(
        request,
        Request::Sessions {
            generation: panel.generation()
        }
    );
    let generation = panel.generation();
    let applied = panel.apply(Response::Sessions {
        generation,
        result: Ok(list()),
    });
    // The watch is renewed before the agent lets it lapse, if the panel is still open then.
    assert_eq!(
        applied,
        Applied::Request(Request::Wait {
            generation,
            delay: REWATCH
        })
    );
    assert_eq!(
        panel.apply(Response::Due { generation }),
        Applied::Request(Request::Sessions { generation })
    );
    panel
}

fn session(id: &str) -> RowKey {
    RowKey::Session(id.into())
}

fn project(device: &str, path: &str) -> RowKey {
    RowKey::Project {
        device_id: device.into(),
        path: path.into(),
    }
}

fn computer(device: &str) -> RowKey {
    RowKey::Computer(device.into())
}

#[test]
fn the_list_parses_with_unread_totals_status_and_last_seen() {
    let (signed_in, computers) = tree::parse_sessions(&list());
    assert!(signed_in);
    assert_eq!(computers.len(), 2);
    let office = &computers[0];
    assert_eq!(office.unread(), 2);
    assert_eq!(office.projects[0].sessions.len(), 2);
    assert_eq!(
        office.projects[0].sessions[0].activity(),
        Some(tree::Activity::Working)
    );
    assert_eq!(
        office.projects[0].sessions[1].activity(),
        Some(tree::Activity::NeedsApproval)
    );
    // Without the relay's own `lastSeenAt`, an offline computer was last seen at its newest session.
    assert_eq!(computers[1].last_seen_ms, Some(5000.0));
    let starting = json!({ "computers": [{ "deviceId": "x", "projects": [{ "path": "/p", "sessions": [
        { "sessionId": "relay:s", "status": "idle", "starting": true }]}]}]});
    let (signed_in, computers) = tree::parse_sessions(&starting);
    assert!(!signed_in);
    assert_eq!(
        computers[0].projects[0].sessions[0].activity(),
        Some(tree::Activity::Starting)
    );
}

#[test]
fn online_computers_start_open_and_offline_ones_folded() {
    let panel = panel(false);
    assert_eq!(
        panel.rows_for_test(),
        vec![
            computer("d1"),
            project("d1", "/w/webapp"),
            session("relay:a"),
            session("relay:b"),
            project("d1", "/w/docs"),
            computer("d2"),
        ]
    );
    assert_eq!(panel.selected_key_for_test(), Some(computer("d1")));
}

#[test]
fn remote_new_opens_at_the_project_list() {
    let panel = panel(true);
    assert_eq!(
        panel.rows_for_test(),
        vec![
            computer("d1"),
            project("d1", "/w/webapp"),
            project("d1", "/w/docs"),
            computer("d2"),
        ]
    );
    assert_eq!(
        panel.selected_key_for_test(),
        Some(project("d1", "/w/webapp"))
    );
}

#[test]
fn arrows_move_fold_and_step_out() {
    let mut panel = panel(false);
    press(&mut panel, KeyCode::Down);
    assert_eq!(
        panel.selected_key_for_test(),
        Some(project("d1", "/w/webapp"))
    );
    // ← folds the open project, and keeps it selected.
    assert_eq!(press(&mut panel, KeyCode::Left), Outcome::Changed);
    assert!(!panel.rows_for_test().contains(&session("relay:a")));
    assert_eq!(
        panel.selected_key_for_test(),
        Some(project("d1", "/w/webapp"))
    );
    // → unfolds it, a second → steps into it.
    press(&mut panel, KeyCode::Right);
    assert!(panel.rows_for_test().contains(&session("relay:a")));
    press(&mut panel, KeyCode::Right);
    assert_eq!(panel.selected_key_for_test(), Some(session("relay:a")));
    // ← on a session goes to its project, then (folding it first) to the computer.
    press(&mut panel, KeyCode::Left);
    assert_eq!(
        panel.selected_key_for_test(),
        Some(project("d1", "/w/webapp"))
    );
    press(&mut panel, KeyCode::Left);
    press(&mut panel, KeyCode::Left);
    assert_eq!(panel.selected_key_for_test(), Some(computer("d1")));
    // Enter on a computer folds or unfolds it too; the offline one opens on request.
    for _ in 0..3 {
        press(&mut panel, KeyCode::Down);
    }
    assert_eq!(panel.selected_key_for_test(), Some(computer("d2")));
    press(&mut panel, KeyCode::Enter);
    assert!(panel.rows_for_test().contains(&project("d2", "/old/api")));
}

#[test]
fn enter_on_a_session_opens_it_by_its_relay_id() {
    let mut panel = panel(false);
    press(&mut panel, KeyCode::Down);
    press(&mut panel, KeyCode::Down);
    assert_eq!(
        press(&mut panel, KeyCode::Enter),
        Outcome::Open {
            session_id: "relay:a".into(),
            cwd: Some("/w/webapp".into())
        }
    );
}

#[test]
fn typing_filters_by_title_project_folder_or_computer_and_esc_clears_then_closes() {
    let mut panel = panel(false);
    type_text(&mut panel, "billing");
    assert_eq!(
        panel.rows_for_test(),
        vec![
            computer("d1"),
            project("d1", "/w/webapp"),
            session("relay:b")
        ]
    );
    // The cursor lands on the row that matched, and the arrows move on from there.
    assert_eq!(panel.selected_key_for_test(), Some(session("relay:b")));
    press(&mut panel, KeyCode::Up);
    assert_eq!(
        panel.selected_key_for_test(),
        Some(project("d1", "/w/webapp"))
    );
    press(&mut panel, KeyCode::Down);
    assert_eq!(panel.selected_key_for_test(), Some(session("relay:b")));
    assert_eq!(press(&mut panel, KeyCode::Esc), Outcome::Changed);
    // Cleared, the whole tree is back with the cursor where it was.
    assert_eq!(panel.rows_for_test().len(), 6);
    assert_eq!(panel.selected_key_for_test(), Some(session("relay:b")));
    assert_eq!(press(&mut panel, KeyCode::Esc), Outcome::Close);

    // A folded computer's sessions are found too, and so is a computer by name.
    let mut panel = self::panel(false);
    type_text(&mut panel, "tokio");
    assert_eq!(
        panel.rows_for_test(),
        vec![
            computer("d2"),
            project("d2", "/old/api"),
            session("relay:c")
        ]
    );
    let mut panel = self::panel(false);
    type_text(&mut panel, "old lap");
    assert_eq!(panel.rows_for_test().len(), 3);
    let mut panel = self::panel(false);
    type_text(&mut panel, "/w/docs");
    assert_eq!(
        panel.rows_for_test(),
        vec![computer("d1"), project("d1", "/w/docs")]
    );
}

#[test]
fn the_list_follows_changes_and_keeps_folds_and_the_cursor() {
    let mut panel = panel(false);
    press(&mut panel, KeyCode::Down);
    press(&mut panel, KeyCode::Left);
    press(&mut panel, KeyCode::Down);
    assert_eq!(
        panel.selected_key_for_test(),
        Some(project("d1", "/w/docs"))
    );
    let mut changed = list();
    changed["computers"][0]["projects"]
        .as_array_mut()
        .unwrap()
        .insert(
            0,
            json!({ "key": "d1:/w/new", "name": "new", "path": "/w/new", "sessions": [
                { "sessionId": "relay:n", "title": "Brand new", "status": "idle" }]}),
        );
    assert!(panel.list_changed(&changed));
    assert!(
        !panel.list_changed(&changed),
        "the same list changes nothing"
    );
    assert_eq!(
        panel.rows_for_test(),
        vec![
            computer("d1"),
            project("d1", "/w/new"),
            session("relay:n"),
            project("d1", "/w/webapp"),
            project("d1", "/w/docs"),
            computer("d2"),
        ]
    );
    assert_eq!(
        panel.selected_key_for_test(),
        Some(project("d1", "/w/docs"))
    );
}

#[test]
fn not_connected_yet_asks_again_soon_and_a_failure_shows() {
    let (mut panel, _) = RemotePanel::open(account(), false);
    let generation = panel.generation();
    let applied = panel.apply(Response::Sessions {
        generation,
        result: Ok(json!({ "signedIn": false, "computers": [] })),
    });
    assert_eq!(
        applied,
        Applied::Request(Request::Wait {
            generation,
            delay: RETRY
        })
    );
    // An answer for an earlier panel is dropped.
    assert_eq!(
        panel.apply(Response::Sessions {
            generation: generation.wrapping_sub(1),
            result: Ok(list()),
        }),
        Applied::Nothing
    );
    assert!(panel.rows_for_test().is_empty());
    let applied = panel.apply(Response::Sessions {
        generation,
        result: Err("Sessions on other computers need remote control".into()),
    });
    assert!(matches!(applied, Applied::Request(Request::Wait { .. })));
    // A wait that ends after the panel closed asks for nothing: that panel's answers are dropped.
    assert_eq!(
        panel.apply(Response::Due {
            generation: generation.wrapping_sub(1)
        }),
        Applied::Nothing
    );
}

#[test]
fn n_on_an_offline_computer_says_so_and_starts_nothing() {
    let mut panel = panel(false);
    // The offline computer, unfolded, then its project.
    for _ in 0..5 {
        press(&mut panel, KeyCode::Down);
    }
    press(&mut panel, KeyCode::Right);
    press(&mut panel, KeyCode::Down);
    assert_eq!(
        panel.selected_key_for_test(),
        Some(project("d2", "/old/api"))
    );
    assert_eq!(press(&mut panel, KeyCode::Char('n')), Outcome::Changed);
    assert!(
        panel
            .notice_for_test()
            .is_some_and(|n| n.contains("Old Laptop"))
    );
    assert_eq!(panel.step_for_test(), "tree");
    // On a computer row there is no project to start in.
    press(&mut panel, KeyCode::Up);
    press(&mut panel, KeyCode::Char('n'));
    assert!(panel.notice_for_test().is_some());
    assert_eq!(panel.step_for_test(), "tree");
}

/// `n` on a session of webapp: the models of its computer, then the thinking level.
fn at_model_step(extra_models: usize) -> RemotePanel {
    let mut panel = panel(false);
    press(&mut panel, KeyCode::Down);
    press(&mut panel, KeyCode::Down);
    let generation = panel.generation();
    assert_eq!(
        press(&mut panel, KeyCode::Char('n')),
        Outcome::Request(Request::Models {
            generation,
            device_id: "d1".into()
        })
    );
    assert_eq!(panel.step_for_test(), "model");
    assert_eq!(
        panel.apply(Response::Models {
            generation,
            device_id: "d1".into(),
            result: Ok(models(extra_models)),
        }),
        Applied::Nothing
    );
    panel
}

#[test]
fn a_new_session_picks_a_model_then_a_thinking_level() {
    let mut panel = at_model_step(0);
    assert_eq!(
        panel.choices_for_test(),
        vec!["Default", "grok-code-fast-1", "grok-3-mini"]
    );
    press(&mut panel, KeyCode::Down);
    press(&mut panel, KeyCode::Enter);
    assert_eq!(panel.step_for_test(), "thinking");
    assert_eq!(panel.choices_for_test(), vec!["Default", "low", "high"]);
    press(&mut panel, KeyCode::Down);
    press(&mut panel, KeyCode::Down);
    let generation = panel.generation();
    assert_eq!(
        press(&mut panel, KeyCode::Enter),
        Outcome::Request(Request::Create {
            generation,
            device_id: "d1".into(),
            path: "/w/webapp".into(),
            model: Some("grok-code-fast-1".into()),
            effort: Some("high".into()),
        })
    );
    assert_eq!(panel.step_for_test(), "creating");
    let Applied::Open {
        session_id,
        cwd,
        toast,
    } = panel.apply(Response::Created {
        generation,
        result: Ok("relay:new".into()),
    })
    else {
        panic!("the new session opens");
    };
    assert_eq!(session_id, "relay:new");
    assert_eq!(cwd.as_deref(), Some("/w/webapp"));
    // Whatever the interface language, the toast names the project and the computer.
    assert!(
        toast.contains("webapp") && toast.contains("Office PC"),
        "{toast}"
    );
    assert_eq!(panel.step_for_test(), "tree");
}

#[test]
fn default_and_a_model_without_levels_start_at_once() {
    let mut panel = at_model_step(0);
    let generation = panel.generation();
    assert_eq!(
        press(&mut panel, KeyCode::Enter),
        Outcome::Request(Request::Create {
            generation,
            device_id: "d1".into(),
            path: "/w/webapp".into(),
            model: None,
            effort: None,
        })
    );
    let mut panel = at_model_step(0);
    type_text(&mut panel, "mini");
    assert_eq!(panel.choices_for_test(), vec!["grok-3-mini"]);
    let generation = panel.generation();
    assert_eq!(
        press(&mut panel, KeyCode::Enter),
        Outcome::Request(Request::Create {
            generation,
            device_id: "d1".into(),
            path: "/w/webapp".into(),
            model: Some("grok-3-mini".into()),
            effort: None,
        })
    );
    // "Default" thinking keeps the model and leaves the level to it.
    let mut panel = at_model_step(0);
    press(&mut panel, KeyCode::Down);
    press(&mut panel, KeyCode::Enter);
    let generation = panel.generation();
    assert_eq!(
        press(&mut panel, KeyCode::Enter),
        Outcome::Request(Request::Create {
            generation,
            device_id: "d1".into(),
            path: "/w/webapp".into(),
            model: Some("grok-code-fast-1".into()),
            effort: None,
        })
    );
}

#[test]
fn a_long_model_list_filters_by_typing() {
    let mut panel = at_model_step(500);
    assert_eq!(panel.choices_for_test().len(), 503);
    // j and k type here: the list is type-to-find.
    type_text(&mut panel, "m-49");
    assert_eq!(
        panel.choices_for_test(),
        (0..500)
            .map(|i| format!("openrouter/m-{i}"))
            .filter(|id| id.contains("m-49"))
            .collect::<Vec<_>>()
    );
    type_text(&mut panel, "9");
    assert_eq!(panel.choices_for_test(), vec!["openrouter/m-499"]);
    let generation = panel.generation();
    assert_eq!(
        press(&mut panel, KeyCode::Enter),
        Outcome::Request(Request::Create {
            generation,
            device_id: "d1".into(),
            path: "/w/webapp".into(),
            model: Some("openrouter/m-499".into()),
            effort: None,
        })
    );
}

#[test]
fn esc_clears_the_filter_then_steps_back_then_closes() {
    let mut panel = at_model_step(0);
    press(&mut panel, KeyCode::Down);
    press(&mut panel, KeyCode::Enter);
    assert_eq!(panel.step_for_test(), "thinking");
    type_text(&mut panel, "lo");
    assert_eq!(panel.choices_for_test(), vec!["low"]);
    press(&mut panel, KeyCode::Esc);
    assert_eq!(panel.choices_for_test(), vec!["Default", "low", "high"]);
    press(&mut panel, KeyCode::Esc);
    assert_eq!(panel.step_for_test(), "model");
    type_text(&mut panel, "grok");
    press(&mut panel, KeyCode::Esc);
    assert_eq!(panel.step_for_test(), "model");
    assert_eq!(panel.choices_for_test().len(), 3);
    press(&mut panel, KeyCode::Esc);
    assert_eq!(panel.step_for_test(), "tree");
    assert_eq!(panel.selected_key_for_test(), Some(session("relay:a")));
    assert_eq!(press(&mut panel, KeyCode::Esc), Outcome::Close);
}

#[test]
fn a_failed_start_goes_back_to_the_step_it_came_from() {
    let mut panel = at_model_step(0);
    press(&mut panel, KeyCode::Down);
    press(&mut panel, KeyCode::Enter);
    press(&mut panel, KeyCode::Enter);
    assert_eq!(panel.step_for_test(), "creating");
    let generation = panel.generation();
    assert_eq!(
        panel.apply(Response::Created {
            generation,
            result: Err("Office PC is offline: start crok or Crok Desktop there.".into()),
        }),
        Applied::Nothing
    );
    assert_eq!(panel.step_for_test(), "thinking");
}

#[test]
fn models_of_an_older_relay_shape_and_an_unreadable_list() {
    let relay_shape = json!({ "models": [
        { "id": "grok-4", "name": "Grok 4", "defaultEffort": "deep", "efforts": [
            { "id": "balanced", "name": "Balanced", "value": "medium" },
            { "id": "deep", "name": "Deep", "value": "xhigh" }]},
    ]});
    let models = tree::parse_models(&relay_shape);
    assert_eq!(models.len(), 1);
    assert!(models[0].efforts[1].default);
    assert!(tree::parse_models(&json!({ "models": null, "availableModels": [] })).is_empty());

    let mut panel = panel(false);
    press(&mut panel, KeyCode::Down);
    let generation = panel.generation();
    press(&mut panel, KeyCode::Char('n'));
    panel.apply(Response::Models {
        generation,
        device_id: "d1".into(),
        result: Err("The other computer did not answer in time.".into()),
    });
    // Its own default is still there to start with.
    assert_eq!(panel.choices_for_test(), vec!["Default"]);
}

#[test]
fn folds_are_kept_by_key() {
    let (_, computers) = tree::parse_sessions(&list());
    let mut folds = Folds::new(false);
    let rows = tree::build_rows(&computers, &folds, "");
    assert_eq!(rows.len(), 6);
    folds.set(RowKind::Computer { c: 0 }, &computers, false);
    assert_eq!(tree::build_rows(&computers, &folds, "").len(), 2);
    // The same computer later in the list keeps its fold.
    let swapped: Vec<_> = computers.iter().rev().cloned().collect();
    assert_eq!(tree::build_rows(&swapped, &folds, "").len(), 2);
}

fn rendered(panel: &mut RemotePanel, width: u16, height: u16) -> String {
    let area = ratatui::layout::Rect::new(0, 0, width, height);
    let mut buf = ratatui::buffer::Buffer::empty(area);
    panel.render(area, &mut buf, &crate::theme::Theme::default(), false);
    buf.content()
        .chunks(width as usize)
        .map(|row| {
            let line: String = row.iter().map(|cell| cell.symbol()).collect();
            line.trim_end().to_owned()
        })
        .collect::<Vec<_>>()
        .join("\n")
}

/// Names and titles only: the rest of the text follows the interface language.
#[test]
fn the_panel_draws_the_tree_and_the_new_session_steps() {
    let mut panel = panel(false);
    let text = rendered(&mut panel, 120, 30);
    eprintln!("{text}");
    for expected in [
        "Office PC",
        "webapp",
        "/w/webapp",
        "Fix the login redirect",
        "Add billing tests",
        "docs",
        "Old Laptop",
        "This Mac",
        "Two Desk Tester",
    ] {
        assert!(text.contains(expected), "{expected} missing:\n{text}");
    }
    // A small terminal still draws the rows it has room for.
    let small = rendered(&mut panel, 64, 16);
    eprintln!("{small}");
    assert!(small.contains("Office PC"), "{small}");

    let mut panel = at_model_step(500);
    let text = rendered(&mut panel, 120, 30);
    eprintln!("{text}");
    assert!(
        text.contains("Grok Code Fast")
            && text.contains("Fast and cheap")
            && text.contains("Office PC"),
        "{text}"
    );
    press(&mut panel, KeyCode::Down);
    press(&mut panel, KeyCode::Enter);
    let text = rendered(&mut panel, 120, 30);
    eprintln!("{text}");
    assert!(
        text.contains("Grok Code Fast") && text.contains("High"),
        "{text}"
    );
}
