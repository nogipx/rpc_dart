---
status: closed (round 605)
round: — (not re-measured) — filed by the external audit of 2026-09-28
commit: 8253fe8a
paths: [packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart, packages/core/rpc_dart/lib/src/rpc/streams/base_processor.dart, packages/core/rpc_dart/lib/src/rpc/streams/unary/caller.dart]
probe: none — static read, nothing run
reason: "DONE: streaming levels (603), five peer-triggerable responder warnings once per connection (604; the other two unreachable per round 515), and one caller record per genuine fault on every shape, the call's own catch, by the owner's choice (605: 2/2/3/0 -> 1/1/1/1)"
---

# B-124 — warnings a peer can trigger fire on every frame, and application errors log at error twice

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**high**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

CLAUDE.md: a warning a peer can repeat fires ONCE; these fire per frame: `Ignoring no-op frame for unknown stream`, `Refusing stream … concurrent-stream limit`, the pre-method refusal, the handler-limit refusal, `Message received but endpoint is not started`; `StreamProcessor.sendError` logs every status sent at error, and `UnaryCaller` logs every failed call at error twice.

## The shape

`packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart:685, 714, 776, 1049, 1256`;
`base_processor.dart:717`; `unary/caller.dart:337, 586`.

## Why it matters

Log flooding under a misbehaving peer, and an application NOT_FOUND reads as an
incident on both sides.

## Witness a round would build

Count records from 10k no-op frames on unknown ids (the logging test pattern in
`test/transports/flow_controller_logging_test.dart`).

## Fix sketch

One-shot bools for the peer-driven warnings; application statuses at debug.

## Round 515 tried and could not build the witness

**Still unverified — not refuted.** 10 000 hand-built no-op metadata frames on unknown
stream ids produced **zero** warnings. The frames never reach
`_processResponderMessage`: not even its first branch, "Message received but endpoint
is not started", which is the most trivially peer-reachable of the five sites and was
tried with the endpoint deliberately unstarted.

By reading, `_opensOrAdvancesStream` returns false for a metadata-only frame with no
`methodPath`, not end-of-stream, no payload and no `x-client-cancelled` header, so
`responder_pipeline.dart:739` should fire per frame. It fires never, so the frame is
gone earlier. Candidates not eliminated: the channel's `_validateInbound` dropping it
against the policy, the transport declining to route a metadata-only frame with no
known stream, or the pipeline not subscribing in the configuration the rig built.

Rig: `packages/core/rpc_dart/.dart_tool/probe/b124_peer_warning_flood.dart`.

**Whoever takes this next should get a real peer to send the frame** rather than
hand-building one — drive it from an `RpcCallerEndpoint` doing something malformed, or
find which layer drops it first by instrumenting the channel.

## Round 516 took the double-logging half — CONFIRMED and fixed

```
                               caller   responder      after
a handler throws NOT_FOUND        2          1         0 / 0
a call that succeeds              0          0         0 / 0   <- control
a handler throws INTERNAL         2          1         2 / 1   <- control
a handler throws StateError       2          1         2 / 1   <- control
```

Three `error` records for a server answering correctly. The caller's two came from
DIFFERENT sites — the non-OK trailer branch and the surrounding `catch` — which is
what the printed scope and message made visible.

`RpcStatus.isFault` now names the codes that mean something broke (UNKNOWN, INTERNAL,
UNAVAILABLE, DATA_LOSS) and the three sites consult it; a throw with no status counts
as a fault, since an unclassifiable failure is not an application answering.
**Deliberately narrower than `RpcCircuitBreakerInterceptor`'s health set** from round
501, which also counts DEADLINE_EXCEEDED and RESOURCE_EXHAUSTED — a breaker asks "is
this endpoint in trouble", this asks "did something break", and a slow server is not a
broken one. A guard pins the difference.

**Still not fixed: the caller logs twice for a genuine FAULT** (`caller 2` for
INTERNAL). The two records carry different information — status and message versus
method path and stack trace — so collapsing them loses something and needs a decision
about which site owns the report.

**And the streaming shapes are untouched**: `StreamProcessor.sendError` logs every
status sent at `error` and was not varied.

## The flooding half is what remains

It needs no peer-reachability argument. `StreamProcessor.sendError` logs every status
sent at `error`, and `UnaryCaller` logs a failed call at `error` twice — so an
application NOT_FOUND reads as an incident on both sides. One failing call and a
count confirms or refutes it, with none of the difficulty above.

## A method note this lead cost, now verified

`CLAUDE.md` says to test log guards by counting calls into a `LogScope` subclass.
**That does not survive a derived scope**: `LogScope.child()` constructs a plain
`LogScope`, so the override is lost as soon as the code under test derives one — which
`UnaryCaller`, `StreamProcessor` and `CallProcessor` all do. The cited worked example,
`flow_controller_logging_test.dart`, works only because the flow controller is handed
its scope directly.

Count by overriding `LogController.add` instead. It runs before filtering, so it keeps
the property the guidance wanted — "did the code decide to log", not "was a record
delivered".

## Round 603 — the streaming shapes

```
                 caller   responder    after
server-stream      2         2         0 / 0
client-stream      3         2         0 / 0
bidi               0         2         0 / 0
```

`../rounds/603-every-streaming-answer-was-an-incident.md`.

## Round 604 — the flooding half

A raw client transport reaches five of the seven sites; each warned `5` times for
five refusals and now warns `1`. Endpoint-not-started and the unknown-stream no-op
stay unguarded: round 515 could not reach them, so a guard would have no witness.
`../rounds/604-the-peer-chose-how-many-lines.md`.

## Round 605 — one record per fault

`unary 2, server 2, client 3, bidi 0` caller records for a genuine INTERNAL became
`1` on every shape. `../rounds/605-one-failure-one-record.md`.

## Owner decision

Round 605's session: the call's own catch record (error, method path, stack) owns
a fault's report; the trailer sites log at debug.
