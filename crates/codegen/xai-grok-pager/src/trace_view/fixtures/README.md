These synthetic session records exercise the trace viewer without credentials or private conversation data. Their shapes follow the harness's `Summary`, `ConversationItem`, session event log, ACP update envelope, `SessionUsageFile`, and `SubagentMeta` formats.

The example contains a recorded reasoning message, a successful file read, a failed test followed by a successful retry, a permission decision, usage and context statistics, and a child-agent reference. The child session itself is intentionally absent so the viewer can explain that coverage gap.

From the repository root:

```sh
crok trace view crates/codegen/xai-grok-pager/src/trace_view/fixtures/session --format html --output /tmp/agent-trace.html
```
