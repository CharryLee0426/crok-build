use std::sync::{Arc, Mutex, OnceLock};

use futures_util::StreamExt;
use futures_util::stream;
use serde_json::Value;
use xai_grok_sampling_types::{
    ApiBackend, ConversationItem, ConversationRequest, ConversationResponse, StopReason,
    TokenUsage, ToolCall, ToolSpec, rs,
};

use super::*;
use crate::config::SamplerConfig;
use crate::events::SamplingEvent;
use crate::metrics::InferenceLatencyStats;
use crate::types::RequestId;

/// The process-wide sink every test in this file records into; tests tell their calls apart by session id.
/// The second list holds the harness events (turns, tool runs, steps, scores, ratings, guard checks).
struct TestSink(Mutex<Vec<String>>, Mutex<Vec<String>>);

thread_local! {
    /// Switches the shared sink off for one test's thread only, so tests running beside it still record.
    static SWITCHED_OFF: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
}

impl GenerationSink for TestSink {
    fn record(&self, call: ObservedCall) {
        self.0.lock().unwrap().push(call.to_json_line());
    }

    fn record_event(&self, event: HarnessEvent) {
        self.1.lock().unwrap().push(event.to_json_line());
    }

    fn is_active(&self) -> bool {
        !SWITCHED_OFF.get()
    }
}

fn sink() -> &'static TestSink {
    static TEST_SINK: OnceLock<Arc<TestSink>> = OnceLock::new();
    TEST_SINK.get_or_init(|| {
        let sink = Arc::new(TestSink(Mutex::new(Vec::new()), Mutex::new(Vec::new())));
        install_sink(sink.clone(), "crok");
        sink
    })
}

fn records_for(conversation_id: &str) -> Vec<Value> {
    sink()
        .0
        .lock()
        .unwrap()
        .iter()
        .map(|line| serde_json::from_str::<Value>(line).unwrap())
        .filter(|record| record["start"]["conversationId"] == conversation_id)
        .collect()
}

fn events_for(conversation_id: &str) -> Vec<Value> {
    sink()
        .1
        .lock()
        .unwrap()
        .iter()
        .map(|line| serde_json::from_str::<Value>(line).unwrap())
        .filter(|event| event["conversationId"] == conversation_id)
        .collect()
}

fn events_of(conversation_id: &str, kind: &str) -> Vec<Value> {
    events_for(conversation_id)
        .into_iter()
        .filter(|event| event["type"] == kind)
        .collect()
}

fn anthropic_client() -> SamplingClient {
    SamplingClient::new(SamplerConfig {
        api_key: Some("test-key".to_owned()),
        base_url: "https://api.anthropic.com/v1".to_owned(),
        model: "claude-test".to_owned(),
        api_backend: ApiBackend::Messages,
        context_window: 200_000,
        ..Default::default()
    })
    .unwrap()
}

fn turn_request(session_id: &str) -> ConversationRequest {
    let read_file = ToolCall {
        id: "call_1".into(),
        name: "read_file".to_owned(),
        arguments: r#"{"path":"a.rs"}"#.into(),
    };
    ConversationRequest {
        items: vec![
            ConversationItem::system("You are crok."),
            ConversationItem::user("Why does the test fail?"),
            ConversationItem::assistant_tool_calls(vec![read_file]),
            ConversationItem::tool_result("call_1", "fn main() {}"),
        ],
        tools: vec![ToolSpec {
            name: "read_file".to_owned(),
            description: Some("Read a file".to_owned()),
            parameters: serde_json::json!({"type": "object"}),
        }],
        x_grok_conv_id: Some(session_id.to_owned()),
        x_grok_session_id: Some(session_id.to_owned()),
        x_grok_req_id: Some("prompt-1".to_owned()),
        x_grok_turn_idx: Some("3".to_owned()),
        reasoning_effort: Some(xai_grok_sampling_types::ReasoningEffort::High),
        ..Default::default()
    }
}

