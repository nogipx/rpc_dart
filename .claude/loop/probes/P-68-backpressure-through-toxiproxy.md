---
file: packages/transport/rpc_dart_websocket/.dart_tool/probe/backpressure_under_latency.dart
round: 378
commit: c6e5b662
paths: [packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart, packages/core/rpc_dart/lib/src/rpc/streams/bidirectional/**, packages/core/rpc_dart/lib/src/rpc/streams/server/responder.dart, packages/transport/rpc_dart_websocket/lib/**]
status: valid
---

# P-68 — back-pressure through toxiproxy

## Why it exists

Rounds 370, 371 and 374 each found a missing pause and measured the fix on
`RpcChannelTransport.pair()`. P-58's lesson is that an in-process pair flattens
anything the size of a round trip, and back-pressure is exactly that kind of
question — so those three numbers described the pipeline and not a link.

P-58 answered its own question with a hand-written delaying TCP relay. This one
uses **toxiproxy**, at the owner's suggestion: it is the same latency in the same
place, from a tool that also has bandwidth, slicing and jitter if a later round
needs them.

## The rig

`ghcr.io/shopify/toxiproxy:2.12.0` in its own container — NOT the one already
running for another project, whose single exposed proxy is in use. API on
`127.0.0.1:18475`, proxy listening on `19801`, upstream
`host.docker.internal:19901` where the Dart websocket server binds. A `latency`
toxic of 50 ms on each stream, so 100 ms RTT.

**Reach it over IPv4 explicitly.** `curl http://localhost:18474/...` returns
`000`; `curl -4 http://127.0.0.1:...` returns 200. `localhost` resolves to `::1`
first, which is the same trap the repo's own `test:web` script works around with
`NODE_OPTIONS=--dns-result-order=ipv4first`.

Removed after the run; the other project's proxy verified unchanged.

## Measures

How many messages the library pulled out of the handler's generator while the
consumer was not reading, counted inside that generator, at 2.5 s. Two arms —
the endpoint's bidi pump (round 374's subject) and server-stream, the sibling
that has forwarded pause all along — each run twice: direct, and through the
proxy.

## Control

Three, and the round needs all three.

**Direct vs proxied**: the same arm on the same server, differing only by the
link.

**The sibling**: `serverStream`, unchanged across every cell, so a moving
`bidiPump` is not the rig moving.

**Ablation**: every value is a good one, so round 374's pause forwarding was
switched off:

```
arm           link              fixed   ablated
bidiPump      direct              70      2000
bidiPump      toxiproxy 100ms     70      2000
serverStream  direct              74        70
serverStream  toxiproxy 100ms     70        70
```

The defect is visible THROUGH THE PROXY, which is what makes the latency rig
sensitive rather than merely slower.

## The numbers (round 378)

```
arm           link              produced of 2000     MB
bidiPump      direct                  70            1.1
serverStream  direct                  74            1.2
bidiPump      toxiproxy 100ms         70            1.1
serverStream  toxiproxy 100ms         70            1.1
```

## What it establishes, and what it does not

Establishes: the pause forwarding holds over a link with a real RTT, and the
bound is the window either way. **Latency does not change this answer**, which is
the opposite of what it did for P-58's parking question — so the in-process
numbers in rounds 370/371/374 stand.

Does not cover bandwidth limits, packet slicing or jitter, all of which this rig
could now add. Nor http2 or isolate under latency.
