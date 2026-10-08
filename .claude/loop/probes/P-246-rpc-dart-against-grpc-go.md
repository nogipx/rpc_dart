---
file: packages/transport/rpc_dart_http2/.dart_tool/probe/r742_against_grpc_go.dart
round: 742
commit: a94aca2c
paths: [packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart, packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_common.dart]
status: valid
---

# P-246 — does rpc_dart's h2 caller work against a real gRPC server?

A grpc-go server (`.dart_tool/probe/r742_go/main.go`, build it with `go -C
.dart_tool/probe/r742_go build -o server .`) accepts any method with a raw
codec. The probe starts it, reads its port, and makes every call shape plus
an error, a deadline and an unknown method. Run with `melos exec
--scope=rpc_dart_http2 -- fvm dart run .dart_tool/probe/r742_against_grpc_go.dart`.

## Measures

Each call's result or status at the caller, and grpc-go's own log for the
deadline.

## Control

The failing arms: status 5 with a non-ASCII message, status 4 at 1 s, with
grpc-go reporting a 999 ms deadline from `grpc-timeout`, and status 12.
