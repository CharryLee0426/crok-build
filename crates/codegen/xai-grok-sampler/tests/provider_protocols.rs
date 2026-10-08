//! Exercise subscription and gateway protocols over HTTP without real credentials.
use std::sync::{Arc, Mutex};
use std::time::Duration;

use axum::{Router, body::Bytes, http::HeaderMap, routing::post};
use futures_util::StreamExt;
use serde_json::{Value, json};
use tokio::net::TcpListener;
use xai_grok_sampler::{SamplerConfig, SamplingClient};
use xai_grok_sampling_types::{
    AnthropicOptions, ApiBackend, ConversationItem, ConversationRequest, ConversationToolChoice,
    PromptCacheTtl, ReasoningEffort, ToolSpec,
};

type Captured = Arc<Mutex<Vec<(HeaderMap, Value)>>>;

async fn server(path: &str, events: Vec<Value>) -> (String, Captured, tokio::task::JoinHandle<()>) {
    server_with_headers(path, events, &[]).await
}

/// Like [`server`], with `response_headers` on every response.
async fn server_with_headers(
    path: &str,
    events: Vec<Value>,
    response_headers: &[(&'static str, &'static str)],
) -> (String, Captured, tokio::task::JoinHandle<()>) {
    let captured: Captured = Arc::new(Mutex::new(Vec::new()));
    let sink = captured.clone();
    let keep_open = path.contains("codex");
    let response_headers = response_headers.to_vec();
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
            let response_headers = response_headers.clone();
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
                let mut response =
                    axum::response::Response::builder().header("content-type", "text/event-stream");
                for (name, value) in response_headers {
                    response = response.header(name, value);
                }
                response.body(body).unwrap()
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

/// Where `cache_control` sits in an OpenRouter body: `/messages/{index}` for a whole message, or
/// `/messages/{index}/content/{part}` for one content part.
fn cache_breakpoints(body: &Value) -> Vec<String> {
    let mut found = Vec::new();
    for (index, message) in body["messages"].as_array().unwrap().iter().enumerate() {
        if message.get("cache_control").is_some() {
            found.push(format!("/messages/{index}"));
        }
        for (part, block) in message["content"]
            .as_array()
            .into_iter()
            .flatten()
            .enumerate()
        {
            if block.get("cache_control").is_some() {
                found.push(format!("/messages/{index}/content/{part}"));
            }
        }
    }
    found
}

#[tokio::test]
async fn claude_on_openrouter_marks_cache_breakpoints_and_pins_one_session() {
    let chunk = |delta: Value, finish: Value| json!({"id":"chat-fixture","object":"chat.completion.chunk","created":0,"model":"anthropic/claude-test","choices":[{"index":0,"delta":delta,"finish_reason":finish}]});
    let mut last = chunk(
        json!({"tool_calls":[{"index":0,"id":"call-fixture","type":"function","function":{"name":"read","arguments":"{\"path\":\"hello.txt\"}"}}]}),
        json!("tool_calls"),
    );
    last["usage"] = json!({"prompt_tokens":5000,"completion_tokens":40,"total_tokens":5040,"prompt_tokens_details":{"cached_tokens":4000,"cache_write_tokens":900}});
    let events = vec![
        chunk(
            json!({"reasoning":"Need the file.","reasoning_details":[{"type":"reasoning.text","index":0,"text":"Need the file.","signature":"signed-fixture","format":"anthropic-claude-v1"}]}),
            Value::Null,
        ),
        last,
    ];
    let (base, captured, task) = server("/api/v1/chat/completions", events).await;
    let client = SamplingClient::new(SamplerConfig {
        base_url: format!("{base}/api/v1"),
        model: "anthropic/claude-test".into(),
        api_backend: ApiBackend::OpenRouter,
        api_key: Some("fixture-token".into()),
        ..Default::default()
    })
    .unwrap();
    let response = client.conversation_collect(request()).await.unwrap();
    let usage = response.usage.as_ref().unwrap();
    assert_eq!(usage.cached_prompt_tokens, 4000);
    assert_eq!(usage.cache_creation_prompt_tokens, 900);

    let mut next = request();
    let persisted = serde_json::to_value(&response.items).unwrap();
    next.items
        .extend(serde_json::from_value::<Vec<ConversationItem>>(persisted).unwrap());
    next.items
        .push(ConversationItem::tool_result("call-fixture", "hello"));
    client.conversation_collect(next).await.unwrap();

    let requests = captured.lock().unwrap();
    let [(_, first), (_, second)] = requests.as_slice() else {
        panic!("expected two requests, got {}", requests.len());
    };
    for body in [first, second] {
        assert_eq!(body.get("session_id"), Some(&json!("conv-fixture")));
        assert_eq!(body.get("prompt_cache_key"), Some(&json!("conv-fixture")));
    }
    assert_eq!(
        cache_breakpoints(first),
        ["/messages/0/content/0", "/messages/1/content/0"]
    );
    // The tool result is the newest message; the prompt is where the first request ended.
    assert_eq!(
        cache_breakpoints(second),
        [
            "/messages/0/content/0",
            "/messages/1/content/0",
            "/messages/3"
        ]
    );
    assert_eq!(
        second.pointer("/messages/2/reasoning_details/0/signature"),
        Some(&json!("signed-fixture"))
    );
    task.abort();
}

#[tokio::test]
async fn codex_keeps_a_turn_on_one_backend_and_side_calls_on_the_parent_session() {
    let done = json!({"type":"response.done","response":{"id":"resp_fixture","status":"completed","model":"gpt-codex-test","output":[{"type":"message","id":"msg_fixture","role":"assistant","status":"completed","content":[{"type":"output_text","text":"Done.","annotations":[]}]}],"usage":{"input_tokens":10,"output_tokens":5}}});
    let (base, captured, task) = server_with_headers(
        "/backend-api/codex/responses",
        vec![done],
        &[("x-codex-turn-state", "ts-first")],
    )
    .await;
    let client = SamplingClient::new(SamplerConfig {
        base_url: format!("{base}/backend-api"),
        model: "gpt-codex-test".into(),
        api_backend: ApiBackend::OpenAiCodex,
        api_key: Some("fixture-token".into()),
        ..Default::default()
    })
    .unwrap();
    let in_turn = |turn: &str| ConversationRequest {
        x_grok_conv_id: Some("conv-turn-state".into()),
        x_grok_turn_idx: Some(turn.into()),
        ..request()
    };
    let side_call = ConversationRequest {
        x_grok_conv_id: Some("recap-fixture".into()),
        prompt_cache_key: Some("conv-turn-state".into()),
        ..request()
    };
    for request in [in_turn("3"), in_turn("3"), in_turn("4"), side_call] {
        client
            .conversation_collect_with_idle_timeout(request, Duration::from_secs(2))
            .await
            .unwrap();
    }

    let requests = captured.lock().unwrap();
    let turn_state: Vec<_> = requests
        .iter()
        .map(|(headers, _)| {
            headers
                .get("x-codex-turn-state")
                .map(|value| value.to_str().unwrap())
        })
        .collect();
    // Echoed within the turn that received it, never into another turn or a side call.
    assert_eq!(turn_state, [None, Some("ts-first"), None, None]);
    for (headers, body) in requests.iter() {
        assert_eq!(headers.get("session-id").unwrap(), "conv-turn-state");
        assert_eq!(
            body.get("prompt_cache_key"),
            Some(&json!("conv-turn-state"))
        );
    }
    task.abort();
}

/// Every `cache_control` in a Messages request body, as `<where>:<ttl or "5m">`, in render order.
fn messages_cache_breakpoints(body: &Value) -> Vec<String> {
    let lifetime = |marker: &Value| {
        assert_eq!(marker["type"], "ephemeral");
        marker
            .get("ttl")
            .and_then(Value::as_str)
            .unwrap_or("5m")
            .to_owned()
    };
    let mut found = Vec::new();
    for (index, tool) in body["tools"].as_array().into_iter().flatten().enumerate() {
        if let Some(marker) = tool.get("cache_control") {
            found.push(format!("tools.{index}:{}", lifetime(marker)));
        }
    }
    for (index, block) in body["system"].as_array().into_iter().flatten().enumerate() {
        if let Some(marker) = block.get("cache_control") {
            found.push(format!("system.{index}:{}", lifetime(marker)));
        }
    }
    for (index, message) in body["messages"]
        .as_array()
        .into_iter()
        .flatten()
        .enumerate()
    {
        for block in message["content"].as_array().into_iter().flatten() {
            if let Some(marker) = block.get("cache_control") {
                found.push(format!("messages.{index}:{}", lifetime(marker)));
            }
        }
    }
    found
}

fn anthropic_tool_turn() -> Vec<Value> {
    vec![
        json!({"type":"message_start","message":{"id":"msg_fixture","type":"message","role":"assistant","content":[],"model":"claude-opus-5-5","stop_reason":null,
            "usage":{"input_tokens":12,"output_tokens":0,"cache_creation_input_tokens":2000,"cache_read_input_tokens":0},"input_transformations":[]}}),
        json!({"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}),
        json!({"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Need the file."}}),
        json!({"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig-fixture"}}),
        json!({"type":"content_block_stop","index":0}),
        json!({"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_fixture","name":"read","input":{}}}),
        json!({"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"path\":\"hello.txt\"}"}}),
        json!({"type":"content_block_stop","index":1}),
        json!({"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":20}}),
        json!({"type":"message_stop"}),
    ]
}

