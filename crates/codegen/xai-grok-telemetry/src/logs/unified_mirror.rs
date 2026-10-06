//! Mirrors `tracing` warnings and errors into the unified log.
//!
//! Most failure sites report through `tracing::warn!` / `tracing::error!` and nothing else. In the TUI those lines
//! scroll through the in-app log pane and are gone at exit; under `crok agent stdio` they go to a stderr of which the
//! desktop app keeps the last 16 KB. The mirror writes them to `unified.jsonl`, next to the request that failed, with
//! the callsite (`ctx.target`, `ctx.at`) that raised them.

use std::cell::Cell;
use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use tracing::callsite::Identifier;
use tracing::field::{Field, Visit};
use tracing::span::{Attributes, Id, Record};
use tracing::{Event, Level, Metadata, Subscriber};
use tracing_subscriber::filter::filter_fn;
use tracing_subscriber::layer::{Context, Layer};
use tracing_subscriber::registry::LookupSpan;

use crate::debug_log::RMCP_SSE_NOISE_TARGET;
use crate::session_ctx::SESSION_ID_FIELD;
use crate::unified_log::{self, LogLevel, LogSource};

/// A callsite gets this many entries per [`WINDOW`]; the rest are counted and reported on its next entry as
/// `ctx.suppressed`. A retry loop that warns on every attempt would otherwise push everything else out of a 5 MB log.
const MAX_PER_WINDOW: u32 = 10;
const WINDOW: Duration = Duration::from_secs(60);

/// Longest field value kept. Errors that embed a response body or a prompt are cut here.
const MAX_VALUE_BYTES: usize = 4096;

thread_local! {
    /// Set while this thread is inside [`MirrorLayer::on_event`], so an event raised by the write itself is dropped
    /// rather than mirrored again.
    static MIRRORING: Cell<bool> = const { Cell::new(false) };
}

/// The mirror layer. Add it to a registry once per process.
pub fn layer<S>() -> impl Layer<S>
where
    S: Subscriber + for<'span> LookupSpan<'span>,
{
    MirrorLayer {
        limiter: Mutex::new(Limiter::default()),
    }
    .with_filter(filter_fn(is_mirrored))
}

/// Warnings and errors, plus the spans that carry a session id (the entries are stamped with it).
/// Only those spans: passing every span would switch on trace-level spans nothing else asked for.
fn is_mirrored(meta: &Metadata<'_>) -> bool {
    if meta.is_span() {
        return meta.fields().field(SESSION_ID_FIELD).is_some();
    }
    let level = *meta.level();
    if level > Level::WARN {
        return false;
    }
    let target = meta.target();
    // The unified log reports its own failures through `tracing` while holding its writer lock. Mirroring those would
    // re-enter the writer on the same thread and deadlock.
    if target == unified_log::TRACING_TARGET {
        return false;
    }
    !(target == RMCP_SSE_NOISE_TARGET && level != Level::ERROR)
}

struct MirrorLayer {
    limiter: Mutex<Limiter<Identifier>>,
}

/// Per-key entry budget; the key is a callsite.
struct Limiter<K> {
    buckets: HashMap<K, Bucket>,
}

impl<K> Default for Limiter<K> {
    fn default() -> Self {
        Self {
            buckets: HashMap::new(),
        }
    }
}

struct Bucket {
    window_start: Instant,
    written: u32,
    suppressed: u32,
}

impl<K: std::hash::Hash + Eq> Limiter<K> {
    /// `Some(n)` to write the entry, `n` being how many of this key's entries were dropped since its last one.
    fn admit(&mut self, key: K, now: Instant) -> Option<u32> {
        let bucket = self.buckets.entry(key).or_insert(Bucket {
            window_start: now,
            written: 0,
            suppressed: 0,
        });
        if now.duration_since(bucket.window_start) >= WINDOW {
            bucket.window_start = now;
            bucket.written = 0;
        }
        if bucket.written >= MAX_PER_WINDOW {
            bucket.suppressed = bucket.suppressed.saturating_add(1);
            return None;
        }
        bucket.written += 1;
        Some(std::mem::take(&mut bucket.suppressed))
    }
}

/// The session a span belongs to, kept in its extensions so every event under it can be stamped.
struct MirrorSession(String);

