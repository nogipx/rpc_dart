---
round: 790
class: process
cost: 1 round commit rebuilt; 1 lint info the gate had reported clean, found 1 round later
paths: [packages/**/test/**, packages/**/lib/**]
commit: 713ca944
status: active
---

# L-24 — analyze after the last format

## The rule

`dart format` rewrites code, and a rewrite can create a lint the analyzer
has not seen: it splits a one-line `if` into two lines, which
`curly_braces_in_flow_control_structures` then rejects. So the analyzer runs
AFTER the last formatter run, not before it. If `format:check` fails and you
format, analyze again before committing.

## What it cost

Round 790 ran `melos run analyze` (green), then `dart format` on a new test
(1 file changed), then `format:check` (green), and committed. The formatter
had split `if (r is LogEvent && r.level == RpcLogLevel.error) errors.add(...)`
across two lines; round 791's analyze reported it, and the round commit had
to be rebuilt. CLAUDE.md records the same lint once shipping in a published
`rpc_dart`.

## How to apply

Order the gate: format the files you touched, then `melos run analyze`, then
the rest. A `dart format` that reports "N changed" invalidates any analyze
that ran before it.
