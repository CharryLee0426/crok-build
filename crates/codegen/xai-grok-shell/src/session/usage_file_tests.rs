use super::*;
use xai_chat_state::UsageLedger;
use xai_grok_sampling_types::TokenUsage;

fn tu(prompt: u32, completion: u32) -> TokenUsage {
    TokenUsage {
        prompt_tokens: prompt,
        completion_tokens: completion,
        total_tokens: prompt + completion,
        reasoning_tokens: 0,
        cached_prompt_tokens: 0,
        cache_creation_prompt_tokens: 0,
    }
}

fn live(calls: &[(&str, u32, u32, Option<i64>)]) -> UsageSummary {
    let mut ledger = UsageLedger::default();
    for (model, prompt, completion, cost) in calls {
        ledger.record_main_loop_call(model, &tu(*prompt, *completion), Some(10), *cost);
    }
    UsageSummary::from_ledger(&ledger)
}

#[test]
fn first_turn_writes_session_and_one_turn() {
    let mut file = SessionUsageFile::new("sess-1");
    let first = live(&[("grok-4", 100, 20, Some(50))]);
    file.apply_turn(1, "2026-08-26T00:00:00Z", &first, None);

    let [t0] = file.turns.as_slice() else {
        panic!("expected one turn: {:?}", file.turns);
    };
    assert_eq!(t0.turn_number, 1);
    assert_eq!(t0.usage.input_tokens, 100);
    assert_eq!(t0.usage.output_tokens, 20);
    assert_eq!(t0.usage.cost_usd_ticks, Some(50));
    assert_eq!(file.session.input_tokens, 100);
    assert_eq!(file.session.output_tokens, 20);
    assert_eq!(file.session.turn_count, 1);
    assert_eq!(file.session.cost_usd_ticks, Some(50));
    assert_eq!(file.session.primary_model_id.as_deref(), Some("grok-4"));
    assert_eq!(file.updated_at, "2026-08-26T00:00:00Z");
}

#[test]
fn session_primary_model_is_the_most_used_not_the_last_turn() {
    let mut file = SessionUsageFile::new("sess-1");
    let first = live(&[("grok-4", 100, 20, Some(50)), ("grok-4", 80, 10, Some(40))]);
    file.apply_turn(1, "t1", &first, None);
    file.apply_turn(
        2,
        "t2",
        &live(&[
            ("grok-4", 100, 20, Some(50)),
            ("grok-4", 80, 10, Some(40)),
            ("grok-fast", 10, 2, Some(1)),
        ]),
        Some(&first),
    );

    assert_eq!(
        file.turns
            .get(1)
            .and_then(|t| t.usage.primary_model_id.as_deref()),
        Some("grok-fast")
    );
    assert_eq!(file.session.primary_model_id.as_deref(), Some("grok-4"));
}

#[test]
fn second_turn_appends_and_session_becomes_latest_ledger() {
    let mut file = SessionUsageFile::new("sess-1");
    let first = live(&[("grok-4", 100, 20, Some(50))]);
    file.apply_turn(1, "t1", &first, None);
    file.apply_turn(
        2,
        "t2",
        &live(&[("grok-4", 100, 20, Some(50)), ("grok-4", 40, 10, Some(20))]),
        Some(&first),
    );

    let [_, t1] = file.turns.as_slice() else {
        panic!("expected two turns: {:?}", file.turns);
    };
    assert_eq!(t1.turn_number, 2);
    assert_eq!(t1.usage.input_tokens, 40);
    assert_eq!(t1.usage.output_tokens, 10);
    assert_eq!(t1.usage.cost_usd_ticks, Some(20));
    assert_eq!(file.session.input_tokens, 140);
    assert_eq!(file.session.output_tokens, 30);
    assert_eq!(file.session.turn_count, 2);
    assert_eq!(file.session.cost_usd_ticks, Some(70));
}

