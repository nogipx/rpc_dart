---
round: 852
commit: 4209b1ba
paths: [packages/core/rpc_dart/lib/src/rpc/transports/flow_controller.dart, packages/core/rpc_dart/lib/src/rpc/streams/base_processor_caller.dart]
scope: the caller over a channel transport, ten server streams cut 59 KB into a 60 KB frame (round 846's INTERNAL path); not the responder's refusal of round 847
---

# C-87 — a cut response returns its connection credit

A response the caller ends INTERNAL because it was cut mid-frame (round 846)
gives its bytes back to the connection window like a whole one: ten such
calls returned 790 KB of credit for 590 KB received, the same margin over
the bytes (the initial window) as ten whole ones. The partial frame sits in
the caller processor's parser, past the transport message that carried it,
and that message counts as consumed. Bench
`../probes/P-319-connection-credit-after-cut-responses.md`.

## Control

`_creditConnection` sending nothing: 262144 B granted (the initial window
alone) for 600 KB received.
