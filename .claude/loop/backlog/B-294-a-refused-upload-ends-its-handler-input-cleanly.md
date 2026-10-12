---
status: open
round: 855
commit: f8523835
paths: [packages/core/rpc_dart/lib/src/rpc/streams/base_processor_responder.dart, packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_responder_transport_inbound.dart]
probe: packages/transport/rpc_dart_http2/.dart_tool/probe/r855_http2_request_cut.dart — P-323
reason: bench — seen in a probe built for another question; not yet measured on its own
rank: 4
---

# B-294 — a refused upload ends its handler input cleanly

In P-323 after round 855's fix, a client-stream request refused for ending
mid-frame answers the client INTERNAL, yet the `collect` handler still runs
to completion: `await reqs.toList()` returns `[]` (or `[x]`, the messages
before the cut) and the handler returns a value nobody receives.

The refusal ends the call through `_answerFramingViolation`, which emits an
`x-client-cancelled` frame. If the responder answers a client cancel by
CLOSING the handler's request stream, an upload handler cannot tell "the
client finished" from "the call was refused or cancelled", and acts on a
partial input as if complete: a handler that commits what it collected
commits a truncated upload. The client is told the call failed, so the two
sides disagree about whether the work happened.

## Next step

Measure on the channel transport first (core, every transport): cancel a
client-stream call mid-upload and record whether the handler's request
stream ends with done or with an error, and whether its return value is
used. Then the http2 refusal path.

## Owner decision

—
