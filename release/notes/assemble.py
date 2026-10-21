#!/usr/bin/env python3
"""Joins one release's notes into the body of its GitHub release: the English, the five translations, each
in a collapsed <details> block, then the checksums.

    release/notes/assemble.py NOTES_DIR --check [--expect FILE]...
    release/notes/assemble.py NOTES_DIR --out FILE --sums SHA256SUMS.txt --set KEY=VALUE... [--expect FILE]...

NOTES_DIR is release/notes/v<version>/ with en.md, zh.md, ja.md, es.md, fr.md and de.md, the full notes in
each language. en.md opens with the blockquote naming the translations. A translation opens with its first
paragraph, and its headings sit one level below the English ones (### for ##), as it goes inside <details>.
{{KEY}} placeholders (PLACEHOLDERS below) are filled from --set; {{VERSION}} is the folder's version.

Both modes check that:
  - all six files are there, and the translations have no level-2 heading and no blockquote of their own;
  - every inline code span of en.md (commands, paths, file names) appears in each translation;
  - en.md names every --expect file, so the notes cover each file the release carries;
  - each ** opens and closes bold text where GitHub sees it (bold next to CJK punctuation is the usual trap);
  - no bare URL runs into the text after it (GitHub links everything up to the next space);
  - only known placeholders are used, and when writing, all of them are filled.
"""
import argparse
import pathlib
import re
import sys
import unicodedata

LANGUAGES = [
    ("en", "English"),
    ("zh", "简体中文"),
    ("ja", "日本語"),
    ("es", "Español"),
    ("fr", "Français"),
    ("de", "Deutsch"),
]
PLACEHOLDERS = {
    "VERSION": "the release number (the folder's name without the v)",
    "COMMIT": "the released commit, abbreviated",
    "CROK_VERSION": "the bundled crok's version, such as 1.0.45 (af1b3e395f68)",
    "TUI_SDK": "the macOS SDK the standalone crok was linked against",
    "SDK26": "the macOS SDK the macOS 26 SDK image was linked against",
    "SDK15": "the macOS SDK the macOS 15 SDK image was linked against",
    "XCODE26": "the Xcode that built the macOS 26 SDK image and the iOS app",
    "XCODE15": "the Xcode that built the macOS 15 SDK image",
}
PLACEHOLDER = re.compile(r"\{\{([^{}]*)\}\}")
CODE_SPAN = re.compile(r"`([^`]+)`")
BOLD = re.compile(r"(?<!\*)\*\*(?!\*)")
# Link targets and <autolinks> end where Markdown says. A bare URL ends only at ASCII whitespace or <, so
# GitHub's link also takes in a no-break space or CJK text after it.
LINK_TARGET = re.compile(r"\]\([^)]*\)|<https?://[^>]*>")
BARE_URL = re.compile(r"https?://[^ \t\n\r\f\v<]+")


def prose_lines(text):
    """The numbered lines outside fenced code blocks."""
    fenced = False
    for number, line in enumerate(text.splitlines(), 1):
        if line.lstrip().startswith("```"):
            fenced = not fenced
            continue
        if not fenced:
            yield number, line


def code_spans(text):
    return {match.group(1) for _, line in prose_lines(text) for match in CODE_SPAN.finditer(line)}


def is_punctuation(char):
    # CommonMark's punctuation: ASCII punctuation, or a Unicode character in a P category.
    if char.isascii():
        return not char.isalnum() and not char.isspace()
    return unicodedata.category(char).startswith("P")


def bold_problems(text):
    """The ** runs that would not open or close bold text under CommonMark's flanking rules."""
    problems = []
    for number, line in prose_lines(text):
        # Code spans keep their backticks (which count as punctuation) but not their contents.
        masked = CODE_SPAN.sub(lambda match: "`" + "x" * len(match.group(1)) + "`", line)
        opening = True
        for match in BOLD.finditer(masked):
            before = masked[match.start() - 1] if match.start() > 0 else " "
            after = masked[match.end()] if match.end() < len(masked) else " "
            if opening:
                fine = not after.isspace() and (not is_punctuation(after) or before.isspace() or is_punctuation(before))
            else:
                fine = not before.isspace() and (not is_punctuation(before) or after.isspace() or is_punctuation(after))
            if not fine:
                role = "open" if opening else "close"
                problems.append(f"line {number}: the ** at column {match.start() + 1} does not {role} bold text on GitHub "
                                f"(put a space on its outer side, or move it past the punctuation): {line.strip()}")
            opening = not opening
        if not opening:
            problems.append(f"line {number}: a ** without its pair: {line.strip()}")
    return problems


