---
round: 866
commit: 1c565fdf
paths: [packages/core/rpc_dart/lib/src/rpc/streams/server/responder.dart, packages/transport/rpc_dart_isolate/lib/src/isolate_transport.dart]
scope: a zero-copy server stream over a real isolate whose third item cannot cross the port; not bidi on the isolate, not the web worker
---

# C-94 — an unsendable stream item ends the isolate stream there

Over a real isolate, a zero-copy server stream whose third item holds a
`Future` (unsendable) ends with INTERNAL after items 0 and 1, and nothing
after: round 862's stop on `isAnswered` reaches the direct-object path,
where the failure is `SendPort.send` throwing rather than a codec. With
that check switched off the same test reads `[0, 1, 3, 4]`. Witness
`packages/transport/rpc_dart_isolate/test/unsendable_direct_object_test.dart`,
"a stream item that cannot be sent fails the call, not just that item".

## Control

Round 862's server-stream check off: `Expected: [0, 1] Actual: [0, 1, 3,
4]`.
