#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
#
# SPDX-License-Identifier: MIT
"""PreToolUse guard: Dart code is navigated with dart-runner.

Bash:
  - cat/head/tail/sed/awk/find on *.dart -> deny  (outline / read_symbol)
  - grep/rg on *.dart                    -> allow with a reminder; a class
    sweep needs text search and dart-runner has none
Read:
  - a whole *.dart file (no offset/limit) -> allow with a reminder
  - a part of one (offset/limit)          -> allow with a reminder: read_symbol
    takes path with lines or around
Edit / MultiEdit (hints only, nothing is denied):
  - the same old_string in a third different *.dart file in a row -> a call
    rewrite or a rename, not hand edits: rewrite_calls / rename / fix
PostToolUse Bash:
  - `dart analyze` / `flutter analyze` output with one diagnostic code more
    than 3 times -> fix, and get_problems group "code"

The journal rule (.claude/loop/ through loop.py) is the evidence-loop skill's
own hook, scripts/journal_guard.py.
"""

import json
import os
import re
import shlex
import sys
import tempfile
from collections import Counter

READERS = {"grep", "rg", "find", "cat", "head", "tail", "sed", "awk"}
TEXT_SEARCH = {"grep", "rg"}
SEPARATORS = {"|", "||", "&&", ";", "&", ";;", "(", ")"}
KEYWORDS = {"do", "then", "else", "elif", "done", "fi", "{", "}", "!"}

DART_HINT = (
    "Dart code: load dart-runner via ToolSearch and use outline / read_symbol "
    "to read, find_symbol / find_references / find_callers / "
    "find_implementations / hover to navigate, always format: compact."
)


REPEATED_EDITS = 3
REPEATED_CODES = 3
RECENT_EDITS = 10


def emit(decision, text, event="PreToolUse"):
    out = {"hookSpecificOutput": {"hookEventName": event}}
    if decision == "deny":
        out["hookSpecificOutput"]["permissionDecision"] = "deny"
        out["hookSpecificOutput"]["permissionDecisionReason"] = text
    else:
        out["hookSpecificOutput"]["additionalContext"] = text
    print(json.dumps(out))
    sys.exit(0)


def check_bash(command):
    if re.search(r"\.dart\b", command) is None:
        return
    # punctuation_chars splits `-1;` and `x|y` into separate operators, so a
    # `;` glued to a word still ends the segment.
    try:
        lexer = shlex.shlex(command, posix=True, punctuation_chars=True)
        lexer.whitespace_split = True
        tokens = list(lexer)
    except ValueError:
        tokens = command.split()
    # Only a reader whose OWN arguments name Dart: `loop.py brief --path x.dart
    # | sed ...` filters another command's output.
    readers = set()
    segment = []
    for tok in [*tokens, ";"]:
        if tok in SEPARATORS:
            while segment and segment[0] in KEYWORDS:
                segment = segment[1:]
            if segment:
                name = segment[0].rsplit("/", 1)[-1]
                if name in READERS and any(
                    re.search(r"\.dart\b", t) for t in segment[1:]
                ):
                    readers.add(name)
            segment = []
        else:
            segment.append(tok)
    if not readers:
        return
    if readers <= TEXT_SEARCH:
        emit(
            "allow",
            "Reminder: grep on Dart is for TEXT only (a class sweep, logs, "
            "comments). For a declaration, usages, callers or a body: " + DART_HINT,
        )
    emit(
        "deny",
        "Blocked: reading Dart with "
        + "/".join(sorted(readers - TEXT_SEARCH))
        + ". "
        + DART_HINT,
    )


def check_read(tool_input):
    path = tool_input.get("file_path", "")
    if not path.endswith(".dart"):
        return
    if tool_input.get("offset") is not None or tool_input.get("limit") is not None:
        emit(
            "allow",
            "Reminder: part of a Dart file. dart-runner read_symbol takes path "
            'with lines: "165-180", or around: <line> and context, and names the '
            "declarations (tests, groups) around them.",
        )
    emit(
        "allow",
        "Reminder: whole-file Read of Dart. Prefer dart-runner outline, then "
        "read_symbol for the members you need. " + DART_HINT,
    )


