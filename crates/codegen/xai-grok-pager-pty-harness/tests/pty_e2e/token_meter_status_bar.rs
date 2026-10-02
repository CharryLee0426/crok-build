// Per-test-case module for the `pty_e2e` integration test crate.
#[allow(unused_imports)]
use super::common::*;

const PROMPT_TOKENS: u64 = 2_000;
const CACHED_TOKENS: u64 = 1_500;
const OUTPUT_TOKENS: u64 = 120;

/// A Responses API turn whose usage reports a cache read, which the stock scripts leave at zero.
fn responses_script(text: &str) -> Vec<SseEvent> {
    vec![
        SseEvent::data(
            json!({
                "type": "response.created",
                "sequence_number": 0,
                "response": {
                    "id": "resp_tokens",
                    "object": "response",
                    "created_at": 1234567890,
                    "model": "test-model",
                    "status": "in_progress",
                    "output": []
                }
            })
            .to_string(),
        ),
        SseEvent::data(
            json!({
                "type": "response.output_text.delta",
                "sequence_number": 1,
                "item_id": "item_tokens",
                "output_index": 0,
                "content_index": 0,
                "delta": text
            })
            .to_string(),
        ),
        SseEvent::data(
            json!({
                "type": "response.completed",
                "sequence_number": 2,
                "response": {
                    "id": "resp_tokens",
                    "object": "response",
                    "created_at": 1234567890,
                    "model": "test-model",
                    "status": "completed",
                    "output": [{
                        "type": "message",
                        "id": "msg_tokens",
                        "role": "assistant",
                        "status": "completed",
                        "content": [{ "type": "output_text", "text": text, "annotations": [] }]
                    }],
                    "usage": {
                        "input_tokens": PROMPT_TOKENS,
                        "output_tokens": OUTPUT_TOKENS,
                        "total_tokens": PROMPT_TOKENS + OUTPUT_TOKENS,
                        "input_tokens_details": { "cached_tokens": CACHED_TOKENS },
                        "output_tokens_details": { "reasoning_tokens": 0 }
                    }
                }
            })
            .to_string(),
        ),
        SseEvent::data("[DONE]".to_string()),
    ]
}

/// The same turn for the Chat Completions backend.
fn chat_completions_script(text: &str) -> Vec<SseEvent> {
    vec![
        SseEvent::data(
            json!({
                "id": "chatcmpl-tokens",
                "object": "chat.completion.chunk",
                "created": 1234567890,
                "model": "test-model",
                "choices": [{
                    "index": 0,
                    "delta": { "role": "assistant", "content": text },
                    "finish_reason": "stop"
                }]
            })
            .to_string(),
        ),
        SseEvent::data(
            json!({
                "id": "chatcmpl-tokens",
                "object": "chat.completion.chunk",
                "created": 1234567890,
                "model": "test-model",
                "choices": [],
                "usage": {
                    "prompt_tokens": PROMPT_TOKENS,
                    "completion_tokens": OUTPUT_TOKENS,
                    "total_tokens": PROMPT_TOKENS + OUTPUT_TOKENS,
                    "prompt_tokens_details": { "cached_tokens": CACHED_TOKENS }
                }
            })
            .to_string(),
        ),
        SseEvent::data("[DONE]".to_string()),
    ]
}

/// A finished response puts the session's token counts, cache hit rate, and output rate in the status bar.
/// The figures come from the shell's `response_completed` update, so this covers the path from the provider's usage to the row.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore]
async fn token_meter_status_bar() {
    let content = ContentController::start().await.expect("start content");
    let text = format!("{MOCK_RESPONSE_SENTINEL} counted.");
    let _turn = content.expect_agent_turn_with_responses(
        "counted turn",
        ScriptedResponse::sse(responses_script(&text)),
        ScriptedResponse::sse(chat_completions_script(&text)),
    );
    // Without a gap between events the response decodes in zero time, and a rate over zero time is not reported
    content.set_chunk_delay(Some(Duration::from_millis(60)));

    let binary = pager_binary().expect("resolve pager binary");
    let mut harness =
        PtyHarness::spawn_with_content(&binary, DEFAULT_ROWS, DEFAULT_COLS, &content, &[])
            .expect("spawn pager with content");
    harness
        .wait_for_text(WELCOME_SCREEN_SENTINEL, WELCOME_TIMEOUT)
        .expect("welcome text");

    harness
        .inject_keys(format!("{PROMPT}\r").as_bytes())
        .expect("submit prompt");
    harness
        .wait_for_text(MOCK_RESPONSE_SENTINEL, Duration::from_secs(30))
        .expect("mock response on screen");

    harness
        .wait_for_text("75% cached", Duration::from_secs(15))
        .unwrap_or_else(|e| {
            panic!(
                "cache hit rate never reached the status bar: {e}\n{}",
                harness.screen_contents()
            )
        });
    let screen = harness.screen_contents();
    assert!(
        screen.contains("\u{2191}2.0K \u{2193}120"),
        "input and output counts missing from the status bar:\n{screen}"
    );
    assert!(
        screen.contains("tok/s"),
        "output rate missing from the status bar:\n{screen}"
    );

    harness.quit().expect("clean quit");
}
