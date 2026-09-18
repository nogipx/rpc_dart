---
file: packages/transport/rpc_dart_isolate/.dart_tool/probe/bidi_endings_over_isolate.dart
round: 385
commit: 8315658d
paths: [packages/transport/rpc_dart_isolate/lib/**, packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart, packages/core/rpc_dart/lib/src/rpc/streams/bidirectional/**]
status: valid
---

# P-76 — C-41's endings over a real isolate, serialized AND zero-copy

## Why it exists

P-74 took the endings and duplex cases to a real websocket. The isolate is the
owner's second transport and the one whose channel is not a socket at all:
SendPort/ReceivePort, frames that are `_IsolateMessage`s. It is also the only
transport with a ZERO-COPY path, a second branch through
`_ensureBidirectionalResponder` that no endings matrix had ever run.

## Measures

The same seven endings, three scales, duplex and 8-way concurrency as P-74 —
then all of it again with the codecs removed.

The counters cannot be read from the test side: the responder lives in another
isolate. A unary `stats` method reports `openStreams`, `activeResponders`, the
handler's live count and the transport's `activeStreams`/`streamControllers`/
`statusSeen` over the wire, which doubles as the check that the connection still
works after each ending.

**The baseline is 1, not 0**, because the stats call owns a stream while it
runs. That is what the unary arm is for — it establishes the baseline in the
same run rather than by argument.

## Control

Three. The unary arm fixes the baseline. The `deadline` row is the sensitivity
proof — the one arm that reads above baseline, so the instrument demonstrably
reports retention. And the serialized pass is the control for the zero-copy
pass: same endings, same scales, same worker, differing only in whether codecs
were given.

## The numbers (round 385)

Every arm at baseline in both modes, `deadline` at +5 / +12 / +12 in both,
`fullDuplex` 30/30 order preserved in both, `concurrent` 8 of 8 clean in both,
`usable` everywhere. The two modes agree in every cell.

## What it establishes, and what it does not

Establishes: no bidi ending retains state over a real isolate, duplex ordering
holds, eight concurrent calls do not cross-talk, the connection stays usable —
and the zero-copy path behaves identically to the serialized one on all of it.

Does not cover latency, which has no analogue here and was NOT simulated: an
isolate port is not a link. Nor RSS, nor a worker that dies mid-call, nor
payloads large enough to engage flow control.