impl<S> Layer<S> for MirrorLayer
where
    S: Subscriber + for<'span> LookupSpan<'span>,
{
    fn on_new_span(&self, attrs: &Attributes<'_>, id: &Id, ctx: Context<'_, S>) {
        let mut visitor = SessionIdVisitor(None);
        attrs.record(&mut visitor);
        if let (Some(session), Some(span)) = (visitor.0, ctx.span(id)) {
            span.extensions_mut().replace(MirrorSession(session));
        }
    }

    /// A span may declare `session_id` empty and fill it in once the session exists.
    fn on_record(&self, id: &Id, values: &Record<'_>, ctx: Context<'_, S>) {
        let mut visitor = SessionIdVisitor(None);
        values.record(&mut visitor);
        if let (Some(session), Some(span)) = (visitor.0, ctx.span(id)) {
            span.extensions_mut().replace(MirrorSession(session));
        }
    }

    fn on_event(&self, event: &Event<'_>, ctx: Context<'_, S>) {
        if MIRRORING.replace(true) {
            return;
        }
        let _reset = ResetMirroring;
        let meta = event.metadata();
        let admitted = self
            .limiter
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .admit(meta.callsite(), Instant::now());
        let Some(suppressed) = admitted else {
            return;
        };

        let mut visitor = FieldVisitor::default();
        event.record(&mut visitor);
        let session = ctx.event_scope(event).and_then(|mut scope| {
            scope.find_map(|span| {
                span.extensions()
                    .get::<MirrorSession>()
                    .map(|s| s.0.clone())
            })
        });

        let mut fields = visitor.fields;
        fields.insert("target".into(), meta.target().into());
        if let (Some(file), Some(line)) = (meta.file(), meta.line()) {
            fields.insert("at".into(), format!("{file}:{line}").into());
        }
        if suppressed > 0 {
            fields.insert("suppressed".into(), suppressed.into());
        }
        let src = if meta.target().starts_with("xai_grok_pager") {
            LogSource::GrokPager
        } else {
            LogSource::Shell
        };
        let lvl = if *meta.level() == Level::ERROR {
            LogLevel::Error
        } else {
            LogLevel::Warn
        };
        let msg = if visitor.message.is_empty() {
            meta.name()
        } else {
            visitor.message.as_str()
        };
        unified_log::emit_from(
            src,
            lvl,
            msg,
            session.as_deref(),
            Some(serde_json::Value::Object(fields)),
        );
    }
}

struct ResetMirroring;

impl Drop for ResetMirroring {
    fn drop(&mut self) {
        MIRRORING.set(false);
    }
}

struct SessionIdVisitor(Option<String>);

impl Visit for SessionIdVisitor {
    fn record_str(&mut self, field: &Field, value: &str) {
        if field.name() == SESSION_ID_FIELD {
            self.0 = Some(value.to_owned());
        }
    }

    fn record_debug(&mut self, field: &Field, value: &dyn std::fmt::Debug) {
        if field.name() == SESSION_ID_FIELD {
            self.0 = Some(format!("{value:?}"));
        }
    }
}

#[derive(Default)]
struct FieldVisitor {
    message: String,
    fields: serde_json::Map<String, serde_json::Value>,
}

impl FieldVisitor {
    fn text(&mut self, field: &Field, mut value: String) {
        if value.len() > MAX_VALUE_BYTES {
            value.truncate(value.floor_char_boundary(MAX_VALUE_BYTES));
            value.push('…');
        }
        if field.name() == "message" {
            self.message = value;
        } else {
            self.fields.insert(field.name().to_owned(), value.into());
        }
    }
}

impl Visit for FieldVisitor {
    fn record_str(&mut self, field: &Field, value: &str) {
        self.text(field, value.to_owned());
    }

    fn record_debug(&mut self, field: &Field, value: &dyn std::fmt::Debug) {
        self.text(field, format!("{value:?}"));
    }

    fn record_error(&mut self, field: &Field, value: &(dyn std::error::Error + 'static)) {
        // The whole chain: the outermost message alone is usually the least specific one.
        let mut text = value.to_string();
        let mut source = value.source();
        while let Some(cause) = source {
            text.push_str(": ");
            text.push_str(&cause.to_string());
            source = cause.source();
        }
        self.text(field, text);
    }

    fn record_i64(&mut self, field: &Field, value: i64) {
        self.fields.insert(field.name().to_owned(), value.into());
    }

    fn record_u64(&mut self, field: &Field, value: u64) {
        self.fields.insert(field.name().to_owned(), value.into());
    }

    fn record_bool(&mut self, field: &Field, value: bool) {
        self.fields.insert(field.name().to_owned(), value.into());
    }

    fn record_f64(&mut self, field: &Field, value: f64) {
        self.fields.insert(field.name().to_owned(), value.into());
    }
}

#[cfg(test)]
mod tests {
    use tracing_subscriber::layer::SubscriberExt as _;

