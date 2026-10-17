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
struct TestSink(Mutex<Vec<String>>);

thread_local! {
    /// Switches the shared sink off for one test's thread only, so tests running beside it still record.
    static SWITCHED_OFF: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
}

impl GenerationSink for TestSink {
    fn record(&self, call: ObservedCall) {
        self.0.lock().unwrap().push(call.to_json_line());
    }

    fn is_active(&self) -> bool {
        !SWITCHED_OFF.get()
    }
}

fn sink() -> &'static TestSink {
    static TEST_SINK: OnceLock<Arc<TestSink>> = OnceLock::new();
    TEST_SINK.get_or_init(|| {
        let sink = Arc::new(TestSink(Mutex::new(Vec::new())));
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

fn completed(text: &str) -> SamplingEvent {
    SamplingEvent::Completed {
        request_id: RequestId::from("r"),
        response: Box::new(response(text)),
        metrics: InferenceLatencyStats::default(),
    }
}

async fn run_turn(client: &SamplingClient, request: &ConversationRequest, path: CallPath) {
    let observation = Observation::start(client, request, path);
    assert!(observation.is_some(), "a sink is installed");
    let events = stream::iter(vec![
        SamplingEvent::FirstToken {
            request_id: RequestId::from("r"),
        },
        completed("Found it."),
    ]);
    let _: Vec<_> = watch(observation, events).collect().await;
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
        side_call_kind(Some(&format!("turn-summary-{uuid}")), Some("s")),
        "turn-summary"
    );
    assert_eq!(
        side_call_kind(Some(&format!("dream-v2-{uuid}")), None),
        "dream-v2"
    );
    assert_eq!(side_call_kind(Some("s"), Some("s")), "side");
    assert_eq!(side_call_kind(Some("btw-test"), Some("s")), "side");
    assert_eq!(side_call_kind(None, Some("s")), "side");
    assert_eq!(side_call_kind(Some(&format!("{uuid}")), None), "side");
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