def url_problems(text):
    """Bare URLs that GitHub's autolinker would extend over the words after them."""
    problems = []
    for number, line in prose_lines(text):
        line = LINK_TARGET.sub(" ", CODE_SPAN.sub(" ", line))
        for match in BARE_URL.finditer(line):
            if not match.group().isascii():
                problems.append(f"line {number}: the link {match.group()} runs into the text after it; put a space after the URL")
    return problems


def fill(text, values, problems, where, check_only):
    def replace(match):
        key = match.group(1)
        if key not in PLACEHOLDERS:
            problems.append(f"{where}: unknown placeholder {{{{{key}}}}} (known: {', '.join(PLACEHOLDERS)})")
            return match.group(0)
        if key in values:
            return values[key]
        if not check_only:
            problems.append(f"{where}: no value for {{{{{key}}}}} ({PLACEHOLDERS[key]}); pass --set {key}=…")
        return match.group(0)

    return PLACEHOLDER.sub(replace, text)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("notes_dir", type=pathlib.Path)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--check", action="store_true", help="check the notes only")
    mode.add_argument("--out", type=pathlib.Path, help="write the release body here")
    parser.add_argument("--sums", type=pathlib.Path, help="SHA256SUMS.txt, quoted at the end")
    parser.add_argument("--set", action="append", default=[], metavar="KEY=VALUE", help="fill {{KEY}}")
    parser.add_argument("--expect", action="append", default=[], metavar="FILE", help="a file the notes must name")
    args = parser.parse_args()

    problems = []
    folder = args.notes_dir.resolve().name
    version = re.fullmatch(r"v(\d+\.\d+\.\d+)", folder)
    if not version:
        sys.exit(f"{args.notes_dir}: the folder is named v<version>, such as v2.0.0, not {folder}")
    values = {"VERSION": version.group(1)}
    for item in args.set:
        key, separator, value = item.partition("=")
        if not separator or key not in PLACEHOLDERS:
            sys.exit(f"--set {item}: expected KEY=VALUE with KEY one of {', '.join(PLACEHOLDERS)}")
        if key == "VERSION" and value != values["VERSION"]:
            sys.exit(f"--set VERSION={value}, but these are the notes of {values['VERSION']}")
        values[key] = value
    if args.out and not args.sums:
        sys.exit("--out needs --sums")

    texts = {}
    for code, _ in LANGUAGES:
        path = args.notes_dir / f"{code}.md"
        if not path.is_file() or not path.read_text().strip():
            problems.append(f"{path}: missing or empty")
            continue
        texts[code] = fill(path.read_text().strip(), values, problems, path.name, args.check)
    if len(texts) < len(LANGUAGES):
        sys.exit("\n".join(problems))

    english = texts["en"]
    if not english.startswith(">"):
        problems.append("en.md: start with the blockquote naming the translations (see the last release's notes)")
    for name in args.expect:
        if name not in english:
            problems.append(f"en.md: never names {name}, a file this release carries")
    spans = code_spans(english)
    for code, name in LANGUAGES[1:]:
        body = texts[code]
        if body.startswith(">"):
            problems.append(f"{code}.md: starts with a blockquote; the English one covers every language")
        for number, line in prose_lines(body):
            if line.startswith("## "):
                problems.append(f"{code}.md line {number}: a level-2 heading; translations go one level down")
        missing = sorted(span for span in spans if span not in body)
        if missing:
            problems.append(f"{code}.md ({name}) lacks code from en.md: " + ", ".join(f"`{span}`" for span in missing))
    for code, _ in LANGUAGES:
        problems.extend(f"{code}.md {problem}" for problem in bold_problems(texts[code]))
        problems.extend(f"{code}.md {problem}" for problem in url_problems(texts[code]))
    if problems:
        sys.exit("\n".join(problems))
    if args.check:
        print(f"{args.notes_dir}: notes of {values['VERSION']} in {len(LANGUAGES)} languages are complete")
        return

    parts = [english + "\n"]
    parts.append("\n---\n\n## Translations\n\nEach section holds the full notes in that language. Click a language to open it.\n")
    for code, name in LANGUAGES[1:]:
        parts.append(f"\n<details>\n<summary><b>{name}</b></summary>\n\n{texts[code]}\n\n</details>\n")
    checksums = args.sums.read_text().strip()
    parts.append(f"\n---\n\n## Checksums\n\nSHA-256, also attached as `SHA256SUMS.txt`:\n\n```\n{checksums}\n```\n")
    text = "".join(parts)
    if text.count("<details>") != text.count("</details>"):
        sys.exit("unbalanced <details> blocks")
    args.out.write_text(text)
    print(f"wrote {args.out}: {len(text.splitlines())} lines")


if __name__ == "__main__":
    main()
