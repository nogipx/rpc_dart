---
round: 459
commit: 071cd0e5
paths: [packages/transport/rpc_dart_http2/lib/**, packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart, packages/core/rpc_dart/lib/src/core/parser.dart]
scope: [rpc_dart_http2]
---

# C-51 — http2 does charge the buffered bytes, in the layer it shares

No bench: a read. The claim is about where a charge LIVES, so the answer is a call
graph.

> **Scope**: the two buffered-bytes mechanisms named below. It does NOT measure
> peak RSS under an inbound burst, which was the other half of B-79's bench idea.

## The claim that was checked

B-79: *"Core meters `bufferedBytes` in five places … `bufferedBytes` does not
appear anywhere in `rpc_dart_http2/lib`. So the same inbound shape is charged
against a residency bound on a channel transport and against nothing on http2."*

**The string does appear — twice — and the claim confuses two different
mechanisms.** Neither is missing on http2.

## What was read

**1. The per-stream parser buffer cap IS passed by http2.**

```
rpc_http2_caller_transport.dart:1396     maxBufferedBytes: _policy.maxBufferedBytes
rpc_http2_responder_transport.dart:627   maxBufferedBytes: _policy.maxBufferedBytes
```

`maxBufferedBytes` is nullable and defaults to null, and the parser's own fallback
is `maxMessageLength + RpcConstants.messagePrefixSize` (`parser.dart:111-113`) —
the SAME formula as `RpcSecurityPolicy.effectiveMaxBufferedBytes`. So core (which
passes `effectiveMaxBufferedBytes` explicitly) and http2 (which passes the raw
nullable) arrive at the same number, set or unset.

**2. The residency charge is not a transport's job, and lives where both meet.**
`bufferedBytes` is a property of `RpcTransportMessage` (`transport.dart:78`), and
the site that charges it is `responder_pipeline.dart:1027`, against
`_respMaxPreMethodBytes`. The pipeline is CORE and every transport feeds it,
http2 included — so the charge applies there without http2 naming it. A transport
with nothing of its own to charge is the correct shape, not a gap.

**3. The window that charge protects cannot open on HTTP/2 at all.** It bounds
payload buffered *before the method is known*. The http2 responder derives
`methodPath` from `extractMethodPath(message.headers)` on the HEADERS frame
(`:584`) and stamps it on every message it emits (`:588`, `:600`). In HTTP/2 the
method is a `:path` pseudo-header, so it arrives on the frame that opens the
stream, always before any DATA. A stream with payload and no method is a
channel-transport shape.

## Control

The read has a control in the same sense a grep does: the mechanism was looked for
in three places and found in all three, with the third explaining why the second
is unreachable rather than merely present. Had the pipeline charge been in a
transport rather than in core, or had http2 stamped `methodPath` only on the
headers message, the answer would have been the opposite — and both were checked
rather than assumed.

## Deliberately NOT changed

http2 passes `_policy.maxBufferedBytes`; core passes
`policy.effectiveMaxBufferedBytes`. They agree only because the parser repeats the
fallback formula. Making http2 pass the effective value would turn a coincidence
into a statement — **and it is a change no canary could kill**, because the
behaviour is identical. Round 366 dropped a guard for exactly that reason, so this
is recorded instead of shipped.

## What this does not say

Nothing about PEAK MEMORY. B-79's own counter-argument — that a server on
`dart:io` has already buffered the peak before this library sees a byte — is still
unmeasured, and remains the interesting question if anyone wants a number rather
than a call graph.
