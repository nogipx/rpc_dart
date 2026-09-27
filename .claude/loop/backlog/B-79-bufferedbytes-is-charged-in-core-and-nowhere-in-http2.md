---
status: closed (round 459)
round: 444 — re-read against the tree, never measured
commit: 67303ea6
paths: [packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart, packages/core/rpc_dart/lib/src/endpoint/responder_streams.dart, packages/transport/rpc_dart_http2/lib/**]
probe: —
reason: cost — split out of B-70 item 20; whether http2 needs its own charge depends on what dart:io has already buffered
---

# B-79 — core charges bufferedBytes, http2 charges nothing

## CLOSED (round 459) — the evidence was false and the concern confuses two things

`checked/C-51`. **`maxBufferedBytes` appears TWICE in `rpc_dart_http2/lib`** —
`caller :1396` and `responder :627`, both passing the policy value into the parser,
whose null fallback is the same formula as `effectiveMaxBufferedBytes`. So the
per-stream buffer cap is applied there and agrees with core, set or unset.

And the residency charge is a different mechanism: `bufferedBytes` is a property of
`RpcTransportMessage`, and the site that charges it is `responder_pipeline.dart:1027`
— CORE, which every transport feeds. A transport with nothing of its own to charge
is the correct shape.

**The window that charge protects cannot open on HTTP/2 anyway.** It bounds payload
buffered before the method is KNOWN; the http2 responder takes `methodPath` from the
HEADERS frame and stamps it on every message, because in HTTP/2 the method is a
`:path` pseudo-header on the frame that opens the stream. A stream with payload and
no method is a channel-transport shape.

Left standing deliberately: http2 passes the raw nullable where core passes the
effective value. They agree only via the parser's repeated fallback — worth stating
one day, but no canary could kill the change, so it is recorded not shipped.

Still unmeasured: PEAK MEMORY, this lead's own counter-argument about `dart:io`
having committed the peak first.

Core meters `bufferedBytes` in five places and is explicit that metadata counts
toward it — `responder_pipeline.dart:934` and `responder_streams.dart:282` both
say so, the latter with the words "NOT payload.length".

**`bufferedBytes` does not appear anywhere in `rpc_dart_http2/lib`.**

So the same inbound shape is charged against a residency bound on a channel
transport and against nothing on http2.

**The counter-argument has to be measured, not assumed**, and it is the same one
`fromChannel` makes about oversized frames (`channel_transport.dart:207-213`): a
server on `dart:io` has already buffered the peak before this library sees a
byte, so charging it afterwards may be accounting for memory that is already
committed. If that holds, the answer is a doc line, not a counter.

RPC-17 is the lens — a limit that fires after residency is not a limit — and
C-29 has the scope of the stream limits. Read both first.

Bench: the same inbound burst over a channel transport and over http2, with the
policy bound low, reading the peak RSS and where the refusal comes from. The
interesting value is whether http2 refuses at all and at what point relative to
the bytes arriving.

## Owner decision

**Measure first, then apply uniformly** — the same call as B-75 and B-80, given
once for the class.

The measurement in the lead is the round, and it decides between two answers,
not one: if `dart:io` / `package:http2` has already committed the peak before
this library sees a byte, the answer is a DOC LINE, because RPC-17 says a limit
that fires after residency is not a limit. Adding a counter is NOT pre-approved
by this decision.

If http2 does need a bound, prefer the http2 flow-control window over a counter:
it prevents the residency instead of reporting it, and it does not introduce a
refusal the transport never produced. That shape needs its own measurement —
whether the window can be driven from the policy value at all — so treat it as
the second question, not the fix.

DECLINED: adding the counter without the measurement, and documenting it as
unsupported without one either.
