---
file: packages/transport/rpc_dart_http2/.dart_tool/probe/bidi_endings_over_http2.dart
round: 385
commit: 8315658d
paths: [packages/transport/rpc_dart_http2/lib/**, packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart, packages/core/rpc_dart/lib/src/rpc/streams/bidirectional/**]
status: valid
---

# P-77 — C-41's endings over real HTTP/2, direct and over a round trip

## Why it exists

The third of the owner's transports, and the one where the shape maps onto
HEADERS/DATA/RST_STREAM rather than onto frames of the library's own design. Two
of the seven endings — `consumerCancel` and `tokenCancel` — go out as
RST_STREAM here, which is B-53's own primitive, so the `usable` column is not a
formality.

## Measures

As P-74: seven endings, three scales, `openStreams` / `activeResponders` / live
handlers / the caller's `activeStreams`, a unary call after every scale, then
`fullDuplex` and 8-way `concurrent`. Both links, the second through the same
Dart TCP relay.

## What it found, and the two changes that made it readable

The endings are clean on both links. The DUPLEX section killed the connection
over the latent link, and the first run could not say why: `concurrent` reported
eight identical `MISMATCH`es and the residue was dead.

Two changes turned that into a reading:

- **a fresh connection per duplex case**, so neither can be blamed for the
  other. It showed `fullDuplex` 30/30 CORRECT and then the connection dead —
  i.e. the death follows a call that SUCCEEDED;
- **a SEQUENTIAL arm** beside the concurrent one, eight calls one after the
  other. It died too, which removed concurrency as the variable and left the
  cancel timing, which P-78 then isolated.

A mismatch also had to say which KIND it was: short (the connection died
mid-run) or full-length-but-wrong (a demux fault). It was always short.

## Control

The unary arm, run on the same connection in the same run; and the direct link
as the control for the latent one — the same arms, the same code, differing only
in the relay.

## What it establishes, and what it does not

Establishes: no bidi ending retains state over real HTTP/2 on either link, and
full duplex preserves order on both. It does NOT establish that http2 is clean —
it is the bench that found B-53's ordinary trigger, which P-78 then isolated.

Does not cover packet loss, coalescing, dart2js or RSS.
