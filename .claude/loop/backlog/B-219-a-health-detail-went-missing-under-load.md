---
status: closed (round 592)
round: 592
commit: 5d33d595
paths: [packages/transport/rpc_dart_websocket/lib/src/websocket_caller_transport.dart, packages/transport/rpc_dart_websocket/test/peer_ids_return_to_zero_test.dart]
probe: —
reason: "CONFIRMED by reading, as the lead prescribed: `health()` has TWO early returns (closed, disconnected) that answer without the wrapper's own counters, so the key is absent exactly while something is wrong. Fixed on all three answers; the test's `!` is gone too. Previously: observed once in a loaded gate run and not reproduced: health().details['peerStreamIds'] was NULL where the same call had returned 0 seconds earlier. `lib/` was byte-identical to its committed state, so it is not the round's change — but a diagnostic that can answer `null` for a key it documents is a defect in the diagnostic, and the test asserts through a `!`"
---

# B-219 — a health detail answered null under load

Seen during round 555's gate, which is the only reason it is written down.

```
test/peer_ids_return_to_zero_test.dart: WITNESS: the heartbeat does not fill the peer-id set
  Null check operator used on a null value
  test/peer_ids_return_to_zero_test.dart 102:48  _peerIds
```

`_peerIds` is `(await t.health()).details['peerStreamIds']! as int`. The SAME call three seconds
earlier in the same test returned `0` — so the key was present and then absent.

## What is already established

- **Not this round's change.** `git status` showed `lib/` byte-identical to its committed state;
  the only modified file was an unrelated core test.
- **Not reproducible on demand.** The file passes alone (5 of 5), and the full `test:unit` passed
  on the next run with websocket at `241`.
- **The machine was loaded**: `load average 9.62 12.68 11.07`, well above the `uptime` under 3
  that `config.md` names as the condition for reading an intermittent failure.

## Why it matters

Two separate things, and the smaller one is certain:

1. **The test asserts through `!`.** Whatever makes the key absent, the witness reports it as a
   null-check crash rather than as the fact it is about, which costs a reader the diagnosis.
   Cheap to fix and worth doing whoever is right about (2).
2. **`health()` may be able to answer without a key it documents.** If `details` is assembled
   from a transport that is mid-reconnect or closing, a diagnostic an operator polls would be
   missing a field rather than reporting a state — the same class as B-104's `health()` reading
   CLOSED during a recovery, which was a real defect.

## Witness a round would build

Read `health()`'s detail assembly in the websocket wrapper and find every path on which a key can
be omitted — then drive that state deliberately rather than waiting for load to produce it. If no
such path exists, the finding is about the TEST's timing and the `!` is still wrong.

Do not start by looping the gate: one reproduction under load costs minutes and says nothing a
reading of the assembly does not say faster.

## Measured — round 592, CONFIRMED by reading

The lead said not to start by looping the gate, and that was right. `health()`'s
assembly sets the key unconditionally after the spread, so it cannot be missing
there — which means the call returned from somewhere else. It did, from two early
returns above it:

```
_closed        RpcHealthStatus.closed(...)                            no details at all
_disconnected  RpcHealthStatus.degraded(details: {'supported': true})  no counters
```

Both exist for documented reasons — a closed transport must not delegate, and
`_inner` is already closed during a reconnect — and neither reason says anything
about the wrapper's own counters, the only thing in `details` no inner health can
see. They were dropped by omission on exactly the two answers a supervisor polls
for.

Reachable in that very test without touching it: the app-level heartbeat closes the
socket when a pong misses its one-interval deadline, which at `load average 9.62` is
what happened.

Fixed: the counters are assembled once (`_ownDetails`) and present on all three
answers, the degraded branch keeping its own `supported: true`. Canary — the counters
removed again — reads `Actual: <null>` and names the state: `degraded {supported:
true}`.

Claim 1 is also done: `_peerIds` no longer asserts through `!`, so the absence reads
as a failed expectation printing the level, the message and the whole map.

## What this lead does NOT cover

- No arm reproduces the crash under load; the lead forbade starting there.
- `_reconnectOnce`'s three other `RpcHealthStatus` returns are left alone — that is
  `reconnect()`'s result, reporting an ATTEMPT, with its own vocabulary.
- The other transports' wrappers were not asked the same question.

## Owner decision

—
