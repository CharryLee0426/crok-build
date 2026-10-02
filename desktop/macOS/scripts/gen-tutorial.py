#!/usr/bin/env python3
"""Regenerates Sources/GrokDesktop/TutorialContent.swift from the terminal's tutorial pages.

Usage: scripts/gen-tutorial.py [path/to/crok-build]   (defaults to the repository around this package)
"""
import pathlib, sys

PACKAGE = pathlib.Path(__file__).resolve().parent.parent
REPO = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else PACKAGE.parent.parent
PAGER = REPO / "crates/codegen/xai-grok-pager"
OUT = PACKAGE / "Sources/GrokDesktop/TutorialContent.swift"

# (file, title, blurb, go_deeper) exactly as in xai-grok-pager/src/tutorial_docs.rs.
TOPICS = [
    ("01-coming-from-another-tool.md", "Coming from Claude, Cursor, or Codex?", "your settings, rules & skills carry over", "Project Rules (AGENTS.md)"),
    ("02-first-prompt.md", "Your First Prompt", "send, queue, cancel", "Getting Started"),
    ("03-attach-and-paste.md", "Attach Files, Images & Paste", "@files, line ranges, screenshots", "Getting Started"),
    ("04-navigation.md", "Finding Your Way Around", "focus, scrollback, panes", "Keyboard Shortcuts"),
    ("05-slash-commands.md", "Slash Commands", "/help  /model  /resume  and Ctrl+P", "Slash Commands"),
    ("06-worktrees.md", "Parallel Work: Worktrees", "isolated sessions on one repo", "Session Management"),
    ("07-plan-and-permissions.md", "Plan Mode & Permissions", "review the approach before it acts", "Plan Mode"),
    ("08-make-it-yours.md", "Make It Yours", "just ask: AGENTS.md, memory, themes", "Project Rules (AGENTS.md)"),
    ("09-where-next.md", "Where to Go Next", "guides, feedback, and good habits", None),
]

INDENT = " " * 12

def literal(text):
    assert '"""#' not in text and "\\#" not in text
    body = "\n".join((INDENT + line) if line.strip() else "" for line in text.rstrip("\n").split("\n"))
    return '#"""\n' + body + "\n" + INDENT + '"""#'

def swift_string(value):
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'

out = [
    "// Generated from crates/codegen/xai-grok-pager/docs/tutorial/*.md by scripts/gen-tutorial.py.",
    "// The page text is verbatim; regenerate instead of editing it by hand.",
    "",
    "/// The nine `/tutorial` topics, in the terminal's order (`xai-grok-pager/src/tutorial_docs.rs`).",
    "enum GrokTutorial {",
    "    static let topics: [GrokTutorialTopic] = [",
]
for file, title, blurb, deeper in TOPICS:
    text = (PAGER / "docs/tutorial" / file).read_text()
    out += [
        "        GrokTutorialTopic(",
        f"            id: {swift_string(file[:-3])},",
        f"            title: {swift_string(title)},",
        f"            blurb: {swift_string(blurb)},",
        f"            goDeeper: {swift_string(deeper) if deeper else 'nil'},",
        f"            content: {literal(text)}",
        "        ),",
    ]
out += ["    ]", "}", ""]
OUT.write_text("\n".join(out))
print(f"wrote {OUT}")
