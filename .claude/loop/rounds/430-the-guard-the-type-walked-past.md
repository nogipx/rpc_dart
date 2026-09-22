---
round: 430
verdict: FIXED
packages: [rpc_dart, rpc_dart_http, rpc_dart_http2, rpc_dart_websocket, rpc_dart_isolate, rpc_dart_wasm]
lens: RPC-04
bench: P-09 — reused
commit: yes
---

# Round 430 — the guard the type walked past

## Target

**B-21**, last of the four the owner listed, and a decided breaking change:
declare `IRpcReconnectableTransport` and make it `RpcClientConnection`'s
`transportFactory` return type.

RPC-04 — a capability hidden by a wrapper — because that is the defect the type
exists to make impossible.

The decision names three steps and says the third is the one that can go wrong:
**re-check the claim that it fixes nothing currently broken.** It does not go
wrong the way the lead expected.

## Hypothesis

Two claims to check, not one. The lead states both:

1. *"It fixes nothing that is currently broken"* — the runtime refusal is loud,
   early and self-explanatory.
2. *"Round 224's runtime refusal stays either way — the type is the earlier
   warning, not a replacement for the guard."*

## Before

**Claim 1 holds.** P-09 reused unchanged, control repeated first:

```
factory returns          came online   reason names it   handlers ended
the transport itself     yes, id 3     n/a               0 -> 0
a plain decorator        NO, refused   true              0
```

Identical to what round 224 left. Nothing is broken today.

**Claim 2 is false**, and the analyzer plus the suite say so together. With the
typed factory in place, a transport without the cursor can only arrive by
defeating the type, and the implicit downcast throws BEFORE the value reaches
the `is!` guard. Measured on round 224's own witness:

```
                        round 224      through the type
state                   Disconnected   RpcClientConnecting
transports built        1              2 and counting
reason names remedy     yes            no -- a bare TypeError
```

The type does not preserve the guard. It walks past it, and the failure
DEGRADES from a one-shot refusal into the backoff spin round 224's GUARD test
was written to prevent.

## Mechanism

`implements` in Dart is nominal. A class implementing `IRpcTransport` and
`IRpcStreamIdSequence` separately is NOT a subtype of an interface declared as
implementing both — so every transport must name the marker, and everything
that merely declares `IRpcTransport` in a signature stops compiling even when
the object behind it conforms.

That is what found the three erased entry points below. It is also why the
non-conforming case becomes a cast, and a cast throws where the guard cannot see
it.

## After

The analyzer enumerated the whole surface — **39 sites, and exactly one was in
library code once the four caller transports named the marker**:

```
declare IRpcReconnectableTransport   RpcChannelTransport, RpcHttpCallerTransport,
                                     RpcHttp2CallerTransport,
                                     RpcWebSocketCallerTransport
declared type ERASED the capability  RpcInMemoryTransport.pair
  (the object always conformed;      RpcIsolateTransport.spawn  (x3 variants)
   the signature said otherwise)     RpcWasmTransport.fromBridge
consequence of leaving them          a factory using any of them would not
                                     compile, on code that works today
rpc_dart's resilience tests          32 sites, all test doubles
```

`rpc_dart_log` was the only first-party LIBRARY caller affected, and it went
green the moment `RpcWebSocketCallerTransport` named the marker.

And the owner's decision on what the measurement found: **ship the type AND
restore the one-shot refusal.** `RpcClientConnection` now catches `TypeError`
from the factory as non-transient and emits the same `RpcClientDisconnected`
naming the two members to forward.

```
P-09 after                          identical to before
the transport itself     yes, id 3     n/a               0 -> 0
a plain decorator        NO, refused   true              0
```

A bench whose readings did not move is the evidence here: the compile-time
error is new, and nothing about the runtime behaviour changed.

## Canary

The ablation is the round's own first attempt, kept as the record:

```
without the TypeError catch     round 224's witness failed with
                                "Expected: <Instance of 'RpcClientDisconnected'>
                                   Actual: <Instance of 'RpcClientConnecting'>"
                                and its GUARD with "Expected: <1> Actual: <2>"
```

Both of 224's guarantees — refused once, and the reason names the remedy —
fail without it and pass with it. The other seven tests in that file stayed
green throughout, which is what says the catch is scoped to the wrong-type case
and not swallowing ordinary connect failures.

## Gate

```
melos run analyze        SUCCESS, 21 packages + rpc_dart_wasm
melos run test:unit      SUCCESS
melos run test:web       SUCCESS -- 12 dart2js suites, 0 failures
melos run format:check   SUCCESS
melos run license:check  compliant, 1605/1605
P-09                     re-run, readings unchanged
```

## Not fixed

**The runtime guard below the await is now unreachable from sound Dart**, and it
stays. It is the second line for `dynamic`, JS interop and casts — the same
callers the `TypeError` catch serves — and deleting it would leave that path
resting on one mechanism.

**Every third-party transport that implements both interfaces separately stops
compiling**, even though it works. That is the cost of a nominal marker and it
is not avoidable; the error names the interface to add. It belongs in the
major's changelog, which is the owner's domain and outside this round.

**The two witnesses that drive the non-conforming case now need a deliberate
`dynamic` hop** — P-09's decorated arm and
`client_connection_stream_ids_test`'s refusal group. Both say so in place. A
reader who does not know why would reasonably delete the cast and silently lose
the arm.

## Links

- B-21 — closed, and its second claim refuted by measurement before it shipped
- RPC-04 — the capability a wrapper hides; the type is that lens's fix in
  compile-time form
- P-09 — reused, control repeated first, readings unchanged after
- round 224 — the runtime refusal this round nearly walked past
- L-13 — fourth round running where the decision's premise was the thing to
  check. Here ONE of two claims held and the other did not
