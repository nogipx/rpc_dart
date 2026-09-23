---
round: 444
verdict: FIXED
packages: [rpc_dart]
lens: RPC-25
bench: P-98 — new
commit: yes
---

# Round 444 — the one merge site the reserved-header sweep never reached

## Target

The owner asked what is left in the backlog and named **B-70**. Its own last
section says there is nothing in it: round 419 wrote *"17 items remain … all of
them are duplication whose copies currently AGREE — the behavioural half of this
lead is now spent"*, and round 432 checked and agreed.

**That claim was never measured, and it is false.** 419 and 432 both READ, and
432 re-read only items 23 and 34 — the two a stale index line pointed at, both
already closed — then generalised to the other fifteen. So the round took the
claim rather than the lead: re-read the items 419 called agreeing, starting with
the three it itself set apart as *"the same shape as B-67"* (13, 36, 10).

**Item 5 is the counterexample and it is the whole scope.** The class is
"a site that merges a caller `RpcContext`'s headers into outbound request
metadata", counted BEFORE the fix by grepping every package the lens's paths
name: **three sites, two with the filter, one without.** That is small enough to
finish, so the scope is all three, not a subset.

```
  base_processor.dart:1256   CallProcessor._sendInitialMetadata   HAS the filter
  unary/caller.dart:401      UnaryCaller                          HAS the filter
  caller_pipeline.dart:325   ping()                               bare addAll
```

Items 13, 36 and 10 stay open and are re-described in the lead: they are real
and none is the same shape as this one.

## Hypothesis

`ping()` merges the caller's context headers with a bare
`headerMap.addAll(routingContext.headers)`, so a key in `RpcHeaders.reserved`
set through ordinary user metadata reaches the wire on the ping frame — where
the two siblings drop it. If any consumer acts on such a key, the same context
behaves differently depending only on the call shape.

## Before

Probe: `packages/core/rpc_dart/.dart_tool/probe/ping_reserved_headers.dart`
(bench **P-98**). Seven arms, one caller context per arm, over
`RpcChannelTransport` on a `RpcFrameMultiplexedChannel.pair()`.

```
A1 ping    content-type : status=3  Invalid content-type for gRPC
A2 unary   content-type : OK  timeout=null mark=carried
A3 ping    clean        : OK  status=0
A4 ping    grpc-timeout : OK  status=0
A5 unary   grpc-timeout : OK  timeout=null mark=carried
A6 ping    x-client-canc: OK  status=0
A7 ping    window-update: OK  status=0
```

A1 is the defect. **Two controls, and one would not have been enough**: A2 sends
the SAME context down the sibling shape and succeeds, so the context is not the
problem; A3 sends a clean context down the shape under test and succeeds, so
ping is not simply broken. `mark=carried` in A2 is the guard half — the filter
is key-selective, so a green arm cannot come from the context being emptied.

**A6 and A7 bound the severity, and they are measurements, not reassurance.**
The two reserved keys a peer ACTS on — `x-client-cancelled`, the window grants —
do travel on the ping frame (the canary below shows them arriving) and change
nothing, because `responder_pipeline.dart:778` and `flow_controller.dart:511`
both gate on `methodPath == null` and a ping frame carries one. So this is a
correctness defect on the keepalive path, not a flow-control hole.

## Mechanism

`RpcHeaders.reserved` holds eight keys that are protocol signals rather than
user metadata. Its own doc says what happens when one is settable from a
context: *"a context that happened to carry the key … killed its own call at the
door … it hung until its own timeout"*. The round that reserved the keys wrote
`cancellation_header_reserved_test.dart` — including a case named *"the control
keys never reach the wire, ordinary ones do"* — over the unary and streaming
shapes, and never over ping. The ping site kept its `addAll`.

The reachable consequence is `content-type`. A context built by forwarding an
inbound HTTP header map — the case the reserved-set doc names — carries
`content-type` on essentially every request. `RpcContext._sanitizeHeaders` drops
only keys starting with `:`, so it survives into the context; on ping it
overrides the base metadata's `application/grpc`, and the responder refuses at
`responder_pipeline.dart:859`. The same context works on every other call shape.

## After

Same probe, same bench. A1 flips; nothing else moves.

