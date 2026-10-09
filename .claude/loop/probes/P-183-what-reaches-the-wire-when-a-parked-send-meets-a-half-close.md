---
file: packages/transport/rpc_dart_http2/.dart_tool/probe/b184_parked_send_then_finish.dart
round: 558
commit: 79fb3ffb
paths: [packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_common.dart, packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart]
status: valid
---

# P-183 — what reaches the wire when a parked send meets a half-close?

## Why it exists

`RpcHttp2OutgoingPump` parks a send while the peer's window is closed, so a request does not settle
in package:http2's outgoing queue. B-184 claimed two ways that parked send disappears while
reporting success — a half-close arriving meanwhile, and the pump being disposed — and nothing had
been run.

The question is not "does it break" but **what reaches the sink, in what order, and what the parked
future told its caller**. Those are three different observables and a single pass/fail would have
answered none of them.

## The harness

A fake `http2.ClientTransportStream` whose outgoing sink nothing listens to, so `addStream` applies
backpressure and the pump parks. `drain()` starts listening, which is what opening the peer's window
looks like from here.

**The peer's closed window needs no http2 machinery**, and that is why this probe is a unit rather
than a server rig: the pump parks because its controller's subscription is paused, so a sink that
does not drain reproduces the state exactly.

Each arm records the sink's contents in order AND how the parked `add` ended — returned or threw.

## The numbers (round 558)

Before:

```
  CONTROL drains throughout            data 64B eos=false, data 0B eos=true
  parked send, then endStreamNow()     data 0B eos=true        <- payload GONE
      the parked add: returned=true threw=null
  parked send, then dispose()          NOTHING
      the parked add: returned=true threw=null
```

After:

```
  parked send, then endStreamNow()     data 64B eos=false, data 0B eos=true
  parked send, then dispose()          NOTHING
      the parked add: returned=false threw=RpcStatusException(14): HTTP/2 stream 1
                                        was torn down before the message could be sent
```

## Measures

Sink contents in arrival order, and the parked future's outcome. Nothing numeric: the finding is a
missing frame and a wrong success.

## Control

**`CONTROL drains throughout`**, which is what separates "the payload was dropped" from "this rig
never delivers payload". It reads `data 64B, data 0B` — both frames, in order — so the single-frame
row below it is a loss and not an artefact.

The `dispose()` arm is its own control for the fix's second half: the sink is EXPECTED to stay
empty there, because the owner is tearing the stream down. What had to change is only what the
caller is told, so an arm that merely counted frames would have called that case correct.

## What it establishes, and what it does not

Establishes both of the lead's pump claims, and that the first is silent request truncation: a
64-byte payload vanishes and the send reports success.

Does NOT establish the third claim — that `sendMessage` re-adds a stream id to `_halfClosedLocal`
after its await, leaking one entry per stream. That is the caller transport's bookkeeping rather
than the pump's and needs a different rig; it is left on the lead.

Does NOT drive a real server. The states are reproduced at the pump, which is where both defects
live; an end-to-end client-stream against a handler that never reads would exercise the same
mechanism through more layers and was not built.

## Reading

rpc_dart_http2 — **records three observables, not a verdict**: the sink's
contents in arrival order, and whether the parked send returned or threw.
`parked send, then endStreamNow() -> data 0B eos=true` against a CONTROL of
`data 64B, data 0B` is what makes the missing frame a loss rather than a rig
that never delivers. Needs no server: the pump parks because its controller's
subscription is paused, so a sink nothing listens to reproduces a closed peer
window exactly. The `dispose()` arm is its own control for the second half —
the sink is EXPECTED to stay empty there, so an arm that only counted frames
would have called that case correct. Does not cover the lead's third claim
(`_halfClosedLocal` leaking an entry per stream), which is the caller
transport's bookkeeping.