fn response(text: &str) -> ConversationResponse {
    let reasoning = rs::ReasoningItem {
        id: "rs_1".to_owned(),
        summary: Vec::new(),
        content: Some(vec![rs::ReasoningTextContent {
            text: "The fixture is missing.".to_owned(),
        }]),
        encrypted_content: None,
        status: None,
    };
    let mut assistant = ConversationItem::assistant_with_model(text, "claude-test-20261001");
    if let ConversationItem::Assistant(a) = &mut assistant {
        a.tool_calls.push(ToolCall {
            id: "call_2".into(),
            name: "edit_file".to_owned(),
            arguments: "{}".into(),
        });
    }
    ConversationResponse {
        items: vec![ConversationItem::Reasoning(reasoning), assistant],
        stop_reason: Some(StopReason::ToolCalls),
        usage: Some(TokenUsage {
            prompt_tokens: 1_200,
            completion_tokens: 80,
            total_tokens: 1_280,
            reasoning_tokens: 20,
            cached_prompt_tokens: 1_000,
            cache_creation_prompt_tokens: 150,
        }),
        cost_usd_ticks: None,
        message_chunks_emitted: 1,
        doom_loop_signals: Vec::new(),
        stop_message: None,
        message_id: Some("msg_123".to_owned()),
        raw_stop_reason: Some("tool_use".to_owned()),
        stop_sequence: None,
    }
}

async fn run_turn(client: &SamplingClient, request: &ConversationRequest, path: CallPath) {
    run_with(client, request, path, response("Found it.")).await;
}

async fn run_with(
    client: &SamplingClient,
    request: &ConversationRequest,
    path: CallPath,
    response: ConversationResponse,
) {
    let observation = Observation::start(client, request, path);
    assert!(observation.is_some(), "a sink is installed");
    let events = stream::iter(vec![
        SamplingEvent::FirstToken {
            request_id: RequestId::from("r"),
        },
        SamplingEvent::Completed {
            request_id: RequestId::from("r"),
            response: Box::new(response),
            metrics: InferenceLatencyStats::default(),
        },
    ]);
    let _: Vec<_> = watch(observation, events).collect().await;
}

fn client(base_url: &str, model: &str, api_backend: ApiBackend, one_hour: bool) -> SamplingClient {
    SamplingClient::new(SamplerConfig {
        api_key: Some("test-key".to_owned()),
        base_url: base_url.to_owned(),
        model: model.to_owned(),
        api_backend,
        context_window: 200_000,
        anthropic: one_hour.then(xai_grok_sampling_types::AnthropicOptions::default),
        ..Default::default()
    })
    .unwrap()
}