    use super::*;

    /// Entries the mirror wrote whose message is `msg`. The log is shared by every test in this binary, so each test
    /// uses messages of its own.
    fn entries(msg: &str) -> Vec<serde_json::Value> {
        let log = unified_log::snapshot_log().unwrap_or_default();
        String::from_utf8_lossy(&log)
            .lines()
            .filter_map(|line| serde_json::from_str::<serde_json::Value>(line).ok())
            .filter(|entry| entry["msg"] == msg)
            .collect()
    }

    fn with_mirror(f: impl FnOnce()) {
        tracing::subscriber::with_default(tracing_subscriber::registry().with(layer()), f);
    }

    #[test]
    fn warnings_and_errors_are_written_with_their_callsite_and_fields() {
        with_mirror(|| {
            tracing::error!(attempt = 3, reason = %"disk full", "mirror probe: save failed");
            tracing::warn!("mirror probe: slow write");
            tracing::info!("mirror probe: not mirrored");
        });

        let errors = entries("mirror probe: save failed");
        assert_eq!(errors.len(), 1, "{errors:?}");
        let entry = &errors[0];
        assert_eq!(entry["lvl"], "error");
        assert_eq!(entry["src"], "shell");
        assert_eq!(entry["ctx"]["attempt"], 3);
        assert_eq!(entry["ctx"]["reason"], "disk full");
        assert_eq!(entry["ctx"]["target"], module_path!());
        assert!(
            entry["ctx"]["at"]
                .as_str()
                .is_some_and(|at| at.contains("unified_mirror.rs:")),
            "{entry}"
        );

        assert_eq!(entries("mirror probe: slow write")[0]["lvl"], "warn");
        assert!(entries("mirror probe: not mirrored").is_empty());
    }

    #[test]
    fn events_under_a_session_span_carry_its_id() {
        with_mirror(|| {
            let span = tracing::info_span!("session", session_id = %"mirror-sid-1");
            let _entered = span.enter();
            tracing::warn!("mirror probe: inside session");
        });
        with_mirror(|| tracing::warn!("mirror probe: outside session"));

        assert_eq!(
            entries("mirror probe: inside session")[0]["sid"],
            "mirror-sid-1"
        );
        assert!(entries("mirror probe: outside session")[0]["sid"].is_null());
    }

    #[test]
    fn a_flooding_callsite_is_capped_and_the_drop_count_reported() {
        let mut limiter = Limiter::default();
        let start = Instant::now();
        for _ in 0..MAX_PER_WINDOW {
            assert_eq!(limiter.admit("retry loop", start), Some(0));
        }
        assert_eq!(limiter.admit("retry loop", start), None);
        assert_eq!(limiter.admit("retry loop", start), None);
        // Another callsite has a budget of its own.
        assert_eq!(limiter.admit("other", start), Some(0));

        // The next window opens with the two that were dropped.
        assert_eq!(limiter.admit("retry loop", start + WINDOW), Some(2));
        assert_eq!(limiter.admit("retry loop", start + WINDOW), Some(0));
    }

    #[test]
    fn a_flood_of_events_writes_only_the_budget() {
        with_mirror(|| {
            for _ in 0..MAX_PER_WINDOW + 5 {
                tracing::warn!("mirror probe: flood");
            }
        });
        assert_eq!(
            entries("mirror probe: flood").len(),
            MAX_PER_WINDOW as usize
        );
    }

    #[test]
    fn the_unified_logs_own_warnings_are_not_mirrored() {
        with_mirror(|| {
            tracing::warn!(target: unified_log::TRACING_TARGET, "mirror probe: own warning");
        });
        assert!(entries("mirror probe: own warning").is_empty());
    }

    #[test]
    fn long_values_are_cut() {
        let long = "é".repeat(MAX_VALUE_BYTES);
        with_mirror(|| tracing::warn!(body = %long, "mirror probe: long value"));
        let entry = &entries("mirror probe: long value")[0];
        let body = entry["ctx"]["body"].as_str().unwrap();
        assert!(
            body.len() <= MAX_VALUE_BYTES + '…'.len_utf8(),
            "{}",
            body.len()
        );
        assert!(body.ends_with('…'));
    }
}
