#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
#
# SPDX-License-Identifier: MIT
"""PreToolUse guard: Dart code is navigated with dart-runner, the journal with loop.py.

Bash:
  - any reader on .claude/loop/          -> deny  (loop.py answers it)
  - cat/head/tail/sed/awk/find on *.dart -> deny  (outline / read_symbol)
  - grep/rg on *.dart                    -> allow with a reminder; a class
    sweep needs text search and dart-runner has none
Read:
  - a whole *.dart file (no offset/limit) -> allow with a reminder
"""

import json
import re
import shlex
import sys

READERS = {"grep", "rg", "find", "cat", "head", "tail", "sed", "awk"}
TEXT_SEARCH = {"grep", "rg"}
SEPARATORS = {"|", "||", "&&", ";", "&"}

DART_HINT = (
    "Dart code: load dart-runner via ToolSearch and use outline / read_symbol "
    "to read, find_symbol / find_references / find_callers / "
    "find_implementations / hover to navigate, always format: compact."
)
LOOP_HINT = (
    "Journal (.claude/loop/): use python3 .claude/skills/evidence-loop/scripts/"
    "loop.py -- status / next for leads and lenses, find '<target text>' and "
    "find --path <file> for records, stale for what moved, yield for what a "
    "lens produced. Records are hypotheses: stale first."
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


def command_words(tokens):
    """The program names of every command in a pipeline or list."""
    words = []
    expect = True
    for tok in tokens:
        if tok in SEPARATORS:
            expect = True
            continue
        if expect:
            words.append(tok.rsplit("/", 1)[-1])
            expect = False
    return words


def check_bash(command):
    try:
        tokens = shlex.split(command, posix=True)
    except ValueError:
        tokens = command.split()
    if not tokens:
        return
    words = set(command_words(tokens))
    # loop.py itself reads the journal; that is the intended path.
    if "loop.py" in command and words <= {"python3", "python"}:
        return
    readers = words & READERS
    if not readers:
        return
    touches_loop = ".claude/loop" in command
    touches_dart = re.search(r"\.dart\b", command) is not None
    if touches_loop:
        emit("deny", "Blocked: reading the journal with " + "/".join(sorted(readers)) + ". " + LOOP_HINT)
    if touches_dart:
        if readers <= TEXT_SEARCH:
            emit(
                "allow",
                "Reminder: grep on Dart is for TEXT only (a class sweep, logs, "
                "comments). For a declaration, usages, callers or a body: " + DART_HINT,
            )
        emit("deny", "Blocked: reading Dart with " + "/".join(sorted(readers - TEXT_SEARCH or readers)) + ". " + DART_HINT)


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
