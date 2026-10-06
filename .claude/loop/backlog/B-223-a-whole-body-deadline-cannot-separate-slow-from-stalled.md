---
status: closed (round 673)
release: changelog
round: 673
commit: f3cc2e53
paths: [packages/transport/rpc_dart_http/lib/src/rpc_http_responder_transport.dart, packages/transport/rpc_dart_http/lib/src/rpc_http_server.dart]
probe: packages/transport/rpc_dart_http/.dart_tool/probe/b223_slow_versus_stalled.dart
reason: "bench — the mechanism is a reading (`readBody().timeout(...)` bounds the whole read) and the rig that would witness it DEADLOCKS the probe process; what a finite default costs an honest slow upload is unmeasured, which is why round 584 defaulted the policy and not the timeout"
---

# B-223 — a whole-body deadline cannot separate a slow upload from a stalled one

Split out of `B-150` in round 584, which took the policy default and left this.

## The shape

```dart
body = await readBody().timeout(bodyReadTimeout!, onTimeout: () => throw TimeoutException(...));
```

`bodyReadTimeout` bounds the ENTIRE body read, so it is a function of size times
throughput. A slowloris client that sends one byte and stops is refused — which
is what the knob is for — and so is an honest client uploading 16 MiB over a slow
link, at exactly the same deadline. The two are indistinguishable to a total
deadline and completely distinguishable to a per-chunk one.

That is why the knob has no default, and why round 584 did not give it one.

## What round 584 did establish

The DOCUMENTED objection to a finite default is about a short budget, not about
any budget. A client sending `Expect: 100-continue` waits out its own fallback
inside the budget because dart:io never answers the header:

```
bodyReadTimeout 500 ms, client waited 1 s   HTTP/1.1 408 Request Time-out
bodyReadTimeout  30 s, client waited 1 s   HTTP/1.1 200 OK
```

So the `100-continue` hazard does not block a generous default. The reason to
leave the knob null is the slow-link one above, and that reason is a reading.

## Why there is no witness yet

The arm is a client that uploads steadily and never stalls, under a budget
shorter than the upload's duration, and it should read `408` where the mechanism
is wrong and `200` where it is right. Written against a raw socket it deadlocks:
once the responder answers 408 and the server closes, the client is still writing
and `await socket.close()` never completes. `socket.destroy()` is the likely
remedy; it was not tried, because round 584's target did not need it.

## What a round owes this

**The witness above**, at two budgets, so "slow" and "stalled" are two arms rather
than one claim.

**Then the choice**, which is a design one and not a default one:

- a per-chunk idle deadline instead of a total one — reset a timer on each chunk,
  which is the bound that actually names slowloris. This is the candidate the
  current doc is groping for when it calls the trade-off "a policy one".
- both: an idle bound with a default, and the total deadline kept as an opt-in
  ceiling.
- nothing, with the slow-link cost written down.

`RpcHttpServer.bodyReadTimeout` passes straight through, so whatever is decided
covers both entry points.

## Outcome (round 673)

FIXED as decided. At a 2 s total an honest 4-second upload got the same 408 as
a stalled client; the new `bodyIdleTimeout` (default 30 s) passes it and
refuses the stall. `../rounds/673-a-slow-upload-is-not-a-stalled-one.md`.

## Owner decision

Round 673, after the witness: an idle bound with a default (30 s), the total
kept as an opt-in ceiling.