#[test]
fn inherited_turn_number_without_fold_appends() {
    let mut file = SessionUsageFile::new("sess-1");
    let first = live(&[("grok-4", 100, 20, Some(50))]);
    file.apply_turn(1, "t1", &first, None);
    file.restore_apply_cursor(None, None);
    let resumed = live(&[("grok-4", 10, 2, Some(5))]);
    file.apply_turn(1, "t-resume", &resumed, None);

    let [t0, t1] = file.turns.as_slice() else {
        panic!("expected two turns: {:?}", file.turns);
    };
    assert_eq!(t0.turn_number, 1);
    assert_eq!(t0.usage.input_tokens, 100);
    assert_eq!(t1.turn_number, 2);
    assert_eq!(t1.usage.input_tokens, 10);
    assert_eq!(file.session.input_tokens, 110);
    assert_eq!(file.session.turn_count, 2);
}

#[test]
fn duplicate_turn_number_zero_delta_does_not_mutate_turns() {
    let mut file = SessionUsageFile::new("sess-1");
    let first = live(&[("grok-4", 100, 20, Some(50))]);
    file.apply_turn(1, "t1", &first, None);
    file.apply_turn(1, "t1-again", &first, Some(&first));

    let [t0] = file.turns.as_slice() else {
        panic!("expected one turn: {:?}", file.turns);
    };
    assert_eq!(t0.ended_at, "t1");
    assert_eq!(file.session.turn_count, 1);
    assert_eq!(file.updated_at, "t1-again");
}

#[test]
fn duplicate_turn_number_folds_extra_live_usage() {
    let mut file = SessionUsageFile::new("sess-1");
    let first = live(&[("grok-4", 100, 20, Some(50))]);
    file.apply_turn(1, "t1", &first, None);
    let continued = live(&[("grok-4", 100, 20, Some(50)), ("grok-4", 40, 10, Some(20))]);
    file.apply_turn(1, "t1-late", &continued, Some(&first));

    let [t0] = file.turns.as_slice() else {
        panic!("expected one turn: {:?}", file.turns);
    };
    assert_eq!(t0.ended_at, "t1-late");
    assert_eq!(t0.usage.input_tokens, 140);
    assert_eq!(t0.usage.output_tokens, 30);
    assert_eq!(t0.usage.cost_usd_ticks, Some(70));
    assert_eq!(file.session.input_tokens, 140);
    assert_eq!(file.session.output_tokens, 30);
    assert_eq!(file.session.turn_count, 1);
    assert_eq!(file.session.cost_usd_ticks, Some(70));
}

#[test]
fn resume_folds_new_process_ledger_onto_persisted_session() {
    let mut file = SessionUsageFile::new("sess-1");
    let first = live(&[("grok-4", 100, 20, Some(50))]);
    file.apply_turn(1, "t1", &first, None);
    file.apply_turn(
        2,
        "t2",
        &live(&[("grok-4", 100, 20, Some(50)), ("grok-4", 40, 10, Some(20))]),
        Some(&first),
    );

    let post_resume_1 = live(&[("grok-4", 25, 5, Some(8))]);
    file.apply_turn(3, "t3", &post_resume_1, None);

    let [_, _, t2] = file.turns.as_slice() else {
        panic!("expected three turns: {:?}", file.turns);
    };
    assert_eq!(t2.turn_number, 3);
    assert_eq!(t2.usage.input_tokens, 25);
    assert_eq!(t2.usage.output_tokens, 5);
    assert_eq!(file.session.input_tokens, 165);
    assert_eq!(file.session.output_tokens, 35);
    assert_eq!(file.session.turn_count, 3);
    assert_eq!(file.session.cost_usd_ticks, Some(78));
}

#[test]
fn resume_later_turns_use_process_local_delta() {
    let mut file = SessionUsageFile::new("sess-1");
    let first = live(&[("grok-4", 100, 20, Some(50))]);
    file.apply_turn(1, "t1", &first, None);
    file.apply_turn(
        2,
        "t2",
        &live(&[("grok-4", 100, 20, Some(50)), ("grok-4", 40, 10, Some(20))]),
        Some(&first),
    );

    let post_resume_1 = live(&[("grok-4", 25, 5, Some(8))]);
    file.apply_turn(3, "t3", &post_resume_1, None);
    file.apply_turn(
        4,
        "t4",
        &live(&[("grok-4", 25, 5, Some(8)), ("grok-4", 30, 6, Some(9))]),
        Some(&post_resume_1),
    );

    let [_, _, _, t3] = file.turns.as_slice() else {
        panic!("expected four turns: {:?}", file.turns);
    };
    assert_eq!(t3.usage.input_tokens, 30);
    assert_eq!(t3.usage.output_tokens, 6);
    assert_eq!(file.session.input_tokens, 195);
    assert_eq!(file.session.output_tokens, 41);
    assert_eq!(file.session.turn_count, 4);
    assert_eq!(file.session.cost_usd_ticks, Some(87));
}

