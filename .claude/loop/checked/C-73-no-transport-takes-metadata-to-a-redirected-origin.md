---
round: 808
commit: c1a97ff4
paths: [packages/transport/rpc_dart_http/lib/**, packages/transport/rpc_dart_http2/lib/**, packages/transport/rpc_dart_websocket/lib/**]
scope: the default client of http, http2 and websocket against a 303 and a 307 to another origin; not proxies, not the compressed websocket path (B-286)
---

# C-73 — no transport takes metadata to a redirected origin

The I-10 row of the matrix
(`packages/test/rpc_dart_conformance/test/i10_metadata_stays_with_its_origin_test.dart`):
the dialed server answers 303 or 307 with a Location on another origin, a
bare socket counting connections. On http, http2 and websocket the other
origin gets 0 connections and the call fails; channel and isolate dial no
origin and are skipped as not applicable.

## Control

With round 807's `followRedirects = false` switched off in the http caller,
`http | a 303 to another origin` fails `Expected: <0> Actual: <1>`. The
compressed websocket cells, KNOWN FAILING for B-286, fail the same way under
`--run-skipped`. Every cell asserts the dialed server was reached, so a
call that never left cannot pass.

Not re-checkable by a reading: http2 passes because package:http2's client
has no redirect logic; a client library that adds one would be caught here.
