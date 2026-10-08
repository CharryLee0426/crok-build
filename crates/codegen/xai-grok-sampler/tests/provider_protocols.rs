//! Exercise subscription and gateway protocols over HTTP without real credentials.
use std::sync::{Arc, Mutex};
use std::time::Duration;

use axum::{Router, body::Bytes, http::HeaderMap, routing::post};
use futures_util::StreamExt;
use serde_json::{Value, json};
use tokio::net::TcpListener;
use xai_grok_sampler::{SamplerConfig, SamplingClient};
use xai_grok_sampling_types::{
    ApiBackend, ConversationItem, ConversationRequest, ReasoningEffort, ToolSpec,
};

type Captured = Arc<Mutex<Vec<(HeaderMap, Value)>>>;

async fn server(path: &str, events: Vec<Value>) -> (String, Captured, tokio::task::JoinHandle<()>) {
    let captured: Captured = Arc::new(Mutex::new(Vec::new()));
    let sink = captured.clone();
    let keep_open = path.contains("codex");
    let sse: String = events
        .into_iter()
        .map(|value| format!("data: {value}\n\n"))
        .collect();
    let app = Router::new().route(
        path,
        post(move |headers: HeaderMap, body: Bytes| {
            sink.lock()
                .unwrap()
                .push((headers, serde_json::from_slice(&body).unwrap()));
            let sse = sse.clone();
            async move {
                let body = if keep_open {
                    axum::body::Body::from_stream(
                        futures_util::stream::once(async move {
                            Ok::<_, std::io::Error>(Bytes::from(sse))
                        })
                        .chain(futures_util::stream::pending()),
                    )
                } else {
                    axum::body::Body::from(sse)
                };
                axum::response::Response::builder()
                    .header("content-type", "text/event-stream")
                    .body(body)
                    .unwrap()
            }
        }),
    );
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base = format!("http://{}", listener.local_addr().unwrap());
    let task = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    (base, captured, task)
}

