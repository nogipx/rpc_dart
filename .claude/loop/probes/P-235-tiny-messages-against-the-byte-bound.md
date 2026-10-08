---
file: packages/transport/rpc_dart_http2/.dart_tool/probe/r719_tiny_messages_past_the_byte_bound.dart
round: 719
commit: 21f0560b
paths: [packages/core/rpc_dart/lib/src/endpoint/responder_streams.dart, packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart, packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_responder_transport.dart]
status: valid
---

# P-235 — what a queue of tiny h2 request messages retains

N client-stream calls on one h2 connection, each sending `count` two-byte
messages to a handler that does not read until released. RSS delta after the
senders stall. Run with `melos exec --scope=rpc_dart_http2 -- fvm dart run
.dart_tool/probe/r719_tiny_messages_past_the_byte_bound.dart parked 500000 8`
(arms: `parked` | `drains`, count, streams).

## Measures

RSS delta of the process (server and caller), and how many messages the
generators were pulled for.

## Control

A draining handler, and the pre-715 depth bound restored
(`IRpcNoMessageCredit` check disabled in the pipeline):

```
  arm                       streams   rssDelta
  drains                       1      -14 MiB
  parked, no weighing          8     +413 MiB
  parked, depth bound          8      -98 MiB
  parked, weighed (r719)       8      -30 MiB
```

Slow: 32 streams take over ten minutes.
