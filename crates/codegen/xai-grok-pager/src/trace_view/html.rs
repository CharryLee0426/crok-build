//! Self-contained, offline trace report. Trace contents are always data, never markup.

use super::data::TraceData;

/// Render a portable report with no network requests or external assets.
pub fn render(data: &TraceData) -> anyhow::Result<String> {
    let json = script_safe_json(data)?;
    // Insert the payload last: arbitrary trace strings must not participate in
    // template replacement (including strings that look like our markers).
    Ok(include_str!("trace.html")
        .replacen("/* TRACE_STYLES */", include_str!("trace.css"), 1)
        .replacen("/* TRACE_SCRIPT */", include_str!("trace.js"), 1)
        .replacen("<!-- TRACE_DATA -->", &json, 1))
}

fn script_safe_json(value: &impl serde::Serialize) -> anyhow::Result<String> {
    // application/json script elements still use the HTML raw-text tokenizer:
    // escaping `<` is essential to prevent an embedded `</script>` from closing
    // the element. Escape the other HTML-sensitive and JS separator characters
    // too, while preserving their original values after JSON.parse.
    Ok(serde_json::to_string(value)?
        .replace('&', "\\u0026")
        .replace('<', "\\u003c")
        .replace('>', "\\u003e")
        .replace('\u{2028}', "\\u2028")
        .replace('\u{2029}', "\\u2029"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hostile_trace_contents_cannot_close_the_data_element() {
        let original = serde_json::json!({
            "text": "</script><script>alert('trace')</script><!--&>\u{2028}\u{2029}",
            "nested": { "</ScRiPt>": "<img src=x onerror=alert(1)>" }
        });
        let serialized = script_safe_json(&original).unwrap();
        assert!(!serialized.contains(['<', '>', '&', '\u{2028}', '\u{2029}']));
        assert_eq!(
            serde_json::from_str::<serde_json::Value>(&serialized).unwrap(),
            original
        );
    }

    #[test]
    fn report_serializes_encrypted_reasoning_metadata() {
        let data: TraceData = serde_json::from_value(serde_json::json!({
            "schema_version": 1,
            "source": "local",
            "session_id": "encrypted-session",
            "title": "Encrypted reasoning",
            "model": null,
            "cwd": null,
            "created_at": null,
            "updated_at": null,
            "summary": {
                "event_count": 0, "turn_count": 0, "tool_count": 0, "error_count": 0,
                "duration_ms": null, "input_tokens": null, "output_tokens": null,
                "cached_input_tokens": null, "total_tokens": null
            },
            "events": [],
            "turns": [],
            "tools": [],
            "artifacts": [],
            "warnings": [],
            "transcript": [{
                "index": 0, "kind": "reasoning", "title": "Reasoning", "text": "unavailable",
                "turn": null, "start_ms": null, "end_ms": null, "wait_ms": null,
                "tool_call_id": null, "status": null, "encryption": "full", "event_indices": []
            }]
        }))
        .unwrap();
        let html = render(&data).unwrap();
        assert!(html.contains("\"encryption\":\"full\""));
        assert!(html.contains("id=\"detail-lock\""));
    }

    #[test]
    fn report_preserves_payload_and_does_not_interpret_template_markers() {
        let data: TraceData = serde_json::from_value(serde_json::json!({
            "schema_version": 1, "source": "local", "session_id": "test",
            "title": "<!-- TRACE_DATA --> /* TRACE_SCRIPT */ </script>",
            "model": null, "cwd": null, "created_at": null, "updated_at": null,
            "summary": {
                "event_count": 0, "turn_count": 0, "tool_count": 0, "error_count": 0,
                "duration_ms": null, "input_tokens": null, "output_tokens": null,
                "cached_input_tokens": null, "total_tokens": null
            },
            "events": [], "turns": [], "tools": [], "artifacts": [], "warnings": []
        }))
        .unwrap();
        let html = render(&data).unwrap();
        let payload = html
            .split("id=\"trace-data\">")
            .nth(1)
            .unwrap()
            .split("</script>")
            .next()
            .unwrap();
        let decoded: TraceData = serde_json::from_str(payload).unwrap();
        assert_eq!(decoded.title, data.title);
        assert!(!html.contains("<script src="));
        assert!(!html.contains("/* TRACE_STYLES */"));
    }
}