#[tokio::test]
async fn a_completed_turn_records_new_input_output_and_inclusive_usage() {
    sink();
    let client = anthropic_client();
    run_turn(&client, &turn_request("obs-turn"), CallPath::Turn).await;

    let records = records_for("obs-turn");
    assert_eq!(records.len(), 1, "{records:?}");
    let record = &records[0];
    let start = &record["start"];
    assert_eq!(record["type"], "generation");
    assert_eq!(start["mode"], "STREAM");
    assert_eq!(start["agentName"], "crok");
    assert_eq!(start["model"]["provider"], "anthropic");
    assert_eq!(start["model"]["name"], "claude-test");
    assert_eq!(start["systemPrompt"], "You are crok.");
    assert_eq!(start["thinkingEnabled"], true);
    assert_eq!(start["tools"][0]["name"], "read_file");
    assert_eq!(start["tools"][0]["inputSchemaJSON"], r#"{"type":"object"}"#);
    assert_eq!(start["tags"]["call_kind"], "turn");
    assert_eq!(start["tags"]["backend"], "messages");
    assert_eq!(start["metadata"]["crok.request_id"], "prompt-1");
    assert_eq!(start["metadata"]["crok.turn_index"], "3");
    assert_eq!(start["metadata"]["crok.reasoning_effort"], "high");
    assert!(start["id"].as_str().unwrap().starts_with("gen_"));
    assert!(record["firstTokenAtMs"].as_i64().unwrap() >= start["startedAtMs"].as_i64().unwrap());

    // Only what was added since the model last spoke: the tool result, named after its call.
    let result = &record["result"];
    let input = result["input"].as_array().unwrap();
    assert_eq!(input.len(), 1, "{input:?}");
    assert_eq!(input[0]["role"], "tool");
    assert_eq!(input[0]["parts"][0]["type"], "tool_result");
    assert_eq!(input[0]["parts"][0]["toolResult"]["toolCallId"], "call_1");
    assert_eq!(input[0]["parts"][0]["toolResult"]["name"], "read_file");
    assert_eq!(
        input[0]["parts"][0]["toolResult"]["content"],
        "fn main() {}"
    );

    let parts = result["output"][0]["parts"].as_array().unwrap();
    let kinds: Vec<&str> = parts.iter().map(|p| p["type"].as_str().unwrap()).collect();
    assert_eq!(kinds, ["thinking", "text", "tool_call"]);
    assert_eq!(parts[2]["toolCall"]["name"], "edit_file");
    assert_eq!(result["responseId"], "msg_123");
    assert_eq!(result["responseModel"], "claude-test-20261001");
    assert_eq!(result["stopReason"], "tool_use");
    assert_eq!(result["usage"]["inputTokens"], 1_200);
    assert_eq!(result["usage"]["cacheReadInputTokens"], 1_000);
    assert_eq!(result["usage"]["cacheWriteInputTokens"], 150);
    assert_eq!(result["usage"]["reasoningTokens"], 20);
    assert_eq!(result["usage"]["inputSemantics"], "inclusive");
    assert!(record.get("error").is_none());
    // `claude-test` has no standard price, so the span says nothing about cost.
    assert_eq!(
        record["spanAttributes"],
        serde_json::json!({"crok.backend": "messages"})
    );
}

#[tokio::test]
async fn a_priced_call_reports_its_standard_cost_at_the_cache_lifetime_it_wrote() {
    sink();
    // The response names `claude-test-20261001`, which no list prices, so the requested model is.
    let five_minutes = client(
        "https://api.anthropic.com/v1",
        "claude-sonnet-5-5",
        ApiBackend::Messages,
        false,
    );
    run_turn(&five_minutes, &turn_request("obs-cost-5m"), CallPath::Turn).await;
    let one_hour = client(
        "https://api.anthropic.com/v1",
        "claude-sonnet-5-5",
        ApiBackend::Messages,
        true,
    );
    run_turn(&one_hour, &turn_request("obs-cost-1h"), CallPath::Turn).await;

    // 50 uncached input at $2, 1,000 cache reads at $0.10, 150 writes at $2.50 (5 min) or $4 (1 h),
    // 80 output at $10, per million tokens.
    let span = |id| records_for(id)[0]["spanAttributes"].clone();
    assert_eq!(span("obs-cost-5m")["crok.cost.source"], "list_price");
    let usd = |id| span(id)["crok.cost.usd"].as_f64().unwrap();
    assert!(
        (usd("obs-cost-5m") - 0.001_375).abs() < 1e-12,
        "{}",
        usd("obs-cost-5m")
    );
    assert!(
        (usd("obs-cost-1h") - 0.001_6).abs() < 1e-12,
        "{}",
        usd("obs-cost-1h")
    );
}

#[tokio::test]
async fn a_provider_reported_cost_wins_over_the_list_price() {
    sink();
    let openrouter = client(
        "https://openrouter.ai/api/v1",
        "anthropic/claude-sonnet-5-5",
        ApiBackend::OpenRouter,
        false,
    );
    let mut billed = response("Found it.");
    billed.cost_usd_ticks = Some(123_400_000);
    run_with(
        &openrouter,
        &turn_request("obs-cost-billed"),
        CallPath::Turn,
        billed,
    )
    .await;

    let span = &records_for("obs-cost-billed")[0]["spanAttributes"];
    assert_eq!(span["crok.backend"], "openrouter");
    assert_eq!(span["crok.cost.source"], "provider");
    assert!((span["crok.cost.usd"].as_f64().unwrap() - 0.012_34).abs() < 1e-12);
    assert!(span.get("crok.cancelled").is_none());
}

#[tokio::test]
async fn a_codex_call_is_estimated_at_the_openai_price() {
    sink();
    let codex = client(
        "https://chatgpt.com/backend-api/codex",
        "gpt-5.3-codex",
        ApiBackend::OpenAiCodex,
        false,
    );
    run_turn(&codex, &turn_request("obs-cost-codex"), CallPath::Turn).await;

    let record = &records_for("obs-cost-codex")[0];
    assert_eq!(record["start"]["model"]["provider"], "openai");
    let span = &record["spanAttributes"];
    assert_eq!(span["crok.backend"], "openai_codex");
    // 50 at $1.75, 1,000 at $0.175, 150 at $1.75, 80 at $14 per million tokens.
    assert!((span["crok.cost.usd"].as_f64().unwrap() - 0.001_645).abs() < 1e-12);
}

#[tokio::test]
async fn a_first_prompt_sends_the_user_message_and_keeps_the_system_prompt_apart() {
    sink();
    let client = anthropic_client();
    let mut request = turn_request("obs-first");
    request.items.truncate(2);
    run_turn(&client, &request, CallPath::Turn).await;

    let records = records_for("obs-first");
    let input = records[0]["result"]["input"].as_array().unwrap();
    assert_eq!(input.len(), 1);
    assert_eq!(input[0]["role"], "user");
    assert_eq!(input[0]["parts"][0]["text"], "Why does the test fail?");
    assert_eq!(records[0]["start"]["systemPrompt"], "You are crok.");
}

#[tokio::test]
async fn a_send_error_keeps_the_status_and_a_dropped_stream_is_recorded_as_cancelled() {
    sink();
    let client = anthropic_client();
    let request = turn_request("obs-errors");
    let observation = Observation::start(&client, &request, CallPath::Turn);
    record_send_error(
        observation,
        &xai_grok_sampling_types::SamplingError::Api {
            status: reqwest::StatusCode::TOO_MANY_REQUESTS,
            message: "slow down".to_owned(),
            model_metadata: None,
            retry_after_secs: None,
            should_retry: None,
            error_code: None,
        },
    );
    let observation = Observation::start(&client, &request, CallPath::Turn);
    let events = watch(observation, stream::pending::<SamplingEvent>());
    drop(events);

    let records = records_for("obs-errors");
    assert_eq!(records.len(), 2);
    assert_eq!(records[0]["error"]["statusCode"], 429);
    assert!(
        records[0]["error"]["message"]
            .as_str()
            .unwrap()
            .contains("slow down")
    );
    assert_eq!(records[0]["result"]["input"].as_array().unwrap().len(), 1);
    assert!(
        records[1]["error"]["message"]
            .as_str()
            .unwrap()
            .starts_with("cancelled")
    );
    assert!(records[1]["result"].get("usage").is_none());
    // Only the cancelled one says so: a failure carries no flag.
    assert!(records[0]["spanAttributes"].get("crok.cancelled").is_none());
    assert_eq!(records[1]["spanAttributes"]["crok.cancelled"], true);
    assert!(records[1]["spanAttributes"].get("crok.cost.usd").is_none());
}

#[tokio::test]
async fn a_side_call_is_named_by_its_kind_and_filed_under_its_session() {
    sink();
    let client = anthropic_client();
    let mut request = turn_request("obs-side");
    request.x_grok_conv_id = Some(format!("recap-{}", uuid::Uuid::new_v4()));
    run_turn(&client, &request, CallPath::SideCall).await;

    let records = records_for("obs-side");
    assert_eq!(records[0]["start"]["agentName"], "crok/recap");
    assert_eq!(records[0]["start"]["tags"]["call_kind"], "recap");
    assert_eq!(
        records[0]["start"]["metadata"]["crok.call_path"],
        "side_call"
    );
}

#[tokio::test]
async fn a_sub_agent_links_its_first_turn_to_the_parent_turn_that_spawned_it() {
    sink();
    let client = anthropic_client();
    register_session("obs-parent", None, None);
    set_session_title("obs-parent", "Fix the flaky test");
    register_session("obs-child", Some("explore"), Some("obs-parent"));
    run_turn(&client, &turn_request("obs-parent"), CallPath::Turn).await;
    run_turn(&client, &turn_request("obs-child"), CallPath::Turn).await;
    run_turn(&client, &turn_request("obs-child"), CallPath::Turn).await;

    let parent = records_for("obs-parent");
    assert_eq!(
        parent[0]["start"]["conversationTitle"],
        "Fix the flaky test"
    );
    let parent_id = parent[0]["start"]["id"].clone();
    let child = records_for("obs-child");
    assert_eq!(child.len(), 2);
    assert_eq!(child[0]["start"]["agentName"], "crok/explore");
    assert_eq!(child[0]["start"]["tags"]["call_kind"], "subagent_turn");
    assert_eq!(
        child[0]["start"]["conversationTitle"],
        "explore sub-agent · Fix the flaky test"
    );
    assert_eq!(
        child[0]["start"]["parentGenerationIds"],
        serde_json::json!([parent_id])
    );
    assert!(child[1]["start"].get("parentGenerationIds").is_none());
    assert_eq!(
        child[0]["start"]["metadata"]["crok.parent_session_id"],
        "obs-parent"
    );
}

#[test]
fn a_switched_off_sink_gets_no_calls_but_sessions_are_still_registered() {
    sink();
    let client = anthropic_client();
    let request = turn_request("obs-switched-off");
    SWITCHED_OFF.set(true);
    register_session("obs-switched-off", None, None);
    set_session_title("obs-switched-off", "Kept for later");
    let observation = Observation::start(&client, &request, CallPath::Turn);
    SWITCHED_OFF.set(false);
    assert!(observation.is_none(), "nothing is snapshotted while off");
    assert!(records_for("obs-switched-off").is_empty());

    // Switched back on, the next call carries the title registered while it was off
    let observation = Observation::start(&client, &request, CallPath::Turn);
    assert_eq!(
        observation.map(|o| o.call.conversation_title),
        Some(Some("Kept for later".to_owned()))
    );
}

#[test]
fn side_call_kinds_come_from_synthetic_conversation_ids() {
    let uuid = uuid::Uuid::new_v4();
    assert_eq!(
        side_call_kind(Some(&format!("turn-summary-{uuid}")), Some("s"), None),
        "turn-summary"
    );
    assert_eq!(
        side_call_kind(Some(&format!("dream-v2-{uuid}")), None, None),
        "dream-v2"
    );
    assert_eq!(side_call_kind(Some("s"), Some("s"), None), "side");
    assert_eq!(side_call_kind(Some("btw-test"), Some("s"), None), "side");
    assert_eq!(side_call_kind(None, Some("s"), None), "side");
    assert_eq!(side_call_kind(Some(&format!("{uuid}")), None, None), "side");
    // A call that keeps the session's conversation id (for the prompt cache) is named by its request id.
    assert_eq!(
        side_call_kind(Some("s"), Some("s"), Some(&format!("xai-goal-eval-{uuid}"))),
        "goal-eval"
    );
    assert_eq!(
        side_call_kind(Some(&format!("title-{uuid}")), Some("s"), Some("r1")),
        "title"
    );
    assert_eq!(side_call_kind(Some("s"), Some("s"), Some("r1")), "side");
}

#[test]
fn providers_are_named_by_host_then_backend() {
    assert_eq!(
        provider_name(&ApiBackend::Messages, "https://api.anthropic.com/v1"),
        "anthropic"
    );
    assert_eq!(
        provider_name(&ApiBackend::ChatCompletions, "https://api.x.ai/v1"),
        "xai"
    );
    assert_eq!(
        provider_name(&ApiBackend::OpenRouter, "https://openrouter.ai/api/v1"),
        "openrouter"
    );
    assert_eq!(
        provider_name(&ApiBackend::Messages, "https://api.deepseek.com/anthropic"),
        "deepseek"
    );
    assert_eq!(
        provider_name(&ApiBackend::Glm, "https://open.bigmodel.cn/api/paas/v4"),
        "zai"
    );
    assert_eq!(
        provider_name(&ApiBackend::ChatCompletions, "http://127.0.0.1:8080/v1"),
        "127.0.0.1"
    );
    assert_eq!(
        provider_name(&ApiBackend::OpenAiCodex, "https://example.test"),
        "openai"
    );
}

#[test]
fn long_parts_are_cut_on_a_char_boundary_with_a_note() {
    let text = "é".repeat(MAX_PART_BYTES);
    let cut = capped(&text);
    assert!(cut.len() < text.len());
    assert!(cut.ends_with(&format!(
        "[crok: {} more bytes not sent]",
        text.len() - MAX_PART_BYTES
    )));
    assert_eq!(capped("short"), "short");
}

#[tokio::test]
async fn a_turn_is_the_parent_of_its_calls_tool_runs_and_steps_and_counts_them() {
    sink();
    let client = anthropic_client();
    register_session("obs-turn-tree", None, None);
    set_session_title("obs-turn-tree", "Fix the flaky test");
    set_session_tag("obs-turn-tree", "repo", "me/proj");
    set_session_tag("obs-turn-tree", "branch", "charlie/dev");
    let turn = begin_turn(TurnStart {
        session_id: "obs-turn-tree",
        turn_index: Some(3),
        model: Some("claude-test"),
        permission_mode: Some("default"),
    })
    .expect("a sink is installed");
    let span = turn.span().clone();
    assert_eq!(span.trace_id.len(), 32);
    assert_eq!(span.span_id.len(), 16);
    run_turn(&client, &turn_request("obs-turn-tree"), CallPath::Turn).await;
    let now = std::time::SystemTime::now();
    record_tool(ToolRun {
        session_id: "obs-turn-tree",
        tool_name: "run_terminal_command",
        tool_call_id: "call_9",
        started_at: now,
        completed_at: now,
        outcome: ToolRunOutcome::Error,
        kind: "mutating",
        exit_code: Some(2),
        result_bytes: Some(120),
        backgrounded: false,
        error: Some("exit status 2\nmore detail"),
        model: Some("claude-test"),
    });
    record_step(Step {
        session_id: "obs-turn-tree",
        name: "permission",
        started_at: now,
        completed_at: now,
        input: serde_json::Map::new(),
        output: serde_json::Map::from_iter([("decision".to_owned(), "allow".into())]),
        error: None,
    });
    record_verdict(Verdict {
        session_id: "obs-turn-tree",
        evaluator: "crok.laziness",
        key: "category",
        value: VerdictValue::Label("not_stalled_complete"),
        passed: Some(true),
        explanation: None,
    });
    turn.end(TurnEnd::Completed, None);

    let call = &records_for("obs-turn-tree")[0];
    assert_eq!(call["parent"]["traceId"], span.trace_id.as_str());
    assert_eq!(call["parent"]["spanId"], span.span_id.as_str());
    assert_eq!(call["start"]["tags"]["repo"], "me/proj");
    assert_eq!(call["start"]["tags"]["branch"], "charlie/dev");

    let tool = &events_of("obs-turn-tree", "tool")[0];
    assert_eq!(tool["parent"]["spanId"], span.span_id.as_str());
    assert_eq!(tool["toolName"], "run_terminal_command");
    assert_eq!(
        tool["error"], "exit status 2",
        "only the first line is sent"
    );
    assert_eq!(tool["attributes"]["crok.tool.outcome"], "error");
    assert_eq!(tool["attributes"]["crok.tool.exit_code"], 2);
    assert_eq!(tool["tags"]["repo"], "me/proj");

    let step = &events_of("obs-turn-tree", "step")[0];
    assert_eq!(step["stepName"], "permission");
    assert_eq!(step["parent"]["traceId"], span.trace_id.as_str());
    assert_eq!(
        step["linkedGenerationIds"],
        serde_json::json!([call["start"]["id"]])
    );

    let score = &events_of("obs-turn-tree", "score")[0];
    assert_eq!(score["generationId"], call["start"]["id"]);
    assert_eq!(score["evaluatorId"], "crok.laziness");
    assert_eq!(
        score["value"],
        serde_json::json!({ "string": "not_stalled_complete" })
    );
    assert_eq!(score["traceId"], span.trace_id.as_str());

    let ended = &events_of("obs-turn-tree", "turn")[0];
    assert_eq!(ended["span"]["spanId"], span.span_id.as_str());
    assert!(ended["parent"].is_null());
    assert_eq!(ended["agentName"], "crok");
    assert_eq!(ended["conversationTitle"], "Fix the flaky test");
    assert_eq!(ended["attributes"]["crok.turn.outcome"], "completed");
    assert_eq!(ended["attributes"]["crok.turn_index"], 3);
    assert_eq!(ended["attributes"]["crok.model_calls"], 1);
    assert_eq!(ended["attributes"]["crok.tool_calls"], 1);
    assert_eq!(ended["attributes"]["crok.tool_errors"], 1);
    assert_eq!(ended["attributes"]["gen_ai.request.model"], "claude-test");

    // After the turn, calls hang under nothing.
    run_turn(&client, &turn_request("obs-turn-tree"), CallPath::SideCall).await;
    assert!(records_for("obs-turn-tree")[1].get("parent").is_none());
}

#[tokio::test]
async fn a_sub_agent_turn_joins_the_trace_of_the_turn_that_started_it() {
    sink();
    register_session("obs-trace-parent", None, None);
    register_session("obs-trace-child", Some("explore"), Some("obs-trace-parent"));
    let parent = begin_turn(TurnStart {
        session_id: "obs-trace-parent",
        turn_index: None,
        model: None,
        permission_mode: None,
    })
    .unwrap();
    let child = begin_turn(TurnStart {
        session_id: "obs-trace-child",
        turn_index: None,
        model: None,
        permission_mode: None,
    })
    .unwrap();
    assert_eq!(child.span().trace_id, parent.span().trace_id);
    assert_ne!(child.span().span_id, parent.span().span_id);
    let parent_span = parent.span().clone();
    child.end(TurnEnd::Error, Some("the model stopped answering"));
    drop(parent);

    let child_turn = &events_of("obs-trace-child", "turn")[0];
    assert_eq!(child_turn["parent"]["spanId"], parent_span.span_id.as_str());
    assert_eq!(child_turn["agentName"], "crok/explore");
    assert_eq!(child_turn["attributes"]["crok.turn.outcome"], "error");
    assert_eq!(child_turn["error"], "the model stopped answering");
    let parent_turn = &events_of("obs-trace-parent", "turn")[0];
    assert_eq!(
        parent_turn["attributes"]["crok.turn.outcome"], "cancelled",
        "a turn dropped without ending was interrupted"
    );
}

#[tokio::test]
async fn a_prompt_from_the_relay_tags_its_turn_and_only_that_turn() {
    sink();
    let client = anthropic_client();
    register_session("obs-relay", None, None);
    note_prompt_origin("obs-relay", "relay");
    let turn = begin_turn(TurnStart {
        session_id: "obs-relay",
        turn_index: None,
        model: None,
        permission_mode: None,
    })
    .unwrap();
    run_turn(&client, &turn_request("obs-relay"), CallPath::Turn).await;
    turn.end(TurnEnd::Completed, None);
    let next = begin_turn(TurnStart {
        session_id: "obs-relay",
        turn_index: None,
        model: None,
        permission_mode: None,
    })
    .unwrap();
    run_turn(&client, &turn_request("obs-relay"), CallPath::Turn).await;
    next.end(TurnEnd::Completed, None);

    let calls = records_for("obs-relay");
    assert_eq!(calls[0]["start"]["tags"]["origin"], "relay");
    assert!(calls[1]["start"]["tags"].get("origin").is_none());
    let turns = events_of("obs-relay", "turn");
    assert_eq!(turns[0]["tags"]["origin"], "relay");
    assert_eq!(turns[0]["attributes"]["crok.origin"], "relay");
    assert!(turns[1]["tags"].get("origin").is_none());
}

#[test]
fn a_verdict_needs_a_generation_and_a_guard_check_needs_something_to_check() {
    sink();
    register_session("obs-verdictless", None, None);
    record_verdict(Verdict {
        session_id: "obs-verdictless",
        evaluator: "crok.goal_verdict",
        key: "decision",
        value: VerdictValue::Label("continue"),
        passed: None,
        explanation: None,
    });
    check_guard(GuardCheck::Postflight {
        session_id: "obs-verdictless",
        provider: "anthropic",
        model: "claude-test",
        calls: Vec::new(),
    });
    assert!(events_for("obs-verdictless").is_empty());

    check_guard(GuardCheck::Postflight {
        session_id: "obs-verdictless",
        provider: "anthropic",
        model: "claude-test",
        calls: vec![GuardToolCall {
            id: "call_1",
            name: "run_terminal_command",
            arguments: r#"{"command":"git push --force"}"#,
        }],
    });
    check_guard(GuardCheck::Preflight {
        session_id: "obs-verdictless",
        provider: "anthropic",
        model: "claude-test",
        results: vec![GuardToolResult {
            id: "call_2",
            name: "read_file",
            content: "API_KEY=sk-test",
        }],
    });
    let guards = events_of("obs-verdictless", "guard");
    assert_eq!(guards.len(), 2);
    assert_eq!(guards[0]["phase"], "postflight");
    assert_eq!(
        guards[0]["input"]["output"][0]["parts"][0]["toolCall"]["name"],
        "run_terminal_command"
    );
    assert_eq!(guards[1]["phase"], "preflight");
    assert_eq!(
        guards[1]["input"]["messages"][0]["parts"][0]["toolResult"]["content"],
        "API_KEY=sk-test"
    );
    assert_eq!(guards[1]["model"]["provider"], "anthropic");
}

#[test]
fn guard_providers_come_from_model_ids() {
    assert_eq!(
        guard_provider("openrouter/~deepseek/deepseek-flash-latest"),
        "openrouter"
    );
    assert_eq!(guard_provider("claude-sonnet-5-5"), "anthropic");
    assert_eq!(guard_provider("deepseek-flash"), "deepseek");
    assert_eq!(guard_provider("glm-5.3"), "zai");
    assert_eq!(guard_provider("grok-4.6"), "xai");
    assert_eq!(guard_provider("local-model"), "unknown");
}

#[tokio::test]
async fn blank_text_and_thinking_are_left_out_so_the_generation_is_kept() {
    sink();
    let client = anthropic_client();
    let mut reply = response("\n\n");
    if let Some(ConversationItem::Reasoning(reasoning)) = reply.items.first_mut() {
        reasoning.content = Some(vec![rs::ReasoningTextContent {
            text: "  \n".to_owned(),
        }]);
    }
    run_with(&client, &turn_request("obs-blank"), CallPath::Turn, reply).await;

    let record = &records_for("obs-blank")[0];
    let parts = record["result"]["output"][0]["parts"].as_array().unwrap();
    assert_eq!(parts.len(), 1, "only the tool call is left: {parts:?}");
    assert_eq!(parts[0]["type"], "tool_call");
}
