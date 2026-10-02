---
round: 604
verdict: FIXED
packages: [rpc_dart]
lens: RPC-22
bench: none — the observable is a count of warning records per connection, read by overriding LogController.add in the test
budget: probes 0/5, canaries 0/5
commit: yes
release: changelog
---

# Round 604 — the peer chose how many lines

## Target

B-124's flooding half, open since the audit and unwitnessed since round 515, which
hand-built no-op frames and never reached the pipeline. The lead said to drive a
real peer instead; a raw client transport opening ordinary streams reaches five of
the seven sites.

Counted before the fix — every peer-triggerable warning in
`responder_pipeline.dart`:

```
site                              reachable by a peer   witnessed here
half-open reclaim                 yes                   yes
concurrent-stream ceiling         yes                   yes
pre-method refusal                yes                   yes
pre-bind refusal (round 594)      yes                   yes
concurrent-handler ceiling        yes                   yes
endpoint not started              no (round 515)        no
no-op frame for unknown stream    no (round 515)        no
```

## Hypothesis

Each refusal warns once per refused stream, so the peer chooses how many lines the
server logs; CLAUDE.md requires once per connection.

## Before

```
five refusals each       warnings
stream ceiling           5
handler ceiling          5
pre-bind refusal         5
pre-method refusal       5
half-open reclaim        5
```

Test: `packages/core/rpc_dart/test/logger/a_peer_cannot_flood_the_responder_log_test.dart`,
a raw client transport with its windows off against a responder whose policy
tightens one ceiling at a time; records counted in `LogController.add`, which runs
before filtering.

## Mechanism

The five refusals each called `_log.warning` unconditionally; the file already had
the warn-once shape (`_warnedRepeatOpeningFrame`) for a sixth.

## After

All five read `1`: one bool each, the same shape. The peer still gets its status on
every refused stream — only the log line is once.

## Canary

The before-run above is this code with the guards absent, and each of the five
tests failed with its own count (`Expected: <1> Actual: <5>`, listing the five
messages).

## Gate

`melos run analyze`, `melos run format:check`, `melos run license:check` green.
`melos run test:unit --no-select`: the FIRST run had one rpc_dart failure at load
11-13 whose name was lost to truncated output; `rpc_dart` alone then passed
(+1908), and a second full run was green (15 packages, rpc_dart +1908). The failure
is unidentified, not explained.

## Not fixed

- The two sites round 515 could not reach stay unguarded: a guard nobody can
  trigger has no witness.
- The caller's double record for a genuine fault (round 516) — a decision about
  which site owns the report.

## Links

Lead `../backlog/B-124-peer-triggered-warnings-fire-per-frame.md` — open, only the
decision left.
Lens `../lenses/RPC-22-the-refusal-path-is-reachable-by-anyone.md` — `applied: [604]`.
