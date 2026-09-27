/* Self-contained trace viewer. Recorded values are text, never executable HTML. */
"use strict";
(() => {
  const $ = id => document.getElementById(id);
  const sourceJson = $("trace-data").textContent;
  const data = JSON.parse(sourceJson);
  const events = data.events.filter(event => event.kind !== "artifact");
  const transcript = data.transcript || [];
  const PAGE_SIZE = 80;
  const TURN_PAGE_SIZE = 30;
  const LANES = [["system", "System"], ["user", "User"], ["reasoning", "Reasoning"], ["assistant", "Assistant"], ["tool", "Tools"]];
  const KIND_LABELS = { system: "System", user: "User", reasoning: "Reasoning", assistant: "Assistant", tool: "Tool" };
  const WAIT_COLORS = { reasoning: "var(--reasoning-wait)", assistant: "var(--assistant-wait)" };
  const ROW_HEIGHT = 14;
  const MAX_TOOL_ROWS = 4;
  const IDLE_GAP_MS = 2000;
  const narrowLayout = window.matchMedia("(max-width: 720px)");
  const state = {
    view: transcript.length ? "transcript" : "records",
    matches: [], selected: null, page: 0, turnPage: 0, tab: "content", sessionReady: false,
    scale: "active", viewport: null
  };
  const eventsByIndex = new Map(events.map(event => [event.index, event]));
  const entriesByIndex = new Map(transcript.map(entry => [entry.index, entry]));
  const entryByEvent = new Map();
  for (const entry of transcript) for (const index of entry.event_indices) if (!entryByEvent.has(index)) entryByEvent.set(index, entry.index);
  const toolsByEvent = new Map();
  const toolsById = new Map();
  for (const tool of data.tools) {
    const sameId = toolsById.get(tool.id) || [];
    sameId.push(tool);
    toolsById.set(tool.id, sameId);
    for (const index of tool.event_indices) {
      const linked = toolsByEvent.get(index) || [];
      linked.push(tool);
      toolsByEvent.set(index, linked);
    }
  }
  const number = value => value == null ? "—" : Number(value).toLocaleString();
  const countLabel = (value, label, plural = `${label}s`) => `${number(value)} ${value === 1 ? label : plural}`;
  const present = value => value != null && value !== "";
  const human = value => String(value || "unknown").replace(/[_-]/g, " ");
  const json = value => JSON.stringify(value, null, 2);
  const isEventError = event => /error|fail/i.test(event.kind) || /error|fail/i.test(event.status || "");
  const isEntryError = entry => /error|fail|cancel|reject|denied|invalid/i.test(entry.status || "");
  const entryEnd = entry => entry.end_ms == null ? entry.start_ms : Math.max(entry.start_ms, entry.end_ms);
  const entryDuration = entry => entry.start_ms != null && entry.end_ms != null ? Math.max(0, entry.end_ms - entry.start_ms) : null;
  const usageArtifact = data.artifacts.filter(artifact => /(^|\/)usage\.json$/.test(artifact.name))
    .sort((a, b) => a.name.split("/").length - b.name.split("/").length || a.name.length - b.name.length)[0];
  const usage = usageArtifact && typeof usageArtifact.content === "object" ? usageArtifact.content : null;
  const turnUsage = new Map((usage && Array.isArray(usage.turns) ? usage.turns : []).map(turn => [turn.turnNumber, turn]));
  const cost = row => {
    if (!row || !(row.costUsdTicks > 0)) return "—";
    const amount = row.costUsdTicks / 1e10;
    return `${row.costIsPartial ? "≥ " : ""}$${amount.toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: amount < 0.01 ? 6 : 4 })}`;
  };
  const duration = value => {
    if (value == null) return "—";
    if (value < 1000) return `${number(Math.round(value))} ms`;
    if (value < 60000) return `${(value / 1000).toFixed(value < 10000 ? 2 : 1)} s`;
    if (value < 3600000) return `${Math.floor(value / 60000)}m ${Math.floor(value % 60000 / 1000)}s`;
    return `${Math.floor(value / 3600000)}h ${Math.floor(value % 3600000 / 60000)}m`;
  };
  const date = value => {
    if (!present(value)) return "—";
    const parsed = new Date(value);
    return Number.isNaN(parsed.valueOf()) ? value : parsed.toLocaleString(undefined, { dateStyle: "medium", timeStyle: "medium" });
  };
  const time = value => {
    const parsed = new Date(value);
    return Number.isNaN(parsed.valueOf()) ? String(value) : parsed.toLocaleTimeString(undefined, { hour12: false });
  };
  const clock = value => new Date(value).toLocaleTimeString(undefined, { hour12: false, hour: "2-digit", minute: "2-digit", second: "2-digit", fractionalSecondDigits: 3 });
  const category = event => {
    if (isEventError(event)) return "error";
    if (/reason|thinking|analysis/.test(event.kind)) return "reasoning";
    if (/tool.*(result|complet|update)|^tool$/.test(event.kind)) return "result";
    if (/tool|permission|command/.test(event.kind)) return "tool";
    if (/user/.test(event.kind)) return "user";
    if (/assistant|message/.test(event.kind)) return "assistant";
    return "system";
  };
  function node(tag, className, text) {
    const element = document.createElement(tag);
    if (className) element.className = className;
    if (text != null) element.textContent = String(text);
    return element;
  }
  function button(label, className, action) {
    const element = node("button", className, label);
    element.type = "button";
    element.addEventListener("click", action);
    return element;
  }
  /* Rust classifies reasoning before export. A readable copy of the summary is "none". */
  function encryptionOf(item) {
    const value = item && item.encryption;
    return value === "partial" || value === "full" ? value : "none";
  }
  function encryptionPhrase(level) {
    return level === "partial"
      ? "Encrypted reasoning; the text shown is a summary"
      : "Encrypted reasoning; readable contents are unavailable";
  }
  function encryptedBadge(level) {
    const badge = node("span", "encrypted-badge");
    badge.append(node("span", "encrypted-glyph", "🔒"), node("span", "", level === "partial" ? "Summary" : "Encrypted"));
    badge.setAttribute("aria-label", encryptionPhrase(level));
    return badge;
  }
  function encryptedNotice(level) {
    return node("p", "encrypted-note", level === "partial"
      ? "🔒 This is a readable summary. The full reasoning was recorded only in encrypted form."
      : "🔒 Encrypted reasoning was recorded; its readable contents are unavailable.");
  }
  function isEncrypted(item) {
    return encryptionOf(item) !== "none";
  }
  function encryptedLock(level, select) {
    const lock = button("", "encrypted-lock", event => {
      event.stopPropagation();
      select();
      announce(encryptionPhrase(level) + ".");
    });
    lock.setAttribute("aria-label", encryptionPhrase(level));
    lock.title = encryptionPhrase(level);
    lock.append(node("span", "encrypted-glyph", "🔒"));
    return lock;
  }
  function metadata(target, entries) {
    for (const [label, value, mono] of entries) {
      target.append(node("dt", "", label), node("dd", mono ? "mono" : "", present(value) ? value : "—"));
    }
  }
  function code(value) {
    const element = node("pre", "json-block");
    element.append(node("code", "", typeof value === "string" ? value : json(value)));
    return element;
  }
  let toastTimer;
  function announce(message) {
    $("announcement").textContent = message;
    $("announcement").hidden = false;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => { $("announcement").hidden = true; }, 3500);
  }
  function download(value, filename, alreadySerialized = false) {
    const url = URL.createObjectURL(new Blob([alreadySerialized ? value : json(value)], { type: "application/json;charset=utf-8" }));
    const link = node("a");
    link.href = url;
    link.download = filename;
    document.body.append(link);
    link.click();
    link.remove();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  }
  function eventPayload(event) {
    const raw = event.raw;
    return raw && (raw.params && raw.params.update || raw.update || raw);
  }
  function entryRaw(entry) {
    return entry.event_indices.map(index => eventsByIndex.get(index)).filter(Boolean).map(event => event.raw);
  }
  function entryTools(entry) {
    return entry.tool_call_id ? toolsById.get(entry.tool_call_id) || [] : [];
  }
  /* Assistant replies made only of tool calls list the tools they requested. */
  function requestedTools(entry) {
    const names = [];
    for (const index of entry.event_indices) {
      const payload = eventsByIndex.has(index) ? eventPayload(eventsByIndex.get(index)) : null;
      const calls = payload && Array.isArray(payload.tool_calls) ? payload.tool_calls : [];
      for (const call of calls) names.push((call.function || call).name || "tool");
    }
    return names;
  }

  /* ---- Views: the transcript and every raw record share one ledger. ---- */
  const searchCache = new Map();
  let searchCacheBytes = 0;
  function cachedSearch(key, build) {
    if (searchCache.has(key)) return searchCache.get(key);
    const text = build().toLocaleLowerCase();
    if (searchCacheBytes + text.length * 2 <= 8 * 1024 * 1024) {
      searchCache.set(key, text);
      searchCacheBytes += text.length * 2;
    }
    return text;
  }
  const VIEWS = {
    transcript: {
      items: transcript,
      byIndex: entriesByIndex,
      noun: ["entry", "entries"],
      kinds: () => LANES.filter(([kind]) => transcript.some(entry => entry.kind === kind)).map(([kind]) => [kind, KIND_LABELS[kind]]),
      kindOf: entry => entry.kind,
      isError: isEntryError,
      isEncrypted,
      summary: entry => `${entry.title}\n${entry.text}\n${entry.kind}\n${entry.tool_call_id || ""}\n${entry.status || ""}\n${isEncrypted(entry) ? "encrypted reasoning" : ""}`,
      deep: entry => cachedSearch(`t${entry.index}`, () => JSON.stringify([entryTools(entry).map(tool => [tool.input, tool.output]), entryRaw(entry)])),
      boundary: entry => entry.turn == null ? "Session" : `Turn ${entry.turn}`,
      row: transcriptRow,
      inspect: renderEntryInspector
    },
    records: {
      items: events,
      byIndex: eventsByIndex,
      noun: ["record", "records"],
      kinds: () => [...new Set(events.map(event => event.kind))].sort().map(kind => [kind, human(kind)]),
      kindOf: event => event.kind,
      isError: isEventError,
      isEncrypted,
      summary: event => `${event.title}\n${event.text}\n${event.kind}\n${event.source}\n${event.tool_call_id || ""}\n${event.status || ""}\n${event.timestamp || ""}\n${isEncrypted(event) ? "encrypted reasoning" : ""}`,
      deep: event => cachedSearch(`r${event.index}`, () => JSON.stringify(event.raw)),
      boundary: event => {
        if (!event.timestamp) return `Recorded transcript · ${event.source}${event.turn == null ? "" : ` · Turn ${event.turn}`}`;
        return event.turn == null ? "Session events" : `Turn ${event.turn}`;
      },
      row: recordRow,
      inspect: renderRecordInspector
    }
  };
  const view = () => VIEWS[state.view];

  function renderHeader() {
    document.title = `${data.title || "Agent trace"} · Grok Build`;
    $("session-title").textContent = data.title || "Agent trace";
    $("session-subtitle").textContent = [data.model, data.session_id].filter(present).join(" · ");
    const turns = new Set(transcript.map(entry => entry.turn).filter(turn => turn != null));
    const stats = transcript.length
      ? [countLabel(transcript.length, "entry", "entries"), countLabel(turns.size || data.turns.length, "turn"), countLabel(transcript.filter(entry => entry.kind === "tool").length, "tool call")]
      : [countLabel(events.length, "record"), countLabel(data.turns.length, "turn"), countLabel(data.tools.length, "tool")];
    if (timeline.active != null) stats.push(`${duration(timeline.active)} active`);
    if (data.summary.duration_ms != null) stats.push(`${duration(data.summary.duration_ms)} recorded`);
    if (data.summary.total_tokens != null) stats.push(`${number(data.summary.total_tokens)} tokens`);
    const errors = view().items.filter(view().isError).length;
    if (errors) stats.push(countLabel(errors, "error"));
    $("session-stats").textContent = stats.join(" · ");
    $("next-error").disabled = !errors;
    $("next-error").title = errors ? `${number(errors)} recorded errors · E` : "No recorded errors";
  }

  /* ---- Timeline: one lane per transcript type, width is recorded execution time. ---- */
  const timeline = buildTimeline();
  function buildTimeline() {
    const spans = transcript.filter(entry => entry.start_ms != null).map(entry => ({
      entry, start: entry.start_ms, end: entryEnd(entry), open: entry.end_ms == null
    }));
    // Parallel tool calls stack into sub-rows so no call hides another.
    const rowEnds = [];
    for (const span of spans.filter(span => span.entry.kind === "tool").sort((a, b) => a.start - b.start || a.end - b.end)) {
      let row = rowEnds.findIndex(end => end <= span.start);
      if (row < 0) row = rowEnds.length < MAX_TOOL_ROWS ? rowEnds.length : rowEnds.indexOf(Math.min(...rowEnds));
      rowEnds[row] = Math.max(rowEnds[row] ?? -Infinity, span.end);
      span.row = row;
    }
    const lanes = [];
    let top = 2;
    for (const [kind, label] of LANES) {
      const rows = kind === "tool" ? Math.max(1, rowEnds.length) : 1;
      lanes.push({ kind, label, top, rows });
      top += rows * ROW_HEIGHT;
    }
    const laneOf = new Map(lanes.map(lane => [lane.kind, lane]));
    for (const span of spans) span.top = laneOf.get(span.entry.kind).top + (span.row || 0) * ROW_HEIGHT + 2;
    // Active time is the union of recorded activity.
    const intervals = spans.map(span => [span.start, span.end]).sort((a, b) => a[0] - b[0]);
    const covered = [];
    for (const [start, end] of intervals) {
      const last = covered[covered.length - 1];
      if (last && start <= last[1]) last[1] = Math.max(last[1], end);
      else covered.push([start, end]);
    }
    const active = covered.length ? covered.reduce((sum, [start, end]) => sum + end - start, 0) : null;
    const turnStarts = new Map();
    for (const span of spans) {
      const turn = span.entry.turn;
      if (turn == null) continue;
      const prompt = span.entry.kind === "user" && span.entry.title === "Prompt";
      const current = turnStarts.get(turn);
      if (!current || (prompt && !current.prompt) || (prompt === current.prompt && span.start < current.time)) turnStarts.set(turn, { time: span.start, prompt });
    }
    return { spans, lanes, height: top + 2, covered, active, turnStarts, origin: covered.length ? covered[0][0] : 0 };
  }
  /* Map recorded time to plotted time. Active time shrinks idle gaps to a sliver. */
  function projection(scale) {
    const origin = timeline.origin;
    const gaps = [];
    if (scale === "active") {
      const keep = Math.min(IDLE_GAP_MS, Math.max(20, (timeline.active || 0) * 0.006));
      let removed = 0;
      for (let index = 1; index < timeline.covered.length; index += 1) {
        const start = timeline.covered[index - 1][1];
        const end = timeline.covered[index][0];
        if (end - start <= IDLE_GAP_MS) continue;
        gaps.push({ start, end, before: removed, keep });
        removed += end - start - keep;
      }
    }
    const project = value => {
      let low = 0;
      let high = gaps.length - 1;
      let gap = null;
      while (low <= high) {
        const middle = (low + high) >> 1;
        if (gaps[middle].start < value) { gap = gaps[middle]; low = middle + 1; } else high = middle - 1;
      }
      if (!gap) return value - origin;
      if (value >= gap.end) return value - origin - gap.before - (gap.end - gap.start - gap.keep);
      return gap.start - origin - gap.before + (value - gap.start) * gap.keep / (gap.end - gap.start);
    };
    const end = timeline.covered.length ? project(timeline.covered[timeline.covered.length - 1][1]) : 0;
    return { project, gaps, end: Math.max(1, end) };
  }
  let plot = null;
  const spanElements = new Map();
  function renderTimeline() {
    const labels = $("lane-labels");
    const track = $("timeline-track");
    const domain = $("timeline-domain");
    labels.replaceChildren();
    domain.replaceChildren();
    spanElements.clear();
    track.style.height = labels.style.height = `${timeline.height}px`;
    for (const lane of timeline.lanes) {
      const label = node("span", "", lane.label);
      label.style.setProperty("--lane", `var(--${lane.kind})`);
      label.style.top = `${lane.top}px`;
      label.style.height = `${lane.rows * ROW_HEIGHT}px`;
      labels.append(label);
      if (lane.top > 2) {
        const divider = node("div", "lane-divider");
        divider.style.top = `${lane.top}px`;
        domain.append(divider);
      }
    }
    for (const empty of track.querySelectorAll(".timeline-empty")) empty.remove();
    if (!timeline.spans.length) {
      track.append(node("div", "timeline-empty", transcript.length ? "No transcript timing was recorded" : "No transcript was recorded"));
      $("timeline-axis").replaceChildren();
      $("timeline-note").textContent = "";
      for (const id of ["scale-active", "scale-wall"]) $(id).disabled = true;
      return;
    }
    plot = projection(state.scale);
    const percent = value => `${value / plot.end * 100}%`;
    const fragment = document.createDocumentFragment();
    for (const gap of plot.gaps) {
      const line = node("div", "idle-break");
      line.style.left = percent(plot.project(gap.start) + gap.keep / 2);
      fragment.append(line);
    }
    for (const [turn, start] of timeline.turnStarts) {
      const line = node("div", "turn-line");
      line.style.left = percent(plot.project(start.time));
      line.append(node("span", "", `T${turn}`));
      fragment.append(line);
    }
    for (const span of timeline.spans) {
      const start = plot.project(span.start);
      const width = Math.max(0, plot.project(span.end) - start);
      const element = node("button", "span");
      element.type = "button";
      element.tabIndex = -1;
      element.dataset.entry = String(span.entry.index);
      element.setAttribute("aria-label", `${KIND_LABELS[span.entry.kind]}: ${span.entry.title}${isEncrypted(span.entry) ? `, ${encryptionPhrase(encryptionOf(span.entry))}` : ""}`);
      element.style.setProperty("--color", `var(--${span.entry.kind})`);
      element.style.left = percent(start);
      element.style.width = percent(width);
      element.style.top = `${span.top}px`;
      if (span.open || span.start === span.end) element.classList.add("marker");
      if (isEntryError(span.entry)) element.classList.add("error");
      const total = span.end - span.start;
      if (span.entry.wait_ms != null && total > 0 && WAIT_COLORS[span.entry.kind]) {
        element.classList.add("timed-wait");
        element.style.setProperty("--wait-color", WAIT_COLORS[span.entry.kind]);
        element.style.setProperty("--wait", `${Math.min(100, span.entry.wait_ms / total * 100)}%`);
      }
      spanElements.set(span.entry.index, element);
      fragment.append(element);
    }
    domain.append(fragment);
    const notes = [];
    if (state.scale === "active" && plot.gaps.length) notes.push(`${countLabel(plot.gaps.length, "idle gap")} removed (dashed)`);
    const untimed = transcript.length - timeline.spans.length;
    if (untimed) notes.push(`${number(untimed)} untimed`);
    $("timeline-note").textContent = notes.join(" · ");
    applyViewport();
    syncTimelineSelection();
    dimTimeline();
  }
  function applyViewport() {
    if (!plot) return;
    const [start, end] = state.viewport || [0, plot.end];
    const span = Math.max(1e-6, end - start);
    const domain = $("timeline-domain");
    domain.style.left = `${-start / span * 100}%`;
    domain.style.width = `${plot.end / span * 100}%`;
    $("zoom-reset").hidden = !state.viewport;
    $("timeline-track").classList.toggle("zoomed", Boolean(state.viewport));
    renderAxis(start, end);
  }
  function renderAxis(start, end) {
    const axis = $("timeline-axis");
    axis.replaceChildren();
    const width = axis.clientWidth || 600;
    const steps = [1, 2, 5, 10, 20, 50, 100, 200, 500, 1e3, 2e3, 5e3, 1e4, 15e3, 3e4, 6e4, 12e4, 3e5, 6e5, 9e5, 18e5, 36e5, 72e5, 144e5, 288e5, 864e5];
    const step = steps.find(value => (end - start) / value <= width / 84) || steps[steps.length - 1];
    for (let value = Math.ceil(start / step) * step; value <= end; value += step) {
      const label = node("span", value === 0 ? "first" : "", axisLabel(value));
      label.style.left = `${(value - start) / (end - start) * 100}%`;
      axis.append(label);
    }
  }
  function axisLabel(value) {
    if (value === 0) return "0";
    if (value < 1000) return `${Math.round(value)}ms`;
    const seconds = Math.round(value / 100) / 10;
    if (seconds < 60) return `${seconds}s`;
    const minutes = Math.floor(seconds / 60);
    const rest = Math.round(seconds % 60);
    if (minutes < 60) return rest ? `${minutes}m${rest}s` : `${minutes}m`;
    return minutes % 60 ? `${Math.floor(minutes / 60)}h${minutes % 60}m` : `${minutes / 60}h`;
  }
  function setViewport(start, end) {
    if (!plot) return;
    const minimum = Math.min(plot.end, Math.max(5, plot.end / 20000));
    let span = Math.max(minimum, end - start);
    if (span >= plot.end * 0.999) {
      state.viewport = null;
    } else {
      start = Math.min(Math.max(0, start), plot.end - span);
      state.viewport = [start, start + span];
    }
    applyViewport();
  }
  function zoom(factor, anchor = 0.5) {
    if (!plot) return;
    const [start, end] = state.viewport || [0, plot.end];
    const center = start + (end - start) * anchor;
    const span = (end - start) * factor;
    setViewport(center - span * anchor, center - span * anchor + span);
  }
  function revealInTimeline(entry) {
    if (!plot || !state.viewport || entry.start_ms == null) return;
    const [start, end] = state.viewport;
    const from = plot.project(entry.start_ms);
    const to = plot.project(entryEnd(entry));
    if (to >= start && from <= end) return;
    const span = end - start;
    setViewport(from - span * 0.2, from - span * 0.2 + span);
  }
  function syncTimelineSelection() {
    for (const element of spanElements.values()) element.removeAttribute("aria-pressed");
    if (state.view !== "transcript" || state.selected == null) return;
    const element = spanElements.get(state.selected);
    if (element) element.setAttribute("aria-pressed", "true");
  }
  function dimTimeline() {
    const filtering = state.view === "transcript" && state.matches.length !== transcript.length;
    const visible = filtering ? new Set(state.matches.map(entry => entry.index)) : null;
    for (const [index, element] of spanElements) element.classList.toggle("dim", Boolean(visible && !visible.has(index)));
  }
  function tooltipText(entry) {
    const lines = [entry.title === KIND_LABELS[entry.kind] ? entry.title : `${KIND_LABELS[entry.kind]} · ${entry.title}`];
    const preview = entry.kind === "tool" || entry.kind === "user" || entry.kind === "system" ? entry.text : "";
    if (preview) lines.push(preview.replace(/\s+/g, " ").slice(0, 160));
    if (entry.start_ms != null) lines.push(entry.end_ms == null ? `Started ${clock(entry.start_ms)} · no completion recorded` : `${clock(entry.start_ms)} → ${clock(entry.end_ms)}`);
    const facts = [];
    const total = entryDuration(entry);
    if (total != null && total > 0) facts.push(`Total ${duration(total)}`);
    if (entry.wait_ms != null) facts.push(`First token after ${duration(entry.wait_ms)}`);
    if (isEncrypted(entry)) facts.push(encryptionOf(entry) === "partial" ? "Summary of encrypted reasoning" : "Encrypted reasoning");
    if (entry.status) facts.push(entry.status);
    if (facts.length) lines.push(facts.join(" · "));
    return lines;
  }
  function showTooltip(entry, x, y) {
    const tip = $("timeline-tooltip");
    const [heading, ...rest] = tooltipText(entry);
    tip.replaceChildren(node("strong", "", heading), document.createTextNode(rest.join("\n")));
    tip.hidden = false;
    const box = tip.getBoundingClientRect();
    tip.style.left = `${Math.max(8, Math.min(x + 12, window.innerWidth - box.width - 8))}px`;
    tip.style.top = `${y + 18 + box.height > window.innerHeight ? y - box.height - 10 : y + 18}px`;
  }
  const hideTooltip = () => { $("timeline-tooltip").hidden = true; };
  function bindTimeline() {
    const track = $("timeline-track");
    let drag = null;
    track.addEventListener("wheel", event => {
      if (!plot) return;
      event.preventDefault();
      const rect = track.getBoundingClientRect();
      const anchor = Math.min(1, Math.max(0, (event.clientX - rect.left) / Math.max(1, rect.width)));
      const delta = event.deltaMode === 1 ? event.deltaY * 16 : event.deltaY;
      zoom(Math.exp(delta * 0.0015), anchor);
    }, { passive: false });
    track.addEventListener("pointerdown", event => {
      if (event.button !== 0 || !plot) return;
      const span = event.target.closest(".span");
      drag = { x: event.clientX, viewport: state.viewport, moved: false, entry: span ? Number(span.dataset.entry) : null, id: event.pointerId };
      track.setPointerCapture(event.pointerId);
    });
    track.addEventListener("pointermove", event => {
      if (drag && drag.id === event.pointerId) {
        const dx = event.clientX - drag.x;
        if (Math.abs(dx) > 3) drag.moved = true;
        if (drag.moved && drag.viewport) {
          hideTooltip();
          track.classList.add("panning");
          const [start, end] = drag.viewport;
          const shift = -dx / Math.max(1, track.clientWidth) * (end - start);
          setViewport(start + shift, end + shift);
        }
        return;
      }
      const span = document.elementFromPoint(event.clientX, event.clientY);
      const target = span && span.closest ? span.closest("#timeline-track .span") : null;
      if (target) showTooltip(entriesByIndex.get(Number(target.dataset.entry)), event.clientX, event.clientY);
      else hideTooltip();
    });
    const release = event => {
      if (!drag || drag.id !== event.pointerId) return;
      track.classList.remove("panning");
      if (!drag.moved && drag.entry != null) selectEntryFromTimeline(drag.entry);
      drag = null;
    };
    track.addEventListener("pointerup", release);
    track.addEventListener("pointercancel", () => { drag = null; track.classList.remove("panning"); });
    track.addEventListener("pointerleave", hideTooltip);
    track.addEventListener("dblclick", () => setViewport(0, Infinity));
    $("zoom-reset").addEventListener("click", () => setViewport(0, Infinity));
    for (const scale of ["active", "wall"]) {
      $(`scale-${scale}`).addEventListener("click", () => {
        if (state.scale === scale) return;
        state.scale = scale;
        state.viewport = null;
        $("scale-active").setAttribute("aria-pressed", String(scale === "active"));
        $("scale-wall").setAttribute("aria-pressed", String(scale === "wall"));
        renderTimeline();
      });
    }
    window.addEventListener("resize", () => applyViewport());
  }
  function selectEntryFromTimeline(index) {
    if (state.view !== "transcript") switchView("transcript", false);
    selectItem(index, true);
  }

  /* ---- Ledger ---- */
  function initializeFilters() {
    const kind = $("kind");
    kind.replaceChildren(node("option", "", state.view === "transcript" ? "All types" : "All records"));
    kind.firstChild.value = "";
    for (const [value, label] of view().kinds()) {
      const option = node("option", "", label);
      option.value = value;
      kind.append(option);
    }
    const turn = $("turn");
    turn.replaceChildren(node("option", "", "All turns"));
    turn.firstChild.value = "";
    const items = view().items;
    for (const value of [...new Set(items.filter(item => item.turn != null).map(item => item.turn))].sort((a, b) => a - b)) {
      const option = node("option", "", `Turn ${value}`);
      option.value = String(value);
      turn.append(option);
    }
    if (items.some(item => item.turn == null)) {
      const option = node("option", "", state.view === "transcript" ? "Session" : "Unassigned");
      option.value = "none";
      turn.append(option);
    }
    const source = $("source-filter");
    source.replaceChildren(node("option", "", "All sources"));
    source.firstChild.value = "";
    const sources = new Map();
    for (const event of events) sources.set(event.source, (sources.get(event.source) || 0) + 1);
    for (const [name, count] of [...sources].sort(([a], [b]) => a.localeCompare(b))) {
      const option = node("option", "", `${name} (${number(count)})`);
      option.value = name;
      source.append(option);
    }
    $("source-filter-label").hidden = state.view !== "records";
    $("search").placeholder = state.view === "transcript" ? "Search transcript…" : "Search records…";
  }
  function applyFilters(keepSelection = false) {
    const query = $("search").value.trim().toLocaleLowerCase();
    const kind = $("kind").value;
    const turn = $("turn").value;
    const source = state.view === "records" ? $("source-filter").value : "";
    const current = view();
    state.matches = current.items.filter(item => {
      if (kind && current.kindOf(item) !== kind) return false;
      if (source && item.source !== source) return false;
      if (turn === "none" ? item.turn != null : turn && String(item.turn) !== turn) return false;
      if (!query) return true;
      return current.summary(item).toLocaleLowerCase().includes(query) || current.deep(item).includes(query);
    });
    state.page = 0;
    if (!state.matches.some(item => item.index === state.selected)) closeInspector(false);
    else if (keepSelection) state.page = Math.floor(state.matches.findIndex(item => item.index === state.selected) / PAGE_SIZE);
    $("reset-filters").hidden = !(query || kind || turn || source);
    $("filters-toggle").classList.toggle("active", Boolean(turn || source));
    renderLedger();
    dimTimeline();
    if (!keepSelection) $("event-list").scrollTop = 0;
  }
  function clearFilters() {
    for (const name of ["search", "kind", "turn", "source-filter"]) $(name).value = "";
    applyFilters();
  }
  function pagination(target, page, total, size, action) {
    target.replaceChildren();
    const noun = view().noun;
    target.append(node("span", "pagination-info", total ? `${number(page * size + 1)}–${number(Math.min((page + 1) * size, total))} of ${number(total)}` : `0 ${noun[1]}`));
    if (total <= size) return;
    const actions = node("div", "pagination-actions");
    const previous = button("Previous", "", () => action(page - 1));
    previous.disabled = page === 0;
    const next = button("Next", "", () => action(page + 1));
    next.disabled = (page + 1) * size >= total;
    actions.append(previous, next);
    target.append(actions);
  }
  function timeCell(offset, recordedDuration, title) {
    const timing = node("span", "event-time");
    timing.append(node("span", "", offset));
    if (recordedDuration != null) {
      const element = node("span", "event-duration", duration(recordedDuration));
      element.title = "Recorded duration";
      timing.append(element);
    }
    timing.title = title;
    return timing;
  }
  function transcriptRow(entry) {
    const kind = node("span", `event-kind entry-kind${isEntryError(entry) ? " error" : ""}`, KIND_LABELS[entry.kind]);
    kind.style.setProperty("--lane", `var(--${entry.kind})`);
    const summary = node("span", "event-summary");
    summary.append(node("span", "event-title", entry.title));
    if (isEntryError(entry)) summary.append(node("span", "status-badge", entry.status));
    const requested = entry.kind === "assistant" && !entry.text.trim() ? requestedTools(entry) : [];
    const preview = requested.length ? `→ ${requested.join(", ")}` : entry.text.slice(0, 1200).replace(/\s+/g, " ").slice(0, 500);
    if (preview) summary.append(node("span", "event-preview", preview));
    if (isEncrypted(entry)) summary.append(encryptedBadge(encryptionOf(entry)));
    const offset = entry.start_ms == null ? "—" : `+${duration(entry.start_ms - timeline.origin)}`;
    const total = entryDuration(entry);
    const title = entry.start_ms == null ? "Timing not recorded" : `${date(entry.start_ms)}${entry.end_ms == null && entry.kind === "tool" ? " · no completion recorded" : ""}`;
    return { label: `${KIND_LABELS[entry.kind]}: ${entry.title}`, cells: [kind, summary, timeCell(offset, total ? total : null, title)] };
  }
  function recordRow(event) {
    const summary = node("span", "event-summary");
    summary.append(node("span", "event-title", event.title || human(event.kind)));
    const preview = recordPreview(event);
    if (preview) summary.append(node("span", "event-preview", preview));
    if (isEncrypted(event)) summary.append(encryptedBadge(encryptionOf(event)));
    const offset = event.elapsed_ms != null ? `+${duration(event.elapsed_ms)}` : event.timestamp ? time(event.timestamp) : "—";
    const title = event.timestamp ? date(event.timestamp) : "Timestamp not recorded";
    return { label: `Record ${event.index + 1}, ${human(event.kind)}: ${event.title}`, cells: [node("span", `event-kind ${category(event)}`, recordKindLabel(event)), summary, timeCell(offset, event.duration_ms, title)] };
  }
  function recordPreview(event) {
    if (event.text) return event.text.slice(0, 1200).replace(/\s+/g, " ").slice(0, 500);
    const raw = eventPayload(event);
    if (!raw || typeof raw !== "object") return "";
    return [raw.phase, raw.status, raw.model_id, raw.model, raw.reason, raw.error_message]
      .filter(value => typeof value === "string" || typeof value === "number").join(" · ").slice(0, 500);
  }
  function recordKindLabel(event) {
    const type = category(event);
    if (type === "system") return /phase/.test(event.kind) ? "phase" : /turn/.test(event.kind) ? "turn" : human(event.kind);
    if (type === "result") return "tool result";
    return type;
  }
  function renderLedger() {
    const target = $("event-list");
    const oldScroll = target.scrollTop;
    target.replaceChildren();
    const current = view();
    const [one, many] = current.noun;
    $("result-count").textContent = state.matches.length === current.items.length ? countLabel(current.items.length, one, many) : `${number(state.matches.length)} of ${countLabel(current.items.length, one, many)}`;
    if (!state.matches.length) {
      const empty = node("div", "empty-state");
      empty.append(node("p", "", current.items.length ? `No matching ${many}` : state.view === "transcript" ? "No transcript was recorded" : "No records"));
      if (current.items.length) empty.append(button("Clear filters", "", clearFilters));
      else if (state.view === "transcript" && events.length) empty.append(button("Show all records", "", () => switchView("records")));
      else if (data.artifacts.length) empty.append(button("View session files", "", showSession));
      target.append(empty);
    }
    const fragment = document.createDocumentFragment();
    let previousBoundary = null;
    for (const item of state.matches.slice(state.page * PAGE_SIZE, (state.page + 1) * PAGE_SIZE)) {
      const group = current.boundary(item);
      if (group !== previousBoundary) {
        const separator = node("div", "turn-row", group);
        separator.setAttribute("role", "presentation");
        fragment.append(separator);
        previousBoundary = group;
      }
      const wrapper = node("div", "ledger-item");
      wrapper.setAttribute("role", "listitem");
      const row = button("", "ledger-row", () => selectItem(item.index));
      const { label, cells } = current.row(item);
      row.dataset.index = String(item.index);
      row.setAttribute("aria-current", String(item.index === state.selected));
      const level = encryptionOf(item);
      row.setAttribute("aria-label", `${label}${current.isError(item) ? ", error" : ""}${level === "none" ? "" : `, ${encryptionPhrase(level)}`}`);
      if (level !== "none") row.dataset.encrypted = "true";
      row.append(...cells);
      wrapper.append(row);
      if (level !== "none") {
        wrapper.classList.add("has-encrypted");
        wrapper.append(encryptedLock(level, () => selectItem(item.index, true, true)));
      }
      fragment.append(wrapper);
    }
    target.append(fragment);
    target.scrollTop = oldScroll;
    pagination($("pagination"), state.page, state.matches.length, PAGE_SIZE, page => {
      state.page = page;
      renderLedger();
      target.scrollTop = 0;
    });
  }
  function switchView(name, focusList = true) {
    if (!VIEWS[name] || state.view === name) return;
    const selected = state.selected;
    const mapped = selected == null ? null : name === "records"
      ? (entriesByIndex.get(selected) || { event_indices: [] }).event_indices[0]
      : entryByEvent.get(selected);
    closeInspector(false);
    hideTooltip();
    state.view = name;
    $("view-transcript").setAttribute("aria-pressed", String(name === "transcript"));
    $("view-records").setAttribute("aria-pressed", String(name === "records"));
    for (const id of ["search", "kind", "turn", "source-filter"]) $(id).value = "";
    initializeFilters();
    renderHeader();
    applyFilters();
    if (mapped != null && view().byIndex.has(mapped)) selectItem(mapped, true, focusList);
  }
  function selectItem(index, reveal = false, focus = false) {
    const current = view();
    if (!current.byIndex.has(index)) return;
    let position = state.matches.findIndex(item => item.index === index);
    if (position < 0) {
      clearFilters();
      position = state.matches.findIndex(item => item.index === index);
    }
    const item = current.byIndex.get(index);
    if (state.selected !== index) state.tab = defaultTab(item);
    state.selected = index;
    const page = Math.floor(position / PAGE_SIZE);
    if (page !== state.page) {
      state.page = page;
      renderLedger();
    } else {
      for (const row of $("event-list").querySelectorAll("button[data-index]")) row.setAttribute("aria-current", String(Number(row.dataset.index) === index));
    }
    $("inspector").hidden = false;
    $("workbench").classList.add("inspecting");
    renderInspector();
    const row = $("event-list").querySelector(`button[data-index="${Number(index)}"]`);
    if (row && (reveal || focus)) {
      if (focus) row.focus({ preventScroll: true });
      const list = $("event-list");
      const top = row.getBoundingClientRect().top - list.getBoundingClientRect().top + list.scrollTop;
      if (top < list.scrollTop) list.scrollTop = top;
      else if (top + row.offsetHeight > list.scrollTop + list.clientHeight) list.scrollTop = top + row.offsetHeight - list.clientHeight;
    }
    if (state.view === "transcript") revealInTimeline(item);
    syncTimelineSelection();
    syncInspectorLayout();
    if (narrowLayout.matches) $("close-inspector").focus({ preventScroll: true });
  }
  function defaultTab(item) {
    if (state.view === "transcript") return item.kind === "tool" ? (isEntryError(item) ? "output" : "input") : "content";
    return associatedTools(item).length ? category(item) === "result" || isEventError(item) ? "output" : "input" : "content";
  }
  function syncInspectorLayout() {
    const ledger = $("event-list").closest(".ledger");
    ledger.inert = narrowLayout.matches && state.selected != null;
    if (ledger.inert && ledger.contains(document.activeElement)) $("close-inspector").focus({ preventScroll: true });
  }
  function closeInspector(restoreFocus = true) {
    const selected = state.selected;
    state.selected = null;
    $("inspector").hidden = true;
    $("detail-lock").hidden = true;
    $("workbench").classList.remove("inspecting");
    syncInspectorLayout();
    syncTimelineSelection();
    for (const row of $("event-list").querySelectorAll("button[data-index]")) row.setAttribute("aria-current", "false");
    if (restoreFocus) {
      const row = $("event-list").querySelector(`button[data-index="${Number(selected)}"]`);
      if (row) row.focus({ preventScroll: true });
    }
  }

  /* ---- Inspector ---- */
  function renderTabs(tabs, focusTab) {
    if (!tabs.some(([name]) => name === state.tab)) state.tab = tabs[0][0];
    $("detail-tabs").replaceChildren();
    for (const [name, label] of tabs) {
      const tab = button(label, "detail-tab", () => { state.tab = name; renderInspector(true); });
      tab.id = `tab-${name}`;
      tab.dataset.tab = name;
      tab.setAttribute("role", "tab");
      tab.setAttribute("aria-selected", String(name === state.tab));
      tab.setAttribute("aria-controls", "detail-content");
      tab.tabIndex = name === state.tab ? 0 : -1;
      tab.addEventListener("keydown", key => {
        let position = tabs.findIndex(([item]) => item === name);
        if (key.key === "ArrowRight") position = (position + 1) % tabs.length;
        else if (key.key === "ArrowLeft") position = (position + tabs.length - 1) % tabs.length;
        else if (key.key === "Home") position = 0;
        else if (key.key === "End") position = tabs.length - 1;
        else return;
        key.preventDefault();
        state.tab = tabs[position][0];
        renderInspector(true);
      });
      $("detail-tabs").append(tab);
      if (focusTab && name === state.tab) tab.focus();
    }
    const panel = $("detail-content");
    panel.replaceChildren();
    panel.setAttribute("aria-labelledby", `tab-${state.tab}`);
    return panel;
  }
  function syncDetailLock(item) {
    const level = encryptionOf(item);
    const lock = $("detail-lock");
    lock.hidden = level === "none";
    lock.dataset.encryption = level;
    const phrase = level === "none" ? "Encrypted reasoning" : encryptionPhrase(level);
    lock.title = phrase;
    lock.setAttribute("aria-label", phrase);
    lock.setAttribute("aria-hidden", String(level === "none"));
  }
  function renderInspector(focusTab = false) {
    const item = view().byIndex.get(state.selected);
    if (!item) return;
    syncDetailLock(item);
    view().inspect(item, focusTab);
    $("detail-content").scrollTop = 0;
  }
  function recordLinks(indices) {
    const related = node("div", "related-events");
    for (const index of indices) {
      const event = eventsByIndex.get(index);
      if (!event) continue;
      related.append(button(`${event.source}${event.line ? `:${event.line}` : ""} · ${human(event.kind)}`, "text-button", () => {
        switchView("records", false);
        selectItem(index, true);
      }));
    }
    return related;
  }
  function renderEntryInspector(entry, focusTab) {
    $("detail-title").textContent = entry.title;
    const total = entryDuration(entry);
    $("detail-meta").textContent = [KIND_LABELS[entry.kind], entry.turn == null ? null : `Turn ${entry.turn}`, entry.status, total ? duration(total) : null].filter(present).join(" · ");
    const tools = entryTools(entry);
    const tabs = entry.kind === "tool" ? [["input", "Input"], ["output", "Output"], ["raw", "Raw"]] : [["content", "Content"], ["raw", "Raw"]];
    const panel = renderTabs(tabs, focusTab);
    if (isEncrypted(entry)) panel.append(encryptedNotice(encryptionOf(entry)));
    if (state.tab === "raw") {
      panel.append(button("Download records JSON", "text-button", () => download(entryRaw(entry), `grok-trace-entry-${entry.index + 1}.json`)));
      for (const index of entry.event_indices) {
        const event = eventsByIndex.get(index);
        if (!event) continue;
        panel.append(node("div", "content-label", `${event.source}${event.line ? `:${event.line}` : ""} · ${human(event.kind)}`), code(event.raw));
      }
    } else if (entry.kind === "tool") {
      const meta = node("dl", "metadata tool-meta");
      metadata(meta, [["Tool", entry.title], ["Call ID", entry.tool_call_id, true], ["Status", entry.status], ["Duration", duration(total)]]);
      panel.append(meta);
      const values = tools.map(tool => tool[state.tab]).filter(value => value != null);
      if (values.length) for (const value of values) panel.append(code(value));
      else panel.append(node("p", "missing-data", state.tab === "input" ? (entry.text ? entry.text : "Input not recorded.") : "Output not recorded (the call may be incomplete)."));
    } else {
      const requested = entry.kind === "assistant" && !entry.text.trim() ? requestedTools(entry) : [];
      if (entry.text) panel.append(node("div", "event-text message-text", entry.text));
      else if (requested.length) panel.append(node("p", "", `Requested ${requested.join(", ")} without a text reply.`));
      else panel.append(node("p", "missing-data", "No text was recorded."));
    }
    const details = node("details", "source-details");
    details.open = state.tab !== "raw" && entry.kind !== "system" && entry.kind !== "user";
    details.append(node("summary", "", "Timing & source"));
    const list = node("dl", "metadata");
    metadata(list, [
      ["Started", entry.start_ms == null ? "Not recorded" : `${date(entry.start_ms)} (${clock(entry.start_ms)})`],
      ["Ended", entry.end_ms == null ? (entry.start_ms == null ? "Not recorded" : "No completion recorded") : clock(entry.end_ms)],
      ["Duration", duration(total)],
      ["First token", entry.wait_ms == null ? "—" : `after ${duration(entry.wait_ms)}`],
      ["Turn", entry.turn],
      ["Call ID", entry.tool_call_id, true]
    ]);
    details.append(list, node("div", "content-label", "Recorded as"), recordLinks(entry.event_indices));
    panel.append(details);
  }
  function associatedTools(event) {
    const direct = toolsByEvent.get(event.index);
    if (direct && direct.length) return direct;
    return (toolsById.get(event.tool_call_id) || []).filter(tool => tool.turn == null || event.turn == null || tool.turn === event.turn);
  }
  function structuredContent(panel, raw) {
    if (!raw || typeof raw !== "object" || Array.isArray(raw)) {
      panel.append(code(raw));
      return;
    }
    const fields = node("dl", "metadata event-fields");
    const nested = [];
    for (const [key, value] of Object.entries(raw)) {
      if (value != null && typeof value === "object") nested.push([key, value]);
      else fields.append(node("dt", "", key), node("dd", "", value === null ? "null" : String(value)));
    }
    if (fields.childElementCount) panel.append(fields);
    for (const [key, value] of nested) panel.append(node("div", "content-label", key), code(value));
    if (!fields.childElementCount && !nested.length) panel.append(code(raw));
  }
  function renderRecordInspector(event, focusTab) {
    const linked = associatedTools(event);
    $("detail-title").textContent = event.title || human(event.kind);
    $("detail-meta").textContent = [`#${event.index + 1}`, event.turn == null ? null : `Turn ${event.turn}`, event.status, event.duration_ms == null ? null : duration(event.duration_ms)].filter(present).join(" · ");
    const panel = renderTabs(linked.length ? [["input", "Input"], ["output", "Output"], ["raw", "Raw"]] : [["content", "Content"], ["raw", "Raw"]], focusTab);
    if (isEncrypted(event)) panel.append(encryptedNotice(encryptionOf(event)));
    if (state.tab === "raw") {
      panel.append(button("Download record JSON", "text-button", () => download(event.raw, `grok-trace-record-${event.index + 1}.json`)), code(event.raw));
    } else if (linked.length) {
      for (const tool of linked) {
        const section = node("section", "tool-section");
        const meta = node("dl", "metadata tool-meta");
        metadata(meta, [["Tool", tool.name], ["Call ID", tool.id, true], ["Status", tool.status], ["Duration", duration(tool.duration_ms)]]);
        section.append(meta);
        const value = tool[state.tab];
        if (value != null) section.append(code(value));
        else section.append(node("p", "missing-data", `${state.tab === "input" ? "Input" : "Output"} not recorded.`));
        const others = tool.event_indices.filter(index => index !== event.index);
        if (others.length) section.append(node("div", "content-label", "Related records"), recordLinks(others));
        panel.append(section);
      }
    } else if (category(event) === "system") {
      structuredContent(panel, eventPayload(event));
    } else if (event.text) {
      panel.append(node("div", "event-text", event.text));
    } else {
      structuredContent(panel, eventPayload(event));
    }
    const details = node("details", "source-details");
    details.append(node("summary", "", "Source & metadata"));
    const list = node("dl", "metadata");
    metadata(list, [
      ["Record", event.index + 1], ["Source", event.source, true], ["Line", event.line],
      ["Kind", event.kind], ["Timestamp", event.timestamp], ["Elapsed (ms)", event.elapsed_ms],
      ["Duration (ms)", event.duration_ms], ["Turn", event.turn], ["Call ID", event.tool_call_id, true], ["Status", event.status]
    ]);
    details.append(list);
    if (entryByEvent.has(event.index)) {
      details.append(button("Show in transcript", "text-button", () => {
        switchView("transcript", false);
        selectItem(entryByEvent.get(event.index), true);
      }));
    }
    panel.append(details);
  }
  async function copyJson() {
    const item = view().byIndex.get(state.selected);
    if (!item) return;
    const text = json(state.view === "transcript" ? { entry: item, records: entryRaw(item) } : item.raw);
    try {
      if (!navigator.clipboard || !navigator.clipboard.writeText) throw new Error("Clipboard API unavailable");
      await navigator.clipboard.writeText(text);
      announce("JSON copied.");
    } catch (_) {
      const previousFocus = document.activeElement;
      const field = node("textarea");
      field.value = text;
      field.setAttribute("aria-label", "JSON to copy");
      field.style.position = "fixed";
      field.style.left = "-9999px";
      document.body.append(field);
      field.select();
      let copied = false;
      try { copied = document.execCommand("copy"); } catch (_) { /* Local pages may deny clipboard access. */ }
      field.remove();
      if (previousFocus) previousFocus.focus();
      announce(copied ? "JSON copied." : "Clipboard unavailable. Download the JSON from the Raw tab.");
    }
  }

  /* ---- Session details ---- */
  function renderTurns() {
    const target = $("turn-list");
    target.replaceChildren();
    if (!data.turns.length) {
      target.append(node("p", "missing-data", "No turn boundaries recorded."));
      return;
    }
    for (const turn of data.turns.slice(state.turnPage * TURN_PAGE_SIZE, (state.turnPage + 1) * TURN_PAGE_SIZE)) {
      const row = node("div", "session-turn");
      const select = button(`Turn ${turn.number}`, "text-button", () => {
        $("session-dialog").close();
        $("turn").value = String(turn.number);
        $("filters-panel").hidden = false;
        $("filters-toggle").setAttribute("aria-expanded", "true");
        applyFilters();
      });
      const usageRow = turnUsage.get(turn.number);
      row.append(select, node("span", "", [turn.model, turn.status, countLabel(turn.event_count, "record"), duration(turn.duration_ms), usageRow ? `${number(usageRow.totalTokens)} tokens · ${number(usageRow.modelCalls)} calls · ${cost(usageRow)}` : null].filter(present).join(" · ")));
      row.title = `Started: ${turn.started_at || "not recorded"}\nEnded: ${turn.ended_at || "not recorded"}`;
      target.append(row);
    }
    const controls = node("div", "session-pagination");
    pagination(controls, state.turnPage, data.turns.length, TURN_PAGE_SIZE, page => { state.turnPage = page; renderTurns(); });
    target.append(controls);
  }
  function renderModelUsage(models) {
    if (!models || !Object.keys(models).length) return;
    const table = node("table", "usage-table");
    const head = node("thead");
    const labels = node("tr");
    for (const label of ["Model", "Calls", "Input", "Cache read", "Cache write", "Reasoning", "Output", "Total", "Cost"]) {
      const cell = node("th", "", label);
      cell.scope = "col";
      labels.append(cell);
    }
    head.append(labels);
    const body = node("tbody");
    for (const [model, row] of Object.entries(models)) {
      const line = node("tr");
      const title = node("th", "", `${model}${row.usageIsIncomplete ? " (incomplete)" : ""}`);
      title.scope = "row";
      line.append(title);
      for (const field of ["modelCalls", "inputTokens", "cachedReadTokens", "cacheCreationTokens", "reasoningTokens", "outputTokens", "totalTokens"]) line.append(node("td", "", number(row[field])));
      line.append(node("td", "", cost(row)));
      body.append(line);
    }
    table.append(head, body);
    $("model-usage").append(table);
  }
  function renderArtifact() {
    const artifact = data.artifacts[Number($("artifact-select").value)];
    $("artifact-content").textContent = artifact ? typeof artifact.content === "string" ? artifact.content : json(artifact.content) : "No session files recorded.";
  }
  function showSession() {
    if (!state.sessionReady) {
      metadata($("recording-meta"), [
        ["Session ID", data.session_id, true], ["Model", data.model], ["Working directory", data.cwd, true],
        ["Source", data.source, true], ["Created", data.created_at], ["Updated", data.updated_at],
        ["Schema", data.schema_version], ["Transcript entries", number(transcript.length)], ["Raw records", number(events.length)], ["Session files", number(data.artifacts.length)]
      ]);
      metadata($("usage-meta"), [
        ["Input tokens", number(data.summary.input_tokens)], ["Cache read", number(data.summary.cached_input_tokens)],
        ["Output tokens", number(data.summary.output_tokens)], ["Total tokens", number(data.summary.total_tokens)]
      ]);
      if (usage && usage.session) {
        const session = usage.session;
        metadata($("usage-meta"), [["Cache write", number(session.cacheCreationTokens)], ["Reasoning tokens", number(session.reasoningTokens)], ["Model calls", number(session.modelCalls)], ["Reported cost", cost(session)]]);
        if (session.usageIsIncomplete || session.costIsPartial) {
          $("usage-meta").after(node("p", "subtle-note", [session.usageIsIncomplete ? "Token usage is incomplete." : "", session.costIsPartial ? "Cost is a recorded subtotal." : ""].filter(Boolean).join(" ")));
        }
        renderModelUsage(session.modelUsage);
      }
      renderTurns();
      for (const warning of data.warnings) $("warning-list").append(node("li", "", warning));
      if (!data.warnings.length) $("warning-list").append(node("li", "", "No recording warnings."));
      data.artifacts.forEach((artifact, index) => {
        const option = node("option", "", artifact.name);
        option.value = String(index);
        $("artifact-select").append(option);
      });
      $("artifact-select").disabled = !data.artifacts.length;
      renderArtifact();
      state.sessionReady = true;
    }
    $("session-dialog").showModal();
  }
  function nextError() {
    const current = view();
    const errors = current.items.filter(current.isError);
    if (!errors.length) return;
    const position = current.items.findIndex(item => item.index === state.selected);
    const next = current.items.slice(position + 1).find(current.isError) || errors[0];
    selectItem(next.index, true, true);
    announce(`Error: ${next.title}`);
  }

  let searchTimer;
  $("search").addEventListener("input", () => {
    clearTimeout(searchTimer);
    searchTimer = setTimeout(() => applyFilters(), 140);
  });
  for (const name of ["kind", "turn", "source-filter"]) $(name).addEventListener("change", () => applyFilters());
  $("filters-toggle").addEventListener("click", () => {
    const open = $("filters-panel").hidden;
    $("filters-panel").hidden = !open;
    $("filters-toggle").setAttribute("aria-expanded", String(open));
  });
  $("view-transcript").addEventListener("click", () => switchView("transcript"));
  $("view-records").addEventListener("click", () => switchView("records"));
  $("reset-filters").addEventListener("click", clearFilters);
  $("next-error").addEventListener("click", nextError);
  $("detail-lock").addEventListener("click", () => {
    const level = $("detail-lock").dataset.encryption;
    announce(`${encryptionPhrase(level === "partial" ? "partial" : "full")}.`);
  });
  $("copy").addEventListener("click", copyJson);
  $("close-inspector").addEventListener("click", () => closeInspector());
  // Export the exact embedded document: JSON.parse would round integers above 2^53.
  $("export").addEventListener("click", () => download(sourceJson, "grok-agent-trace.json", true));
  $("session-details").addEventListener("click", showSession);
  $("close-session").addEventListener("click", () => $("session-dialog").close());
  $("artifact-select").addEventListener("change", renderArtifact);
  $("shortcuts").addEventListener("click", () => $("shortcut-dialog").showModal());
  $("close-shortcuts").addEventListener("click", () => $("shortcut-dialog").close());
  narrowLayout.addEventListener("change", syncInspectorLayout);
  document.addEventListener("keydown", key => {
    if (key.ctrlKey || key.metaKey || key.altKey) return;
    // Native dialogs own Escape and focus while open.
    if ($("shortcut-dialog").open || $("session-dialog").open) return;
    const active = document.activeElement;
    const editing = /INPUT|TEXTAREA|SELECT/.test(active.tagName) || active.isContentEditable;
    if (key.key === "Escape") {
      key.preventDefault();
      hideTooltip();
      if (state.selected != null) closeInspector();
      else { clearFilters(); if (editing) active.blur(); }
      return;
    }
    if (editing) return;
    const onRow = active.matches("button[data-index]");
    if (key.key === "/") {
      key.preventDefault();
      $("search").focus();
    } else if (key.key === "?") {
      key.preventDefault();
      $("shortcut-dialog").showModal();
    } else if (key.key.toLowerCase() === "e") {
      key.preventDefault();
      nextError();
    } else if (key.key.toLowerCase() === "v") {
      key.preventDefault();
      switchView(state.view === "transcript" ? "records" : "transcript");
    } else if (key.key === "+" || key.key === "=") {
      key.preventDefault();
      zoom(0.6);
    } else if (key.key === "-" || key.key === "_") {
      key.preventDefault();
      zoom(1 / 0.6);
    } else if (key.key === "0") {
      key.preventDefault();
      setViewport(0, Infinity);
    } else if (active.closest("button, a, summary, [role=tab]") && !onRow) {
      return;
    } else if (["ArrowDown", "ArrowUp", "j", "k"].includes(key.key)) {
      if (!state.matches.length) return;
      key.preventDefault();
      const direction = ["ArrowDown", "j"].includes(key.key) ? 1 : -1;
      const focused = onRow ? Number(active.dataset.index) : state.selected;
      const current = state.matches.findIndex(item => item.index === focused);
      const next = current < 0 ? 0 : Math.max(0, Math.min(state.matches.length - 1, current + direction));
      selectItem(state.matches[next].index, true, true);
    }
  });
  $("view-transcript").disabled = !transcript.length;
  $("view-transcript").setAttribute("aria-pressed", String(state.view === "transcript"));
  $("view-records").setAttribute("aria-pressed", String(state.view === "records"));
  initializeFilters();
  renderHeader();
  bindTimeline();
  renderTimeline();
  applyFilters();
})();
