---
round: 418
verdict: FIXED
packages: [rpc_dart, rpc_dart_framework]
lens: RPC-04
bench: none — both defects are a capability that EXISTS and cannot be reached
  from where it is needed; the evidence is two ablations, each restoring the
  unreachable version and failing a named witness
commit: yes
---

# Round 418 — the drain the interface could not ask for

## Target

**B-68 and B-69**, both parked as `owner decision` on the same objection —
widening a public interface, and changing what an unknown number of existing
tests exercise — and both answered by the owner's "backward compatibility does
not matter".

They are one shape: RPC-04, a capability present in the implementation and
unreachable through the type the caller holds.

## Hypothesis

Two small edits: widen a signature, pass a flag.

Held for B-69 (one argument). For B-68 the edit is small and the ORDER is the
actual fix — see below.

## Before

```
IRpcServer.stop()                     declared with no drainTimeout
rpc_http_server.stop(drainTimeout:)   implemented it
rpc_http2_server.stop(drainTimeout:)  implemented it
rpc_websocket_server.stop(...)        implemented it
RpcApp holds an IRpcServer            so it could only reach the hard stop

RpcFrameMultiplexedChannel            closeOnOversizedFrame = true  (SERVER)
  .pair() client half                 ... and production clients get false
```

## Mechanism

**B-68 is an ordering defect, and the unreachable parameter is why.** `RpcApp`
compensated for the narrow signature by draining the endpoints itself:

1. `ep.drain(timeout:)` on every endpoint — **nothing had stopped the
   LISTENER**, so a connection arriving in that window got an already-draining
   endpoint;
2. `module.onStop()`;
3. `server.stop()` — the listener, finally.

And `RpcEndpointBase.drain` is the heavier of the two operations: it CANCELS
active contexts, which is the opposite of letting in-flight work finish. The
websocket server documents exactly that as the reason round 414 gave it
`markDraining()` instead — and `RpcApp` called the one that comment warns
against.

**B-69 is a defect in the WITNESS**, which is the class with the least defence.
`fromChannel` picks the oversized-frame policy by side and argues it: a server
closes because the peak is already resident; a client must not, because killing
the connection takes every other in-flight call with it. `pair()` made no such
choice, so both halves took the constructor default — the server's — and the
frame-codec harness handed every suite a "client" that would kill its
connection.

## After

`IRpcServer.stop({Duration? drainTimeout})`. `RpcApp` asks the SERVER to drain
and does it FIRST, so a handler finishing in the window can still reach what its
module owns; `_drainEndpoints` is gone. `pair()` passes
`closeOnOversizedFrame: false` to the client half.

**The full suite was green before the B-69 fix and after it.** That is the
finding, not a gap: the lead predicted the blast radius was bounded — the flag
reaches `_refusedFrameHeader` and `onMalformedMetadata`, both the refuse-the-
stream half, and neither is reachable from a `pair()` client today. So nothing
was asserting the wrong half yet. What the fix buys is that a future change
breaking the client's "fail the stream, keep the connection" behaviour will now
be caught instead of passing.

## Canary

```
fix switched off                    witness failed with
RpcApp's drainTimeout argument      "the app asks the SERVER to drain, with its
                                    configured budget"  Expected: 0:00:07.000000
                                    Actual: <null>
pair()'s client flag                "pair() gives the client half the CLIENT
                                    policy"  Expected: false  Actual: <true>
```

Both CONTROLs and both GUARDs stayed green under their own ablation — the
ordering assertion, `fromChannel` still choosing by side, a second `stop()`
being a no-op, and the bare constructor still defaulting to the server's policy.

**What the interface widening actually cost, measured rather than estimated**:
six test fakes across `rpc_dart_framework` implement `IRpcServer` and every one
needed the new parameter. That is the whole of the breaking cost B-68 was parked
on, and it is confined to one package.

## Gate

```
melos run analyze        SUCCESS, 21 packages + rpc_dart_wasm
melos run test:unit      SUCCESS
melos run format:check   SUCCESS
melos run license:check  compliant
melos run test:web       SUCCESS — dart2js
```

## Not fixed

**The B-69 witness is a STATE assertion, not a behavioural one.** It reads
`closeOnOversizedFrame` off both halves of `pair()`. What the flag DOES is
witnessed separately by `oversized_frame_is_per_call_test` — which builds its
channel by hand and passes the client value explicitly, and that is precisely
why this went unnoticed for so long: the behaviour was covered through a channel
nobody constructs that way in production, while the factory everything else uses
set it the other way. Driving an oversized frame end-to-end through `pair()`
would be the stronger test and was not written.

**`RpcApp` no longer calls `endpoint.drain()` at all.** If a server's
`stop(drainTimeout:)` does not stop admitting, the app no longer compensates.
All three first-party servers do (websocket since round 414); a third-party
`IRpcServer` that ignores the parameter now silently gets no drain.

## Links

- B-68, B-69 — both closed here
- RPC-04 — a capability hidden behind the type the caller holds
- round 414 — gave the websocket server `markDraining()`, which is the operation
  `RpcApp` should have been asking for all along
