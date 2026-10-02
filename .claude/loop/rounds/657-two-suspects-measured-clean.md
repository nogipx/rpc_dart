---
round: 657
verdict: CLEAN
packages: [rpc_dart, rpc_dart_websocket]
lens: RPC-15
bench: none — a guard test and B-241's probe
budget: probes 3/5, canaries 0/5
commit: yes
release: none
---

# Round 657 — two suspects measured clean

## Target

Two open suspicions: round 640's reviewer noted that the pipeline logs an
ERROR per dropped request frame, which a peer could repeat; and B-241, two
websocket answers lost under gate load.

## Hypothesis

A client that keeps uploading after its handler stopped reading floods the
log; the refused-upgrade test loses its 403 to an RST under load.

## Before

```
client-stream handler `break`s after one message, client sends 20 more
warning-and-above records: 0   (all levels: the frames are consumed below the handler)
refused upgrade, 8 at a time, rpc_dart's suite running at concurrency 12
with body bytes      1200 of 1200 answered 403
without body bytes   1200 of 1200 answered 403
```

## Control

All-level logging in the first arm shows the logger is wired (it prints every
frame's internal record), so zero warnings is a measurement, not a dead
listener.

## Mechanism

None found. The DROPPED branch is the one round 375 already could not reach;
`break` cancels the handler's view and the stream processor keeps consuming.
B-241's RST hypothesis does not reproduce at this load.

## After

A guard test pins the first: a handler that stops reading logs nothing at
warning or above. B-241 stays open with the frequency recorded: 0 in 2400
under load, so the two gate reds remain unexplained.

## Canary

None: nothing was fixed.

## Gate

Rounds 651-657 together: `analyze` (21 packages and wasm) green, `format`
clean. `test:unit`: every package green except one rpc_dart red, an existing
test pinning jitter at whole milliseconds ("greater than 0 ms"), which round
655's microsecond jitter broke. 655 now keeps the old [1 ms, cap] jitter and
uses microseconds only below a millisecond; rpc_dart rerun alone, 2040
passed. rpc_dart_websocket 279.

## Not fixed

B-241.

## Links

Lens `../lenses/RPC-15-remeasure-own-record.md` — `applied: [..., 657]`.
Test `packages/core/rpc_dart/test/endpoint/a_handler_that_stops_reading_logs_nothing_test.dart`.
Lead `../backlog/B-241-websocket-answers-lost-under-gate-load.md`.