fn request() -> ConversationRequest {
    ConversationRequest {
        items: vec![
            ConversationItem::system("Be precise."),
            ConversationItem::user("Read hello.txt"),
        ],
        tools: vec![ToolSpec {
            name: "read".into(),
            description: Some("Read a file".into()),
            parameters: json!({"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}),
        }],
        reasoning_effort: Some(ReasoningEffort::High),
        x_grok_conv_id: Some("conv-fixture".into()),
        ..Default::default()
    }
}

#[tokio::test]
async fn codex_subscription_sse_reassembles_reasoning_and_tool_calls() {
    let reasoning = json!({"type":"reasoning","id":"rs_fixture","summary":[{"type":"summary_text","text":"Need the file."}],"encrypted_content":"opaque-signature"});
    let tool = json!({"type":"function_call","id":"fc_fixture","call_id":"call_fixture","name":"read","arguments":"{\"path\":\"hello.txt\"}","status":"completed"});
    let events = vec![
        json!({"type":"response.output_item.done","output_index":0,"item":reasoning}),
        json!({"type":"response.output_item.added","output_index":1,"item":{"type":"function_call","id":"fc_fixture","call_id":"call_fixture","name":"read","arguments":""}}),
        json!({"type":"response.function_call_arguments.delta","output_index":1,"item_id":"fc_fixture","delta":"{\"path\":\"hello.txt\"}"}),
        json!({"type":"response.output_item.done","output_index":1,"item":tool}),
        json!({"type":"response.done","response":{"id":"resp_fixture","status":"completed","model":"gpt-codex-test","usage":{"input_tokens":10,"output_tokens":5}}}),
    ];
    let (base, captured, task) = server("/backend-api/codex/responses", events).await;
    let mut config = SamplerConfig {
        base_url: format!("{base}/backend-api"),
        model: "gpt-codex-test".into(),
        api_backend: ApiBackend::OpenAiCodex,
        api_key: Some("fixture-token".into()),
        max_completion_tokens: Some(8192),
        stream_tool_calls: true,
        ..Default::default()
    };
    config
        .extra_headers
        .insert("chatgpt-account-id".into(), "account-fixture".into());
    let client = SamplingClient::new(config).unwrap();
    let response = client
        .conversation_collect_with_idle_timeout(request(), Duration::from_secs(2))
        .await
        .unwrap();
    let assistant = response.assistant().unwrap();
    assert_eq!(
        assistant.tool_calls.first().unwrap().id.as_ref(),
        "call_fixture"
    );
    assert_eq!(
        assistant.tool_calls.first().unwrap().arguments.as_ref(),
        "{\"path\":\"hello.txt\"}"
    );
    assert_eq!(
        response
            .reasoning_items()
            .next()
            .unwrap()
            .encrypted_content
            .as_deref(),
        Some("opaque-signature")
    );
    // Even the non-streaming public entry point must use the SSE-only endpoint.
    let response = client.conversation_responses(request()).await.unwrap();
    assert_eq!(response.output.len(), 2);
    let requests = captured.lock().unwrap();
    for (headers, body) in requests.iter() {
        assert_eq!(
            headers.get("authorization").unwrap(),
            "Bearer fixture-token"
        );
        assert_eq!(
            headers.get("chatgpt-account-id").unwrap(),
            "account-fixture"
        );
        assert_eq!(
            headers.get("openai-beta").unwrap(),
            "responses=experimental"
        );
        assert_eq!(headers.get("session-id").unwrap(), "conv-fixture");
        assert_eq!(body.get("instructions"), Some(&json!("Be precise.")));
        assert_eq!(body.get("store"), Some(&json!(false)));
        assert_eq!(body.get("stream"), Some(&json!(true)));
        assert!(body.get("max_output_tokens").is_none());
        assert!(body.get("stream_tool_calls").is_none());
        assert_eq!(body.pointer("/input/0/role"), Some(&json!("user")));
    }
    task.abort();
}

/// The assistant message a later request carries for the tool call made in an earlier one.
fn replayed_tool_call(body: &Value) -> &Value {
    body.get("messages")
        .unwrap()
        .as_array()
        .unwrap()
        .iter()
        .find(|msg| msg.get("tool_calls").is_some())
        .unwrap()
}

#[tokio::test]
async fn deepseek_sends_reasoning_back_through_a_tool_loop() {
    let chunk = |delta: Value, finish: Value| json!({"id":"chat-fixture","object":"chat.completion.chunk","created":0,"model":"deepseek-v4-pro","choices":[{"index":0,"delta":delta,"finish_reason":finish}]});
    let mut last = chunk(
        json!({"tool_calls":[{"index":0,"id":"call-fixture","type":"function","function":{"name":"read","arguments":"{\"path\":\"hello.txt\"}"}}]}),
        json!("tool_calls"),
    );
    // DeepSeek puts usage on the final content chunk and names its cache hits itself.
    last["usage"] = json!({"prompt_tokens":120,"completion_tokens":30,"total_tokens":150,"prompt_cache_hit_tokens":80,"prompt_cache_miss_tokens":40,"completion_tokens_details":{"reasoning_tokens":12}});
    let events = vec![
        chunk(
            json!({"role":"assistant","reasoning_content":"Need "}),
            Value::Null,
        ),
        chunk(json!({"reasoning_content":"the file."}), Value::Null),
        last,
    ];
    let (base, captured, task) = server("/chat/completions", events).await;
    let client = SamplingClient::new(SamplerConfig {
        base_url: base,
        model: "deepseek-v4-pro".into(),
        api_backend: ApiBackend::DeepSeek,
        api_key: Some("sk-fixture".into()),
        ..Default::default()
    })
    .unwrap();
    let response = client.conversation_collect(request()).await.unwrap();
    let usage = response.usage.as_ref().unwrap();
    assert_eq!(usage.cached_prompt_tokens, 80);
    assert_eq!(usage.reasoning_tokens, 12);
    assert_eq!(
        response
            .assistant()
            .unwrap()
            .tool_calls
            .first()
            .unwrap()
            .arguments
            .as_ref(),
        "{\"path\":\"hello.txt\"}"
    );

    let mut next = request();
    // Exercise serialization used by session persistence before the next turn.
    let persisted = serde_json::to_value(&response.items).unwrap();
    next.items
        .extend(serde_json::from_value::<Vec<ConversationItem>>(persisted).unwrap());
    next.items
        .push(ConversationItem::tool_result("call-fixture", "hello"));
    client.conversation_collect(next).await.unwrap();

    let requests = captured.lock().unwrap();
    let (headers, body) = requests.last().unwrap();
    assert_eq!(headers.get("authorization").unwrap(), "Bearer sk-fixture");
    assert_eq!(body.get("model"), Some(&json!("deepseek-v4-pro")));
    assert_eq!(body.get("stream"), Some(&json!(true)));
    assert_eq!(body.get("reasoning_effort"), Some(&json!("high")));
    let assistant = replayed_tool_call(body);
    assert_eq!(
        assistant.get("reasoning_content"),
        Some(&json!("Need the file."))
    );
    assert!(assistant.get("model_id").is_none());
    assert!(assistant.get("reasoning_details").is_none());
    task.abort();
}

#[tokio::test]
async fn glm_coding_plan_streams_tool_calls_and_keeps_reasoning() {
    // As the service sends them: no `object` field, and tool arguments in pieces.
    let chunk = |delta: Value, finish: Value| json!({"id":"2026100712","created":0,"model":"glm-5.3","choices":[{"index":0,"delta":delta,"finish_reason":finish}]});
    let mut last = chunk(
        json!({"tool_calls":[{"index":0,"function":{"arguments":"\"hello.txt\"}"}}]}),
        json!("tool_calls"),
    );
    last["usage"] = json!({"prompt_tokens":90,"completion_tokens":20,"total_tokens":110,"prompt_tokens_details":{"cached_tokens":60}});
    let events = vec![
        chunk(
            json!({"role":"assistant","reasoning_content":"Need the file."}),
            Value::Null,
        ),
        chunk(
            json!({"tool_calls":[{"index":0,"id":"call-fixture","type":"function","function":{"name":"read","arguments":"{\"path\":"}}]}),
            Value::Null,
        ),
        last,
    ];
    let (base, captured, task) = server("/api/coding/paas/v4/chat/completions", events).await;
    let client = SamplingClient::new(SamplerConfig {
        base_url: format!("{base}/api/coding/paas/v4"),
        model: "glm-5.3".into(),
        api_backend: ApiBackend::Glm,
        api_key: Some("fixture.key".into()),
        max_completion_tokens: Some(131_072),
        ..Default::default()
    })
    .unwrap();
    let response = client.conversation_collect(request()).await.unwrap();
    assert_eq!(response.usage.as_ref().unwrap().cached_prompt_tokens, 60);
    let call = response.assistant().unwrap().tool_calls.first().unwrap();
    assert_eq!(call.id.as_ref(), "call-fixture");
    assert_eq!(call.arguments.as_ref(), "{\"path\":\"hello.txt\"}");

    let mut next = request();
    let persisted = serde_json::to_value(&response.items).unwrap();
    next.items
        .extend(serde_json::from_value::<Vec<ConversationItem>>(persisted).unwrap());
    next.items
        .push(ConversationItem::tool_result("call-fixture", "hello"));
    client.conversation_collect(next).await.unwrap();

    let requests = captured.lock().unwrap();
    for (headers, body) in requests.iter() {
        assert_eq!(headers.get("authorization").unwrap(), "Bearer fixture.key");
        assert_eq!(body.get("model"), Some(&json!("glm-5.3")));
        assert_eq!(body.get("max_tokens"), Some(&json!(131_072)));
        assert_eq!(body.get("tool_stream"), Some(&json!(true)));
        assert_eq!(body.get("reasoning_effort"), Some(&json!("high")));
        assert_eq!(
            body.get("thinking"),
            Some(&json!({"type": "enabled", "clear_thinking": false}))
        );
        assert_eq!(
            body.pointer("/stream_options/include_usage"),
            Some(&json!(true))
        );
    }
    let (_, body) = requests.last().unwrap();
    let assistant = replayed_tool_call(body);
    assert_eq!(
        assistant.get("reasoning_content"),
        Some(&json!("Need the file."))
    );
    assert!(assistant.get("model_id").is_none());
    task.abort();
}

#[tokio::test]
async fn a_reply_cut_short_by_the_provider_fails_the_request() {
    let events = vec![
        json!({"id":"1","created":0,"model":"glm-5.3","choices":[{"index":0,"delta":{"content":"Half an ans"}}]}),
        json!({"id":"1","created":0,"model":"glm-5.3","choices":[{"index":0,"delta":{},"finish_reason":"network_error"}]}),
    ];
    let (base, _captured, task) = server("/chat/completions", events).await;
    let client = SamplingClient::new(SamplerConfig {
        base_url: base,
        model: "glm-5.3".into(),
        api_backend: ApiBackend::Glm,
        api_key: Some("fixture.key".into()),
        ..Default::default()
    })
    .unwrap();
    let error = client.conversation_collect(request()).await.unwrap_err();
    assert!(error.to_string().contains("network_error"), "{error}");
    task.abort();
}

#[tokio::test]
async fn openrouter_replays_signed_reasoning_after_streamed_tool_call() {
    let chunk = |delta: Value, finish: Value| json!({"id":"chat-fixture","object":"chat.completion.chunk","created":0,"model":"provider/test","choices":[{"index":0,"delta":delta,"finish_reason":finish}]});
    let events = vec![
        chunk(
            json!({"reasoning":"Need ","reasoning_details":[{"type":"reasoning.text","index":0,"text":"Need ","format":"anthropic-claude-v1"}]}),
            Value::Null,
        ),
        chunk(
            json!({"reasoning":"file.","reasoning_details":[{"type":"reasoning.text","index":0,"text":"file.","signature":"signed-fixture"}]}),
            Value::Null,
        ),
        chunk(
            json!({"tool_calls":[{"index":0,"id":"call-fixture","type":"function","function":{"name":"read","arguments":"{\"path\":\"hello.txt\"}"}}]}),
            json!("tool_calls"),
        ),
    ];
    let (base, captured, task) = server("/api/v1/chat/completions", events).await;
    let client = SamplingClient::new(SamplerConfig {
        base_url: format!("{base}/api/v1"),
        model: "provider/test".into(),
        api_backend: ApiBackend::OpenRouter,
        api_key: Some("fixture-token".into()),
        ..Default::default()
    })
    .unwrap();
    let response = client.conversation_collect(request()).await.unwrap();
    let mut next = request();
    // Exercise serialization used by session persistence before the next turn.
    let persisted = serde_json::to_value(&response.items).unwrap();
    next.items
        .extend(serde_json::from_value::<Vec<ConversationItem>>(persisted).unwrap());
    next.items
        .push(ConversationItem::tool_result("call-fixture", "hello"));
    client.conversation_collect(next).await.unwrap();
    let requests = captured.lock().unwrap();
    let (_, body) = requests.last().unwrap();
    let assistant = body
        .get("messages")
        .unwrap()
        .as_array()
        .unwrap()
        .iter()
        .find(|msg| msg.get("role") == Some(&json!("assistant")))
        .unwrap();
    assert_eq!(body.pointer("/reasoning/effort"), Some(&json!("high")));
    assert!(body.get("reasoning_effort").is_none());
    // Structured reasoning replaces the plaintext alias in replay requests.
    assert!(assistant.get("reasoning").is_none());
    assert_eq!(
        assistant.pointer("/reasoning_details/0/text"),
        Some(&json!("Need file."))
    );
    assert_eq!(
        assistant.pointer("/reasoning_details/0/signature"),
        Some(&json!("signed-fixture"))
    );
    assert!(assistant.get("model_id").is_none());
    task.abort();
}