fn anthropic_config(base: &str) -> SamplerConfig {
    SamplerConfig {
        base_url: format!("{base}/v1"),
        model: "claude-opus-5-5".into(),
        api_backend: ApiBackend::Messages,
        auth_scheme: xai_grok_sampler::AuthScheme::XApiKey,
        api_key: Some("sk-ant-fixture".into()),
        max_completion_tokens: Some(128_000),
        anthropic: Some(AnthropicOptions::default()),
        ..Default::default()
    }
}

/// The Claude API with an API key: what the endpoint requires, what it refuses, and every cache
/// breakpoint the harness is allowed, through a tool loop.
#[tokio::test]
async fn anthropic_api_key_requests_are_shaped_for_the_endpoint_and_its_cache() {
    let (base, captured, task) = server("/v1/messages", anthropic_tool_turn()).await;
    let client = SamplingClient::new(SamplerConfig {
        // Other hosts need these for thinking; this one refuses them.
        temperature: Some(1.0),
        top_p: Some(0.9),
        ..anthropic_config(&base)
    })
    .unwrap();

    let first = client
        .conversation_collect_with_idle_timeout(request(), Duration::from_secs(2))
        .await
        .unwrap();
    let usage = first.usage.clone().unwrap();
    assert_eq!(
        (usage.prompt_tokens, usage.cache_creation_prompt_tokens),
        (2012, 2000),
        "the prompt is the uncached remainder plus both cache buckets"
    );
    let mut items = request().items;
    items.extend(first.items.iter().cloned());
    items.push(ConversationItem::tool_result("toolu_fixture", "hello"));
    client
        .conversation_collect_with_idle_timeout(
            ConversationRequest { items, ..request() },
            Duration::from_secs(2),
        )
        .await
        .unwrap();

    let requests = captured.lock().unwrap();
    let (headers, first_body) = requests.first().unwrap();
    assert_eq!(headers.get("x-api-key").unwrap(), "sk-ant-fixture");
    assert!(headers.get("authorization").is_none());
    assert_eq!(headers.get("anthropic-version").unwrap(), "2023-06-01");
    assert_eq!(
        headers.get("anthropic-beta").unwrap(),
        "thinking-binding-controls-2026-08-01"
    );
    for (_, body) in requests.iter() {
        for refused in ["temperature", "top_p", "top_k"] {
            assert!(body.get(refused).is_none(), "{refused} must not be sent");
        }
        assert_eq!(body["max_tokens"], 128_000);
        assert_eq!(body["output_config"]["effort"], "high");
        assert_eq!(
            body["thinking"],
            json!({"type": "adaptive", "display": "summarized",
                   "block_binding": {"prefix_mismatch_behavior": "drop_block"}})
        );
        assert!(body.get("tool_choice").is_none());
    }
    // Tools, the system prompt and the newest message: each its own entry, each kept an hour.
    assert_eq!(
        messages_cache_breakpoints(first_body),
        ["tools.0:1h", "system.0:1h", "messages.0:1h"]
    );
    // The next step adds where the previous request ended, so it reads that entry whatever the
    // step appended. Four is the most a request may carry.
    let (_, second_body) = requests.get(1).unwrap();
    assert_eq!(
        messages_cache_breakpoints(second_body),
        [
            "tools.0:1h",
            "system.0:1h",
            "messages.0:1h",
            "messages.2:1h"
        ]
    );
    // Everything up to the previous request's end is byte for byte what that request sent.
    assert_eq!(first_body["tools"], second_body["tools"]);
    assert_eq!(first_body["system"], second_body["system"]);
    assert_eq!(first_body["messages"][0], second_body["messages"][0]);
    assert_eq!(
        second_body["messages"][1]["content"],
        json!([
            {"type": "thinking", "thinking": "Need the file.", "signature": "sig-fixture"},
            {"type": "tool_use", "id": "toolu_fixture", "name": "read", "input": {"path": "hello.txt"}}
        ])
    );
    task.abort();
}

