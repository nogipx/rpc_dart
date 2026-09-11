---
refines: U-11
paths: [packages/core/rpc_dart/lib/**, packages/transport/rpc_dart_websocket/lib/**, packages/transport/rpc_dart_http2/lib/**, packages/transport/rpc_dart_isolate/lib/**, packages/transport/rpc_dart_http/lib/**]
applies: several transports share parts of one layer
breaks: "wrong result: a claim about a fix's blast radius that the code does not support. It reached two commit messages, and through them the decision not to check the neighbour."
applied: [340, 341, 342, 343]
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

## The cheaper form of the question — round 341

Reading for missing behaviours does not terminate. **Enumerating
`RpcSecurityPolicy`'s fields does**, and it asks the same thing: a field is
either enforced everywhere it applies, or it is a knob that does nothing
somewhere. One pass over ~14 fields against five transports found
`maxMetadataBytes` unenforced on `rpc_dart_http` — 960 000 bytes of headers
answered 200 OK against a 64 KiB bound.

The state of that enumeration, so the next round starts from it rather than
redoing it:

```
maxMessageLengthBytes, maxBufferedBytes,   parser, every transport      OK
  maxMessagesPerChunk
maxActiveStreams                           createStream + inbound       OK
maxHeaders, maxHeaderNameBytes,            validateMetadata             OK
  maxHeaderValueBytes, maxMethodPathLength   (http2 outbound: round 340)
maxMetadataBytes                           FIXED round 341; isolate
                                             exempt by trust boundary
halfOpenStreamTimeout                      responder pipeline, so all   OK
flowControl*                               shared layer; http2 native   OK
closeOnProtocolError                       channel transports + http2
                                             RESPONDER — NOT the http2
                                             caller. OPEN, needs a round
```

The one open cell looked like a genuine design question — whether a CALLER
should tear down its connection on a peer's protocol violation is not the same
decision as whether a server should. Round 342 took it and found the question
was the wrong one.

## The blind spot in the enumeration — round 342

`_validateInbound` does two things:

```dart
if (_policy.closeOnProtocolError || ++_policyViolations > _maxPolicyViolations)
```

**Only the first is a field.** The second is a 256-violation backstop — a
`static const int` and an `int` — so a field-by-field sweep cannot see it, and
the http2 responder's port had copied the half that had a name. Measured: 2000
violating header blocks accepted at the default policy, connection still open,
RSS up 27 MiB.

So the enumeration above is complete for what it enumerates and blind to
everything else. **After the field names, read the shared layer's method BODIES
for mechanisms that have no name**: constants, counters, caps, ordering
requirements. Those are the entries a hand-rolled port silently drops, because
there is nothing to grep for.

The role question turned out to have an answer already written in the code, at
`channel_transport.dart:268` — `closeOnOversizedFrame: !isClient`, "exactly the
wrong answer for a client, whose other in-flight calls die with the connection".
So the FIELD is role-sensitive and the BACKSTOP is not, which is how round 342
split them.

## Where the vein runs out — round 343

Applying the same reading to the OTHER unnamed mechanisms — the bounded
`_finishedStreams` and the gated `_statusSeen`, both there because an id can be
the peer's choice — came back CLEAN, and the reason generalises:

**A missing port only matters where the hand-rolled transport faces the same
threat.** The http2 caller and the http responder mint their own stream ids, so
the peer cannot name a key and the gating problem cannot arise. The http2
responder takes the peer's ids and bounds them with `maxActiveStreams` and
`SETTINGS_MAX_CONCURRENT_STREAMS` instead — a different mechanism for the same
job, which a "did they port it?" reading scores as a miss.

So the question to ask is not *did they copy this* but *do they face this, and
with what*. Full audit in `checked/C-37`. The three dimensions that terminate
are now worked out (fields 341, `_validateInbound`'s bodies 342, per-stream
state 343); what is left under this lens is open-ended reading.
