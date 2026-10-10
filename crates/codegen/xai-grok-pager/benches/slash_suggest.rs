//! Criterion benchmarks for the slash command menu with a large catalog.
//!
//! Every keystroke in a `/command` recomputes the suggestion rows on the UI thread, and every
//! frame lays the dropdown out again. These measure both with the catalog of a heavy plugin
//! setup: a few thousand skills beside the builtins.

use std::hint::black_box;

use criterion::{Criterion, criterion_group, criterion_main};
use ratatui::buffer::Buffer;
use ratatui::layout::Rect;

use xai_grok_pager::acp::model_state::ModelState;
use xai_grok_pager::slash::{SlashController, SlashState};
use xai_grok_pager::theme::Theme;
use xai_grok_pager::views::slash_dropdown::{desired_item_rows, render_dropdown};

const SKILLS: usize = 2000;

fn controller() -> SlashController {
    let mut ctrl = SlashController::with_builtins(std::path::PathBuf::from("."));
    let skills: Vec<_> = (0..SKILLS)
        .map(|i| {
            let meta = serde_json::json!({
                "scope": "plugin",
                "pluginName": format!("plugin{}", i % 40),
                "path": format!("/plugins/plugin{}/skills/skill-{i:04}/SKILL.md", i % 40),
            })
            .as_object()
            .cloned()
            .expect("skill meta is an object");
            agent_client_protocol::AvailableCommand::new(
                format!("plugin{}:skill-{i:04}", i % 40),
                format!(
                    "Skill number {i} does a thing that needs a description long enough to wrap"
                ),
            )
            .meta(meta)
        })
        .collect();
    ctrl.registry_mut().set_acp_commands(&skills);
    ctrl
}

fn bench_suggestions(c: &mut Criterion) {
    let mut ctrl = controller();
    let models = ModelState::default();
    let state = SlashState::default();
    let mut group = c.benchmark_group("slash_suggest");
    for (name, text) in [
        ("bare_menu", "/"),
        ("one_char", "/s"),
        ("prefix", "/skill-1"),
        ("deep", "/plugin7:skill-07"),
    ] {
        group.bench_function(name, |b| {
            b.iter(|| {
                ctrl.refresh(&state, black_box(text), text.len(), &models);
                black_box(state.snapshot().matches.len())
            })
        });
    }
    group.finish();
}

fn bench_render(c: &mut Criterion) {
    let mut ctrl = controller();
    let models = ModelState::default();
    let state = SlashState::default();
    ctrl.refresh(&state, "/", 1, &models);
    let snap = state.snapshot();
    let theme = Theme::current();
    let area = Rect::new(0, 0, 100, 8);
    let mut buf = Buffer::empty(area);
    c.bench_function("slash_dropdown_frame", |b| {
        b.iter(|| {
            let rows = desired_item_rows(&snap.matches, area.width);
            let rendered = render_dropdown(&mut buf, area, &snap, None, &theme);
            black_box((rows, rendered.row_items.len()))
        })
    });
}

criterion_group!(benches, bench_suggestions, bench_render);
criterion_main!(benches);
