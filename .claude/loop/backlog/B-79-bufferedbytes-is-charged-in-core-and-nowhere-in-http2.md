---
status: open
round: 444 — re-read against the tree, never measured
commit: 67303ea6
paths: [packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart, packages/core/rpc_dart/lib/src/endpoint/responder_streams.dart, packages/transport/rpc_dart_http2/lib/**]
probe: —
reason: cost — split out of B-70 item 20; whether http2 needs its own charge depends on what dart:io has already buffered
---

# B-79 — core charges bufferedBytes, http2 charges nothing

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

—
