---
file: packages/transport/rpc_dart_http/.dart_tool/probe/half_open_after_body_failure.dart
round: 271
commit: 33090229
paths: [packages/transport/rpc_dart_http/lib/**, packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart]
status: valid
---

# P-22 — what a body that never arrives costs the HTTP/1.1 server

Sends N raw HTTP/1.1 requests that promise a gRPC body and then die mid-body,
and reports the TWO budgets separately: the transport's `pendingRequests` and
the pipeline's `openStreams`. Wiring is `RpcHttpServer`'s, opened up so both
objects are reachable — one `RpcResponderEndpoint` over one
`RpcHttpResponderTransport`, served with `shelf_io.serve`.

## Measures

`openStreams` from `endpoint.collectResponderMetrics()` and `pendingRequests`
from `transport.health()`, then one ordinary RPC call through a real
`RpcHttpCallerTransport`. Reporting both is the whole point: they are charged
and released at different moments, and a fix that moves the wedge from one to
the other must be visible as such.

## Control

The ablation — the same arm with the metadata emit put back before the body
read, one line moved, nothing else. `arm=ok` (the same N requests completed
normally) is a liveness guard, not the control: it changes the client too.

```
arm      bodyReadTimeout  pendingRequests  openStreams  ordinary call
ok       -                0 -> 0           0 -> 0       OK -> OK
abort    none             8 -> 8           8 -> 0       503 -> 503
timeout  500ms            0 -> 0           8 -> 0       status 8 -> OK
```

> **Name the limit that refused you.** The `abort` arm's 503 comes from the
> transport's `_pending` check and the `timeout` arm's `RpcStatusException(8)`
> from the pipeline's `_respMaxStreams` — a neighbouring limit and the one under
> test. Read as "the server refused, so the bench works", the `abort` arm would
> have made the fix look like it changed nothing.

The attacker holds no rpc_dart configuration at all: it is a bare socket. The
victim's policy and the ordinary caller's are separate objects.
