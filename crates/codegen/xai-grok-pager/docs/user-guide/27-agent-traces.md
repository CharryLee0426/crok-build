# Agent trace explorer

Use `/trace` in a session, or `crok trace view` from a shell, to inspect how an
agent ran: its prompts and recorded reasoning, tool calls and results, turn
boundaries, failures, usage, and saved configuration. The terminal and HTML views
read the same local snapshot.

`/trace` opens the explorer over the current conversation (fullscreen mode only).
`r` takes a new snapshot of a session that is still running; `Esc` or `q` returns
to the conversation.

```sh
# Open a saved session in the terminal explorer.
crok trace view <session-id>

# Inspect a session directory or an exported trace bundle.
crok trace view ~/.crok/sessions/<encoded-cwd>/<session-id>
crok trace view ./session.tar.gz

# Generate a portable HTML report and open it in a browser.
crok trace view <session-id> --html --open
crok trace view ./session.tar.gz --format html -o trace.html

# Export the normalized data for your own analysis.
crok trace view ./updates.jsonl --format json -o trace.json
crok trace view <session-id> --format json -o -
```

`--format` accepts `tui` (default), `html`, and `json`. `--html` is shorthand
for `--format html`. Without `-o`, HTML and JSON files are saved in
`$CROK_HOME/trace-exports/` (normally `~/.crok/trace-exports/`). `--open` is
available for HTML files. Terminal inspection requires an interactive terminal;
use HTML or JSON in CI and redirected shells.

## Reading a trace

Both views open on the recorded transcript: the system prompt, user prompts and
injected context, reasoning, assistant replies, and tool calls with their results.
Streaming chunks, phase changes, and other lifecycle records are left out of this
list. Press `v` (or choose **All records** in HTML) to browse every raw record,
including those. Selecting a transcript entry shows its content, the tool input and
output for tool calls, and the raw records it was built from.

Above the list, the timeline has one lane each for **System**, **User**,
**Reasoning**, **Assistant**, and **Tools**, and each type has its own color. A bar
starts when the entry started and is as wide as its recorded execution time:

- A reasoning or assistant bar covers the model call that produced it. Its lighter
  leading part is the wait for the first token.
- A tool bar covers the tool's recorded execution time, excluding any wait for
  permission.
- Prompts and context are instants, drawn as thin markers.
- Parallel tool calls stack into extra rows of the Tools lane.
- Turn boundaries are marked. By default, idle time longer than two seconds
  between recorded activity (for example, while you read a reply) is removed and
  shown as a dashed line. Switch to **Wall clock** (`w` in the terminal) to plot
  real elapsed time.

Zoom with the scroll wheel, drag to pan, and double-click to reset in HTML. In the
terminal, use `+`, `-`, and `0`; the zoomed timeline follows the selected entry.
Click a bar to select its entry.

The artifacts view preserves available context such as the system prompt,
tool definitions, prompt context, session metadata, usage, and subagent metadata.
Inspecting this context helps explain what instructions and tools the model had
available. Subagent metadata describes recorded relationships; separate child
sessions can be opened by their own session ID.

In HTML, select an entry to open its inspector: tool entries have Input, Output, and
Raw tabs, and other entries have Content and Raw. **Session details** contains
usage, turn summaries, recording notes, and all saved files. Large traces are paged
without dropping records from search or export.

The page includes its data and assets, works offline, and adapts to narrow screens.
Its timeline and ledger follow
[DeepSeek Harness's trajectory viewer](https://github.com/deepseek-ai/deepseek-harness/tree/master/packages/client/ui-trajectory).
Press `/` to search, `j` / `k` or the arrow keys to inspect adjacent entries, `v` to
switch between the transcript and all records, `e` to find the next error, and
`Esc` to close the inspector or clear filters. Keyboard hints are available in both
views.

Terminal controls:

| Key | Action |
| --- | --- |
| `↑` / `↓`, `j` / `k` | Move in the focused pane |
| `Tab` / `Enter` | Switch between the list and details |
| `1`–`5` | Overview, detail, tool I/O, raw JSON, artifacts |
| `v` | Switch between the transcript and all raw records |
| `+` / `-` / `0` | Zoom the timeline in / out / reset |
| `w` | Switch the timeline between active time and wall clock |
| `/` | Search entry text, tool I/O, and raw fields |
| `f` | Cycle entry types |
| `t` | Filter to the selected turn |
| `[` / `]` | Previous / next turn |
| `e` | Jump to the next error |
| `J` / `K`, `PgUp` / `PgDn` | Scroll details / page through the focused pane |
| `Esc` | Clear search and filters; close when none are set |
| `r` | Take a new snapshot (`/trace` only) |
| `?` | Show help |
| `q` / `Ctrl-C` | Exit (`Ctrl-C` in `crok trace view` only) |

On narrow terminals, `Tab` switches between the two full-width panes. Terminals
shorter than 24 rows hide the timeline lanes.

## What the data can tell you

The viewer presents recorded information. It does not recover unrecorded model
reasoning, infer a hidden execution step, or treat a missing token count as zero.
The transcript file (`chat_history.jsonl`) has no timestamps, so entries are placed
using the event log (`events.jsonl`) and client updates (`updates.jsonl`): by turn
number, model-call order, and tool-call ID. An entry that cannot be matched stays
in the list and is not drawn on the timeline. When compaction has replaced the
transcript with a summary, the transcript is rebuilt from the client updates, which
omit context the harness injected before compaction.
Different streams can have different timestamp coverage. The report flags
missing timing, malformed records, incomplete data, and uncertain cross-stream
ordering. Stream order is retained where timestamps are unavailable. Duration
measurements come from recorded timestamps or duration fields, rather than the
position of a row in the timeline.

This is a snapshot, not a live tail. Reopen or regenerate the report to include
new events from a running session. The original records remain available for
inspection even when an event type is unfamiliar to the viewer.

The reader accepts up to 32 MiB per text file, 128 MiB of selected content,
256 MiB of decompressed archive data, and 100,000 events. Oversized files are
identified in recording notes; oversized archives or event collections produce
an error. Symlinks are skipped, archives are read without extraction, and binary
attachments remain references in the raw records. Compaction checkpoints appear
as historical artifacts rather than additional live events.

## Exporting and sharing

Viewing a trace does not authenticate, contact the model provider, or upload
session contents. Existing trace exports continue to work:

```sh
crok trace <session-id> --local -o session.tar.gz
crok trace <session-id> --local --json
```

HTML and JSON contain the recorded prompts, source code, tool arguments, output,
and other session data. Review the contents before sharing. New report files are
created with owner-only permissions on Unix. The viewer never executes recorded
tool calls or treats trace text as HTML.
