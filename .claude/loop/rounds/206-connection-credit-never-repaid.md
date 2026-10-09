---
round: 206
verdict: FIXED
packages: [rpc_dart, rpc_dart_isolate]
lens: RPC-01
bench: P-01 — new
budget: probes 2/3, canaries 3/3
review: self — the session forbids the Agent tool unless the user asks, so the `loop.py review` prompt was answered in full against the record and the probes rather than by a subagent; approved 10 of 10, one qualification on Q3 (the counter lives in the bench, what it counts is a library event)
commit: yes
---

# Round 206 — connection credit is never repaid for bytes nobody consumed

## Target

RPC-01, first by rank among the never-applied lenses. Its detector is
`_fcOnConsumed` and every one of its callers, plus every place a frame is
dropped before it becomes a message. The lens was confirmed off-journal in round
162 on the per-STREAM window; running the same detector over the connection
pool, which did not exist then, is what this round did.

## Hypothesis

The skip paths the lens names are all covered (`onFrameDiscarded` credits
skipped bytes, metadata frames carry no payload), but the credit RETURN still
hangs on the "message delivered" event at BOTH levels — and only the per-stream
level has a teardown path that reclaims. So bytes that arrive and are never
consumed should shrink the connection pool permanently.

## Before

```
1 MiB connection pool, 256 KiB stream window, 256 KiB per call,
12 sequential streams:

  receiver drains the per-stream view    -> 12 calls, 3072 KiB, never wedged
  receiver binds it and never reads      ->  4 calls, 1024 KiB, then every
                                             send parks forever
  receiver drains, per-stream window OFF ->  4 calls, 1024 KiB, then the same

1024 KiB is exactly one pool. The wedge is permanent: the grace timer
only ever fires for a peer that has NEVER granted, and this peer has.
```

Probe: `packages/core/rpc_dart/.dart_tool/probe/conn_window_leak.dart` (P-01).

The third row is the sharper one — no misbehaviour at all. With
`flowControlWindowBytes: null` and only `flowControlConnectionWindowBytes` set,
a receiver consuming every single message still killed the connection after one
pool.

## Mechanism

Two independent holes, both under the lens.

1. `_fcCreditConnection` runs only from `_fcCredit`, which runs only on
   consumption. `_fcForget` reclaims the per-stream window at teardown and wakes
   whatever parked on it; the shared pool had no equivalent, so bytes buffered
   for a consumer that never took them were charged and never repaid. The loss
   is connection-WIDE, so it kills every later call, not just the one that
   dropped the bytes.
2. Every flow-control gate (`_fcMetered`, `_fcOnConsumed`, `deferFlowCredit`,
   `returnFlowCredit`) tested `flowControlWindowBytes` alone. With only the pool
   configured, metering was skipped entirely while `_fcTryConsume` still charged
   every send against the pool.

## After

```
same probe, same three modes, after the fix:

  receiver drains                        -> 12 calls, 3072 KiB, never wedged
  receiver binds it and never reads      -> 12 calls, 3072 KiB, never wedged
  receiver drains, per-stream window OFF -> 12 calls, 3072 KiB, never wedged
```

All three now equal the control exactly.

## Canary

Two halves, two canaries, in
`packages/core/rpc_dart/test/transports/flow_control_connection_debt_test.dart`.

- Debt ledger off (`_fcRepayConnection` → `if (1 > 0) return;`):
  `Expected: <-1> Actual: <4>` — "sender wedged at call 4 after 1024 KiB,
  against a 1024 KiB pool: credit for the bytes the receiver never took was
  never returned". The other three tests stayed green.
- Metering gate off (`_fcEnabled` → `_fcWindow != null`):
  `Expected: <-1> Actual: <0>` — "one stream, a receiver draining every message,
  wedged after 1024 KiB against a 1024 KiB pool: the pool is charged but never
  credited when flowControlWindowBytes is null".

The second canary PASSED on the first attempt, which meant the test was wrong,
not the code: the ledger repays at teardown, so across 12 short calls it masks
the missing gate entirely. Only a single long-lived stream, where teardown never
comes, isolates it. That cost one canary attempt and is filed as L-01.

`rpc_dart_isolate`'s `spawn_pre_ready_frames_test` went red on the fix. Its
claim (the worker's advertised pool bounds the host) is real and its assertions
are unchanged; its FIXTURE stood on the defect — the comment said in as many
words that with the per-stream window off "the worker never returns connection
credit either", and its `inertEntrypoint` did nothing at all. A stream with no
consumer bound is credited on arrival BY DESIGN, so an entrypoint that does
nothing cannot show a bound once the null-window hole is closed. It now binds a
per-stream view and does not read it — a consumer that does not consume — and
passes on `sent <= 9` exactly as before.

## Gate

`melos run analyze` green; `melos run test:unit --no-select` green
(exit 0, whole workspace); `melos run format:check` green;
`melos run test:web` green (dart2js, core is involved);
`melos exec --scope=rpc_dart -- fvm dart test -j 8` green twice, paced,
load average 7.6.

## Not fixed

Whether an ordinary ENDPOINT client reaches the same wedge. Three benches
failed to produce a valid number for it and the probe budget went with them: a
unary call after the cancels (too few bytes to need credit), producer overrun
after a pause (0 before any cancels too — one saturated stream is already
parked, so the observable could not move), and 30 pause-then-cancel streams
against a 512 KiB pool (still live at the end). That gap is made of LATENCY —
how much sits unconsumed at the instant of a cancel — and an in-memory pair
zeroes it out. Filed as B-11 with what was tried; not claimed as covered.

## Links

Lens `../lenses/RPC-01-flow-control-credit-on-skip.md` — `applied: [206]`,
status refreshed with the connection-level evidence.
Bench `../probes/P-01-connection-window-debt.md` — new, validated by its control.
Lead `../backlog/B-11-endpoint-reachability-needs-latency.md` — new, reason
"bench".
Lesson `../lessons/L-01-half-a-fix-can-mask-the-other-half.md` — new.
Catalog `U-07` (abort became continue) is the parent shape; this is its
connection-level twin, where the reclaim exists at one level and not the other.
