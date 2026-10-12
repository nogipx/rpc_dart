---
file: packages/core/rpc_dart/.dart_tool/probe/r863_response_sink_send_failure.dart
round: 863
commit: 911fe219
paths: [packages/core/rpc_dart/lib/src/rpc/streams/bidirectional/responder.dart, packages/core/rpc_dart/lib/src/core/sink_pump.dart]
status: valid
promoted: packages/core/rpc_dart/test/streams/a_response_sink_send_failure_ends_the_call_test.dart
---

# P-330 — a response-sink send that fails

`fvm dart run <file> <bad|control>` from the repo root. A low-level
`BidirectionalStreamResponder` on a memory pair (the rig of
`response_sink_error_reaches_the_client_test`), whose response codec
throws on `'bad'`. The handler drives `responseSink.addStream(x, bad, y,
z)` and closes it. Prints what the `BidirectionalStreamCaller` read and how
its call ended.

## Measures

Whether a response the responder cannot put on the wire ends the call at
that point on the responseSink path.

## Control

`control` (x, y, z): `[x, y, z], ended OK`.
