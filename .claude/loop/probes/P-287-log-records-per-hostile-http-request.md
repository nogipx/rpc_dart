---
file: packages/transport/rpc_dart_http/.dart_tool/probe/log_records_per_hostile_request.dart
round: 794
commit: 7ac43f19
paths: [packages/transport/rpc_dart_http/lib/src/rpc_http_responder_transport.dart, packages/core/rpc_dart/lib/src/core/parser.dart, packages/core/rpc_dart/lib/src/rpc/streams/unary/responder.dart]
status: valid
---

# P-287 — log records per hostile http request

## Measures

`RpcHttpServer` with defaults, a fresh server and `LogController` per
input; a raw `HttpClient` repeats one request 100 times. Counts records at
warning or above and the set of answers (HTTP status / grpc-status).

Round 794, before:

```
  input                  records   kind       answers
  unknown method         0                    200/12
  unknown service        0                    200/12
  bad path               100       warning    400
  GET                    100       warning    405
  text/html              100       warning    415
  no content-type        100       warning    415
  truncated body         0                    200/3
  garbage body           100       error      200/8    (core: parser)
  two messages           100       error      200/13   (core: unary responder)
  bad grpc-timeout       0                    200/0
  OPTIONS preflight      100       warning    405
  valid call (control)   0                    200/0
```

After: the five warning rows read 1 each with the same answers; the two
core rows are unchanged (round 795).

## Control

The valid call and the rows answered without a record: same client, same
server, 100 requests, 0 records.
