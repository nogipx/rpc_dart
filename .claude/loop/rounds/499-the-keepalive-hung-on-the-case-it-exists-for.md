---
round: 499
verdict: FIXED
packages: [rpc_dart]
lens: RPC-14
bench: P-137 — new
commit: yes
---

# Round 499 — the keepalive hung on the case it exists for

## Target

B-108, fifteenth in the audit's rank and the first past the damage-class leaders.

Lens RPC-14 — a timeout that drops the wait but not the work — read in its
mirror: here the WAIT itself was never bounded, on the one path whose whole
purpose is to notice a peer that has stopped answering.

## Hypothesis

`ping()` pre-checks the context once and then ignores it: the deadline is sent as
`grpc-timeout` but not enforced locally, and the token is not listened to. Also
that the RTT comes from two wall-clock readings and the completer is unlistened
across an await. Refuted if the deadline bounded the wait after all.

## Before

```
                              time      outcome
timeout: 200ms                 222ms    TimeoutException
context deadline 200ms        3003ms    TimeoutException   <- the PROBE's budget
token cancelled at 200ms      3002ms    TimeoutException   <- the PROBE's budget
nothing asked                 3002ms    TimeoutException   <- correct
CONTROL, a peer that answers    32ms    ok
```

Probe: `packages/core/rpc_dart/.dart_tool/probe/b108_ping_ignores_context.dart`

Two of the four claims confirmed by measurement, against a peer that accepts the
ping and never answers. The rows at 3 s are the probe giving up, not the library.

## Mechanism

`routingContext.cancellationToken?.throwIfCancelled()` and `isExpired` run once,
before the send, and nothing reads either again — `execute` bounds the wait only
`if (timeout != null)`, and `timeout` is the explicit argument alone. So the two
ways a caller normally expresses "stop waiting" both reached the wire as a header
and stopped there.

## After

```
context deadline 200ms         204ms    TimeoutException
token cancelled at 200ms       203ms    RpcCancelledException
nothing asked                 3004ms    unchanged
CONTROL, a peer that answers    20ms    ok, rtt sane
```

Three changes, each the shape its neighbours already use:

- `effectiveTimeout = timeout ?? routingContext.remainingTime` — the explicit
  argument still wins, because it is this call's own bound where the deadline
  belongs to the context.
- `execute` takes a `cancellationToken` and completes with
  `RpcCancelledException` when it fires, cancelling that subscription in the same
  `finally` as the stream's.
- the round trip comes from a `Stopwatch`. `sentAt`/`receivedAt` stay on the
  result because they are what went on the wire.

And `completer.future.ignore()` before the awaited send — the pattern
`UnaryCaller` was given after an unlistened completer killed an isolate.

## Canary

Three halves, three canaries, each failing on its OWN witness and leaving the
others green:

- `effectiveTimeout = timeout` — the deadline witness fails, `Expected: a value
  less than <1500> / Actual: <3016>`.
- `roundTrip: receivedAt.difference(sentAt)` — the clock witness fails,
  `Expected: a value less than 0:00:05.000000 / Actual: 1:00:00.012557`.
- `if (cancellationToken != null && 1 < 0)` — the token witness fails,
  `threw TimeoutException: Future not completed`.

The clock witness is the one worth keeping: `sentAt` is a constructor parameter,
so injecting a value an hour in the past stands in for a wall-clock step that no
test can cause.

## Gate

`melos run analyze` SUCCESS over 21 packages plus rpc_dart_wasm;
`melos run test:unit --no-select` SUCCESS; `melos run format:check` SUCCESS;
`melos run license:check` compliant.

## Not fixed

**The unlistened-completer race is reasoned, not witnessed.** `.ignore()` is
shipped because the pattern is established in `UnaryCaller` and the cost there was
a dead isolate, but nothing here drives an error arriving while `sendMetadata` is
still awaiting. It is the one change in this round with no failing test behind it.

**A ping with no bound still waits forever**, which the GUARD pins deliberately:
inventing one would answer B-107's policy question by the back door.

## Links

Lens RPC-14. Bench P-137 (new). Lead B-108 (closed). B-107 owns the question of
whether an unbounded call should be bounded at all.