#[tokio::test]
async fn anthropic_forced_tool_call_is_asked_for_in_words() {
    let (base, captured, task) = server("/v1/messages", anthropic_tool_turn()).await;
    let client = SamplingClient::new(SamplerConfig {
        anthropic: Some(AnthropicOptions {
            cache_ttl: PromptCacheTtl::FiveMinutes,
        }),
        ..anthropic_config(&base)
    })
    .unwrap();
    client
        .conversation_collect_with_idle_timeout(
            ConversationRequest {
                tool_choice: Some(ConversationToolChoice::Function("read".into())),
                max_output_tokens: Some(100),
                temperature: Some(1.0),
                reasoning_effort: None,
                ..request()
            },
            Duration::from_secs(2),
        )
        .await
        .unwrap();

    let requests = captured.lock().unwrap();
    let (_, body) = requests.first().unwrap();
    assert_eq!(body["tool_choice"], json!({"type": "auto"}));
    assert!(body.get("temperature").is_none());
    // Room to think before the call: thinking cannot be turned off and is spent from the same budget.
    assert_eq!(body["max_tokens"], 4096);
    let last = body["messages"].as_array().unwrap().last().unwrap();
    assert_eq!(
        last["content"].as_array().unwrap().last().unwrap()["text"],
        "Answer by calling the `read` tool."
    );
    // With no effort set the request names no thinking configuration, so there is nothing to attach the binding to.
    assert!(body.get("thinking").is_none());
    // The five-minute lifetime is the API's default and is not spelled out.
    assert_eq!(
        messages_cache_breakpoints(body),
        ["tools.0:5m", "system.0:5m", "messages.0:5m"]
    );
    task.abort();
}

