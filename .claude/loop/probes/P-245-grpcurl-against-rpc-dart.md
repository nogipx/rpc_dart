---
file: packages/core/rpc_dart_grpc_reflection/.dart_tool/probe/r740_grpcurl.dart
round: 740
commit: a94aca2c
paths: [packages/core/rpc_dart_grpc_reflection/lib/**, packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_server.dart, packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_responder_transport.dart]
status: valid
---

# P-245 — does a real gRPC client work against rpc_dart?

`RpcHttp2Server` with a hand-built `echo.v1.EchoService` descriptor and
`rpc_dart_grpc_reflection`, driven by the system `grpcurl`: list, describe,
unary, server stream, a missing method, a handler error, and a 1 s client
deadline against a 5 s handler. Run with `melos exec
--scope=rpc_dart_grpc_reflection -- fvm dart run .dart_tool/probe/r740_grpcurl.dart`.
Needs `grpcurl` on PATH.

## Measures

grpcurl's exit code and output per arm, and for the deadline arm the handler's
own view: its context deadline and whether its token was cancelled.

## Control

The failing arms:

```
  Missing   exit 1    method not in the descriptor
  Fail      exit 69   Code: NotFound, Message: no such text
  Slow      exit 68   DeadlineExceeded in 1020 ms; handler token cancelled
```

Round 741 added client-stream (`Join`) and bidi (`Shout`) arms, which feed
requests on stdin. It also added a companion probe, `r741_grpcurl_tls.dart`,
for TLS with a run-made self-signed certificate. It reads `-insecure` exit 0
against `-plaintext` exit 1, and a plaintext preface closed by the server in
1 ms.
