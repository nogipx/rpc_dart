---
refines: U-11
paths: [packages/core/rpc_dart/lib/**, packages/transport/rpc_dart_websocket/lib/**, packages/transport/rpc_dart_http2/lib/**, packages/transport/rpc_dart_isolate/lib/**, packages/transport/rpc_dart_http/lib/**]
applies: several transports share parts of one layer
breaks: "wrong result: a claim about a fix's blast radius that the code does not support. It reached two commit messages, and through them the decision not to check the neighbour."
applied: [340]
status: confirmed (round 150, off-journal)
---

# RPC-10 — A shared layer does not reach every neighbour

## Shape

A fix in a shared layer looks like it covers every transport, while some of them
use only half of that layer.

## Detector

The map «which transport uses which layer». Two DIFFERENT layers both get called
"the channel transports", and conflating them is the whole defect:

```
    RpcChannelTransport            RpcFrameMultiplexedChannel
    (streams, policy, flow ctl)    (9-byte framing over a byte pipe)
    ---------------------------    ---------------------------------
    websocket    YES               websocket    YES
    wasm         YES               wasm         YES
    isolate      YES               isolate      NO  <-- its own
                                                     IRpcMultiplexedChannel
                                                     over SendPort/ReceivePort
    http2        NO (own)          http2        NO
    http         NO (own)          http         NO
```

So a fix in the FRAMING layer reaches websocket and wasm ONLY; a fix in
`RpcChannelTransport` does also reach isolate.

## Ask

Which packages ACTUALLY go through the class that changed?

## Evidence

The radius was overstated in two commits in a row — round 188's
malformed-metadata skip and round 189's `_maxMalformedMetadataFrames` are
framing-layer fixes, and the commit text for 188 and 190 says "websocket and
isolate too". **That is wrong for isolate**: there are no bytes to malform
there. The source comments never made the claim; only the commit text, which
cannot be edited.

**And even the `RpcChannelTransport` half is unreachable through the library's
own API on isolate** (measured round 197). A worker calling `sendMetadata` with
200 headers against a `maxHeaders` of 128 gets `ArgumentError` from the OUTBOUND
check in `RpcChannelTransport.sendMetadata`; the host never sees it —
`delivered=0`, `refused=0`, host transport still open. To violate inbound policy
there, a peer must write raw to the `SendPort`, bypassing rpc_dart, which for an
in-process isolate already means arbitrary code in your own process. **The trust
boundary is genuinely different from a network transport's.**

> **Corollary for probes, and it is why this matters beyond commit hygiene:** a
> forged-frame battery aimed at isolate measures nothing and LOOKS CLEAN — every
> row reads `delivered=0`, including the control. A green result from the wrong
> transport is worse than no result.

Imported from private memory after round 238; the map and the round-197
measurement had no home in the journal.

## Applied, round 340 — the map still holds, and it paid

Re-verified before use rather than trusted: every cell above is unchanged on the
current tree. The lens then found its first defect by turning the question
around — not *does a shared-layer fix reach everyone*, but **what does a
transport that bypasses the shared layer have to re-implement, and did it?**

`RpcChannelTransport.sendMetadata` validates outbound metadata against the
security policy. `rpc_dart_http` ported that to both halves; `rpc_dart_http2`
never did, so `maxHeaders`, `maxHeaderValueBytes` and the name/path rules were
enforced inbound only on that transport.

**The detector for the next one is already written in the code**: http2 carries
comments naming `RpcChannelTransport` behaviours someone noticed were missing and
ported by hand — `createStream`'s `maxActiveStreams`, `finishSending`'s
idempotence. Each is an entry on a list nobody has enumerated. Read
`RpcChannelTransport`'s method bodies as that list.