/// A Messages host that is not Anthropic's gets none of it: the request is what it always was.
#[tokio::test]
async fn other_messages_hosts_get_the_plain_request() {
    let (base, captured, task) = server("/v1/messages", anthropic_tool_turn()).await;
    let client = SamplingClient::new(SamplerConfig {
        anthropic: None,
        temperature: Some(1.0),
        ..anthropic_config(&base)
    })
    .unwrap();
    client
        .conversation_collect_with_idle_timeout(
            ConversationRequest {
                tool_choice: Some(ConversationToolChoice::Function("read".into())),
                ..request()
            },
            Duration::from_secs(2),
        )
        .await
        .unwrap();

    let requests = captured.lock().unwrap();
    let (headers, body) = requests.first().unwrap();
    assert!(headers.get("anthropic-version").is_none());
    assert!(headers.get("anthropic-beta").is_none());
    assert_eq!(body["temperature"], 1.0);
    assert_eq!(body["tool_choice"], json!({"type": "tool", "name": "read"}));
    assert_eq!(
        body["thinking"],
        json!({"type": "adaptive", "display": "summarized"})
    );
    assert!(body["tools"][0].get("cache_control").is_none());
    assert_eq!(
        messages_cache_breakpoints(body),
        ["system.0:5m", "messages.0:5m"]
    );
    task.abort();
}
