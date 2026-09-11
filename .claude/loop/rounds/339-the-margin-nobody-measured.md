---
round: 339
verdict: FIXED
packages: [rpc_dart_http2]
lens: RPC-15
bench: none
commit: yes
---

# Round 339 — the margin nobody measured

## Target

The owner's, pasted mid-round from CI:

```
[rpc_dart_http2]: 00:50 +118 -1: test/concurrent_reconnect_test.dart:
  GUARD: a later reconnect still opens a new connection [E]
  Expected: <0>
    Actual: <1>
```

The assertion is `liveConnections()`, which polled `opened - closed` for 8
seconds. This is L-11's shape — the lesson round 321 paid for on this same
suite — and the round that wrote it left the other gauges of its kind standing.

## Hypothesis

The number is not evidence. Before hunting a defect, find out what else
`opened - closed == 1` can mean — and whether the 8 s budget was ever measured
against the time teardown actually takes.

## Before

**Five local runs, all green**: the file alone, the file under `--concurrency=1`,
the whole `rpc_dart_http2` suite, and two full `melos run test:unit` passes. So
the failure is CI-only, and the number it produced cannot say why.

`Actual: <1>` has three causes that need different fixes: a connection nothing
can close, a close that has not landed yet, and a harness that leaks. The
message distinguishes none of them.

The one cause that is measurable locally is the margin. Instrumenting the
existing poll:

```
concurrent reconnects       opened=2 closed=2   settled in 1733 ms
it does not scale           opened=2 closed=2   settled in 1735 ms
GUARD later reconnect       opened=3 closed=3   settled in 1739 ms
```

**~1735 ms against an 8000 ms budget — a margin of 4.6x**, on an idle machine.
And it is FLAT in the number of connections (2, 2, 3 all settle within 6 ms of
each other), so it is one fixed wait in teardown rather than per-connection
work. CI runs 14 packages at concurrency 4; 4.6x is not much to spend.

## Mechanism

A polled difference of two counters, with a budget nobody had measured against.
Nothing in the test recorded what the normal settle time was, so there was no
way to know 8 s was close — and when it was exceeded the failure named a number
rather than a cause.

## After

The wait is event-driven — it returns the moment the last close lands, so a
larger budget costs nothing when passing — and it reports the evidence:

```dart
Future<({int live, int ms})> settle({Duration within = const Duration(seconds: 30)})
...
reason: '$what: opened=$opened closed=$closed, still live after ${s.ms}ms. '
        'Near the budget means a slow teardown; far below it means a '
        'connection nothing can close.'
```

The file's wall clock is unchanged at 9 s, and `rpc_dart_http2` stays at `+206`.

## Canary

The library's single-flight marker in `reconnect()` ablated, which is the defect
these tests exist for:

```
Expected: <0>
  Actual: <2>
three concurrent reconnects orphaned a connection: opened=4 closed=2,
still live after 30007ms.
```

It still sees the orphan — and the new message settles the question the old one
posed: `30007ms` is the full budget, against `1735ms` when healthy, so this is a
connection nothing can close and not a slow teardown. The sequential GUARD test
stayed green under the same ablation, which is the right specificity.

## Gate

`melos run analyze` clean over 21 packages plus `rpc_dart_wasm`; `format:check`
clean; `test:unit` 14 packages, 0 failures.

## Not fixed

**Which cause CI actually hit is still unknown, and this round does not claim
to have fixed it.** What it fixes is that the next occurrence will say. The
margin is the best-supported explanation — measured, and thin — but a real
orphan under a race only CI's timing reaches is not excluded.

One hypothesis was measured and **disproven**: that the harness proxy orphans an
upstream socket when a client dies inside its 400 ms stall. It does not —
`sub.pause()` defers the done event past the point where `upstream` is assigned,
so all four rows of the probe report `onDone (upstream set)`. A simplified
stand-in harness did show an orphan in the *established* case, unexplained; that
is a stand-in, not the test, and it is not evidence about the library.

**B-34** was this round's original target and is parked with its measurement:
http2 is the only transport that does not validate outbound metadata against the
policy.

## Links

RPC-15 and L-11. L-11 says *assert an event at the peer, never poll a gauge that
rises and falls*; round 321 applied it to one assertion in `rpc_dart_http` and
this suite kept three more of the same shape.

> **A budget with no measurement beside it is a guess that looks like a
> decision.** 8 s reads as generous until you find the normal case takes 1.7 s.
> Nothing in the test recorded that, so nobody could tell whether the number was
> comfortable or one slow CI box away from red — and when it went red it
> reported the symptom rather than which of three causes produced it.
