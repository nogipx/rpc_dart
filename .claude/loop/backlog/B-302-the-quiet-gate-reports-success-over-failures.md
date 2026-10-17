---
status: closed (round 883)
round: 882
commit: 84189f6b
paths: [pubspec.yaml]
probe: —
reason: risk — gate tooling, outside round 882's package; seen once, the cause read from melos's own echo of the command
rank: 1
---

# B-302 — the quiet gate reports SUCCESS over failures

Round 882's `melos run test:unit:quiet --no-select` printed two `[E]`
failures (`rpc_dart_conformance` I-3 socket row, `rpc_dart_http2`
`graceful_drain_on_stop_test`) and still ended `SUCCESS`, exit 0.

The echo melos prints of the per-package command shows why:
`... 2>&1; s=0; grep ...; tail -n 1 .dart_tool/test_out.txt; exit` — the
`$?` and `$s` of the `run:` string in the root `pubspec.yaml` were expanded
by the outer shell before `melos exec` got them. So `s` is always 0 and the
bare `exit` returns `tail`'s status. The config's claim "same exit status" as
`test:unit` does not hold: the loop's gate step cannot fail on a test.

Next step: run the quiet script over a package with a deliberately failing
test and read the exit code (the control); then escape the dollars (`\$?`,
`\$s`) or move the body into a script file, and run the control again.

Closed by round 883: confirmed (planted failure, exit 0 -> 1) and fixed by
escaping; bench P-338.

## Owner decision

—
