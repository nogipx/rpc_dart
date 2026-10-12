---
round: 859
commit: 6c31366f
paths: [packages/core/rpc_dart/lib/src/rpc/streams/base_processor_caller.dart, packages/core/rpc_dart/lib/src/rpc/transports/flow_controller.dart]
scope: the caller over a channel transport, ten server streams whose first message is undecodable and whose 60 KB second arrives in a later DATA frame (round 854's drop path); not http2, whose connection window package:http2 keeps
---

# C-90 — data dropped after a failed call returns its credit

Round 854 made the caller close a call at its first undecodable response
and drop later DATA undecoded. Those bytes still return their connection
credit: ten such calls granted 802306 B for 600180 B received, the same
margin over the bytes (the initial window) as ten whole ones. The transport
counts a DATA message consumed when the processor takes it, before the
processor decides to drop it. Bench
`../probes/P-319-connection-credit-after-cut-responses.md`, arm `bad-first`.

## Control

The same bench's `whole` arm, 600210 B received, 802333 B granted; its
recorded ablation (`_creditConnection` sending nothing) grants 262144 B.