```
A1 ping    content-type : OK  status=0      <- was status=3
A2 unary   content-type : OK  timeout=null mark=carried
A3 ping    clean        : OK  status=0
A4 ping    grpc-timeout : OK  status=0
A5 unary   grpc-timeout : OK  timeout=null mark=carried
A6 ping    x-client-canc: OK  status=0
A7 ping    window-update: OK  status=0
```

## Canary

`if (false && RpcHeaders.isReserved(...))` in place, three times.

Witness 1, `ping survives a context that carries content-type`:

```
RpcStatusException(3): Invalid content-type for gRPC
```

Witness 2, `no reserved key from the context reaches the ping frame`:

```
Expected: not 'forged'
  Actual: 'forged'
content-type was settable as ordinary user metadata
```

The GUARD, `the same context still delivers its own header on a unary call`,
stayed green on both sides — the sibling shape is unaffected, which is the
asymmetry the round is about.

**Witness 2 was wrong first, and the canary is what showed it.** It originally
awaited the ping and asserted on the frame afterwards, so under ablation it died
at the content-type refusal before reaching the loop and the other seven keys
were never checked — L-15's mirror case, an ablation absorbed by a guard ABOVE
the one under test. The frame is recorded as it is SENT, so the assertions now
hold whatever the peer answers, and the failure quoted above is the header
assertion itself.

Third canary, unplanned: the ablated tree run under `test:web` fails both
witnesses on dart2js too, so the fix is not VM-only.

## Gate

```
melos run analyze                  SUCCESS (21 packages + rpc_dart_wasm)
melos run test:unit --no-select    SUCCESS (14 packages)
melos run format:check             SUCCESS
melos run license:check            1620/1620, REUSE compliant
melos run test:web                 All tests passed
fvm dart test -j 8   (rpc_dart)    +1654 ~1
fvm dart analyze lib test          No issues found!
```

**The gate was blocked mid-round by a full disk** (238 MiB free of 460 GiB), and
it is worth recording how the second failure read, because it did not say so.
`dart test` reported `No space left on device` outright; `test:web` reported
`worker_startup_failure_test.dart: loading …` — which is exactly the cold-Chrome
flake this repo's own script documents in a comment. Same cause, and the second
message names a known flake instead. It passed alone and as its own two-file
step, failed twice inside the full script at 8 GiB free, and passed inside the
full script at 33 GiB. The owner freed the space.

## Not fixed

**Items 13, 36 and 10 of B-70**, re-read against the tree this round and written
back into the lead with today's line numbers. They are open and none is the
shape this round closed — 419's "copies currently agree" does not describe them
either, which is the finding about the LEAD:

- **13** — `RpcContext` holds four private limits (`_maxHeaderCount` 128 and
  three more, `contracts/context.dart:11-14`) numerically equal to
  `RpcSecurityPolicy`'s defaults and wired to nothing. `_sanitizeHeaders`
  `continue`s past an over-long header and `break`s at the count or byte
  ceiling, discarding the remainder with no signal. A raised `maxHeaders` never
  reaches it. B-67's shape exactly: a knob that is monotone downward only.
- **36** — every policy default is written twice, in the constructor
  (`security_policy.dart:197-206`) and in `fromMap` (`:258-261`), literal
  repeated. Copies agree TODAY; the failure mode is a changed default.
- **10** — `_setupDeadlineMonitoring` exists once, in `CallProcessor`
  (`base_processor.dart:1321`, the CALLER side). `StreamProcessor`, the
  responder side, has no deadline disposer. Whether that is a defect needs a
  measurement this round did not take: the responder may bound the deadline
  elsewhere. **Not a "copies agree" item either way.**

Each needs its own bench, so taking them here would have meant three
unfinished threads instead of one closed one.

## Links

- Lens **RPC-25** — the same abstraction four times; applied and confirmed here.
  The instance is a site MISSING from a sweep, not a divergence between two
  written copies.
- Bench **P-98** — new.
- Lead **B-70** — item 5 closed; the lead stays open on 13, 36, 10 and the rest,
  and its "the behavioural half is spent" claim is corrected in place.
- **L-12** (sweep the class, not the sample) — applied, and this is another
  instance of what it is about: the round that reserved the keys wrote a witness
  over the shapes it had open and the third site was outside it.
- **L-15** — applied to the canary, second half (an ablation absorbed by a guard
  above the one under test).
- **L-14** — applied to the `test:web` failure, and it bit the other way round:
  the symptom matched a documented flake and the cause was the disk.