#[test]
fn retain_turns_through_drops_later_turns_and_rebuilds_session() {
    let mut file = SessionUsageFile::new("sess-1");
    let first = live(&[("grok-4", 100, 20, Some(50))]);
    file.apply_turn(1, "t1", &first, None);
    file.apply_turn(
        2,
        "t2",
        &live(&[("grok-4", 100, 20, Some(50)), ("grok-4", 40, 10, Some(20))]),
        Some(&first),
    );
    file.retain_turns_through(1);

    let [t0] = file.turns.as_slice() else {
        panic!("expected one turn: {:?}", file.turns);
    };
    assert_eq!(t0.turn_number, 1);
    assert_eq!(file.session.input_tokens, 100);
    assert_eq!(file.session.turn_count, 1);
    assert_eq!(file.session.cost_usd_ticks, Some(50));
}

#[test]
fn turn_lookup_returns_matching_row() {
    let mut file = SessionUsageFile::new("sess-1");
    let first = live(&[("grok-4", 100, 20, Some(50))]);
    file.apply_turn(1, "t1", &first, None);
    file.apply_turn(
        2,
        "t2",
        &live(&[("grok-4", 100, 20, Some(50)), ("grok-4", 40, 10, Some(20))]),
        Some(&first),
    );

    assert_eq!(file.turn(2).unwrap().usage.input_tokens, 40);
    assert!(file.turn(3).is_none());
}

#[test]
fn covers_detects_same_process_vs_reset_ledger() {
    let bigger = live(&[("m", 10, 1, None), ("m", 5, 1, None)]);
    let smaller = live(&[("m", 5, 1, None)]);
    assert!(bigger.covers(&smaller));
    assert!(!smaller.covers(&bigger));
    assert!(smaller.covers(&UsageSummary::default()));
}

/// The session's average speed and an estimated cost survive a resume: the file adds up every
/// process's turns, and a new process's ledger starts from zero.
#[test]
fn speed_and_estimated_cost_add_up_across_a_resume() {
    let timed = |completion: u32, ms: u64, estimate: i64| {
        let mut ledger = UsageLedger::default();
        ledger.record_main_loop_call_with(
            "claude-opus-5-5",
            &tu(1_000, completion),
            &xai_chat_state::CallMetrics {
                api_duration_ms: Some(ms + 400),
                decode_duration_ms: Some(ms),
                cost_usd_ticks: None,
                estimated_cost_usd_ticks: Some(estimate),
            },
        );
        UsageSummary::from_ledger(&ledger)
    };
    let mut file = SessionUsageFile::new("sess-1");
    file.apply_turn(1, "t1", &timed(600, 10_000, 70), None);
    // A resumed process: its first live ledger counts only its own calls.
    file.apply_turn(2, "t2", &timed(400, 15_000, 30), None);
    assert_eq!(file.session.decode_output_tokens, 1_000);
    assert_eq!(file.session.decode_duration_ms, 25_000);
    assert_eq!(file.session.api_duration_ms, 25_800);
    assert_eq!(file.session.output_tokens_per_second(), Some(40.0));
    assert_eq!(file.session.cost_usd_ticks, Some(100));
    assert!(file.session.cost_is_estimated);

    let json = serde_json::to_value(&file).unwrap();
    assert_eq!(json["session"]["decodeDurationMs"], 25_000);
    assert_eq!(json["session"]["decodeOutputTokens"], 1_000);
    assert_eq!(json["session"]["costIsEstimated"], true);
    let back: SessionUsageFile = serde_json::from_value(json).unwrap();
    assert_eq!(back.session.output_tokens_per_second(), Some(40.0));
    // A file written before speeds were kept reads as having none.
    let old: SessionUsageFile =
        serde_json::from_str(r#"{"session":{"outputTokens":5,"modelCalls":1}}"#).unwrap();
    assert_eq!(old.session.output_tokens_per_second(), None);
    assert!(!old.session.cost_is_estimated);
}