def edit_state_path(session):
    safe = re.sub(r"[^\w-]", "_", session or "default")
    return os.path.join(tempfile.gettempdir(), f"rpc_dart_navigation_guard_{safe}.json")


def check_edit(tool, tool_input, session):
    """The same replacement typed into a third Dart file in a row is a rewrite."""
    path = tool_input.get("file_path", "")
    if not path.endswith(".dart"):
        return
    edits = tool_input.get("edits") if tool == "MultiEdit" else [tool_input]
    olds = {
        (e.get("old_string") or "").strip()
        for e in edits or []
        if len((e.get("old_string") or "").strip()) >= 4
    }
    state_path = edit_state_path(session)
    try:
        with open(state_path) as f:
            state = json.load(f)
    except Exception:
        state = {"recent": [], "hinted": []}
    recent = state["recent"]
    hit = None
    for old in olds:
        if old in state["hinted"]:
            continue
        run = [e for e in recent[-(REPEATED_EDITS - 1):] if old in e["olds"]]
        files = {e["file"] for e in run} | {path}
        if len(run) == REPEATED_EDITS - 1 and len(files) == REPEATED_EDITS:
            hit = old
            break
    recent.append({"file": path, "olds": sorted(olds)})
    state["recent"] = recent[-RECENT_EDITS:]
    if hit is not None:
        state["hinted"] = (state["hinted"] + [hit])[-RECENT_EDITS:]
    try:
        with open(state_path, "w") as f:
            json.dump(state, f)
    except OSError:
        pass
    if hit is None:
        return
    shown = hit if len(hit) <= 60 else hit[:60] + "..."
    emit(
        "allow",
        f"Hint: the same edit ({shown!r}) in a third Dart file. Uses of a "
        "declaration are rewritten by dart-runner from the analyzer, with a dry "
        "run: rewrite_calls (template with $target, $args, $0, $name) when a "
        "call changes shape, rename for a name, fill_missing_args for a new "
        "required argument, fix for one diagnostic code. text_replace for docs "
        "and comments.",
    )


ANALYZE = re.compile(r"\b(dart|flutter)\s+analyze\b")
DIAGNOSTIC_CODE = re.compile(r"^\s*(error|warning|info)\s+-\s+.*\s-\s+([a-z0-9_]+)\s*$")


def check_analyze_output(tool_input, response):
    """dart analyze listing one code many times: fix takes them in one go."""
    if not ANALYZE.search(tool_input.get("command", "")):
        return
    if isinstance(response, dict):
        text = "\n".join(str(response.get(k) or "") for k in ("stdout", "stderr", "output"))
    else:
        text = str(response or "")
    codes = Counter()
    for line in text.splitlines():
        m = DIAGNOSTIC_CODE.match(line)
        if m:
            codes[m.group(2)] += 1
    many = [(c, n) for c, n in codes.most_common() if n > REPEATED_CODES]
    if not many:
        return
    listed = ", ".join(f"{n}x {c}" for c, n in many[:5])
    emit(
        "allow",
        f"Hint: {listed}. dart-runner fix (code: ...) applies the analyzer's "
        "quick fix to every site with a dry run and ids; get_problems with "
        'group: "code" (and changed: true) sums them up without the full list.',
        event="PostToolUse",
    )


def main():
    try:
        payload = json.load(sys.stdin)
    except Exception:
        return
    tool = payload.get("tool_name")
    tool_input = payload.get("tool_input") or {}
    if payload.get("hook_event_name") == "PostToolUse":
        if tool == "Bash":
            check_analyze_output(tool_input, payload.get("tool_response"))
        return
    if tool == "Bash":
        check_bash(tool_input.get("command", ""))
    elif tool == "Read":
        check_read(tool_input)
    elif tool in ("Edit", "MultiEdit"):
        check_edit(tool, tool_input, payload.get("session_id"))


if __name__ == "__main__":
    main()
