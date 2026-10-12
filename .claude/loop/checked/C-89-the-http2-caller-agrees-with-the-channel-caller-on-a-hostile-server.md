---
round: 858
commit: 6c31366f
paths: [packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport_inbound.dart]
scope: the four caller shapes over http2 against thirteen hostile response sequences (P-326), compared with the channel caller (P-317); a raw h2 server, one call per connection
---

# C-89 — the http2 caller agrees with the channel caller on a hostile server

On every sequence both probes share, the http2 caller ends each shape the
same way as the channel caller: the same OK or the same status code. Only
the text differs where each transport words a missing status ("Response
ended without a gRPC status" against "Stream ended without a gRPC status",
both 13). Bench `../probes/P-326-what-an-http2-caller-accepts-from-a-hostile-server.md`
beside `../probes/P-317-what-a-channel-caller-accepts-from-a-hostile-server.md`.

The one row that splits does so on both transports alike, by shape: a
status without END_STREAM, then another with it (B-296).

## Control

`valid: one message, OK`: OK on all four shapes on both transports.
