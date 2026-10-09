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

The journal rule (.claude/loop/ through loop.py) is the evidence-loop skill's
own hook, scripts/journal_guard.py.
"""

import json
import re
import shlex
import sys

READERS = {"grep", "rg", "find", "cat", "head", "tail", "sed", "awk"}
TEXT_SEARCH = {"grep", "rg"}
SEPARATORS = {"|", "||", "&&", ";", "&", ";;", "(", ")"}
KEYWORDS = {"do", "then", "else", "elif", "done", "fi", "{", "}", "!"}

DART_HINT = (
    "Dart code: load dart-runner via ToolSearch and use outline / read_symbol "
    "to read, find_symbol / find_references / find_callers / "
    "find_implementations / hover to navigate, always format: compact."
)


def emit(decision, text):
    out = {"hookSpecificOutput": {"hookEventName": "PreToolUse"}}
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
        return
    emit(
        "allow",
        "Reminder: whole-file Read of Dart. Prefer dart-runner outline, then "
        "read_symbol for the members you need. " + DART_HINT,
    )


def main():
    try:
        payload = json.load(sys.stdin)
    except Exception:
        return
    tool = payload.get("tool_name")
    tool_input = payload.get("tool_input") or {}
    if tool == "Bash":
        check_bash(tool_input.get("command", ""))
    elif tool == "Read":
        check_read(tool_input)


if __name__ == "__main__":
    main()
