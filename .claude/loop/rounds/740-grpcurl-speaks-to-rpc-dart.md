---
round: 740
verdict: CLEAN
packages: [rpc_dart_grpc_reflection, rpc_dart_http2]
lens: RPC-15
bench: P-245 — new
commit: yes
release: none
---

# Round 740 — grpcurl speaks to rpc_dart

## Target

Interop with a real gRPC client, the one thing no reading can settle.
`checked/C-15` (grpcurl against http2) was recorded before round 201 and never
re-measured. `rpc_dart_grpc_reflection` exists so that `grpcurl` and Postman
can discover services, and round 284 drove it only through
`processRequestForTest`. `grpcurl` is installed here.

## Hypothesis

A real client fails on one of: reflection listing, describing, a unary call,
a server stream, a handler's error status, or `grpc-timeout`.

## Before

Probe: `packages/core/rpc_dart_grpc_reflection/.dart_tool/probe/r740_grpcurl.dart`.
`RpcHttp2Server` with a hand-built descriptor (`echo.v1.EchoService`,
protobuf payloads encoded by hand) and `registry.attachTo` per endpoint,
driven by the system `grpcurl`:

```
  grpcurl list                        exit 0   echo.v1.EchoService
  grpcurl describe                    exit 0   4 rpcs, Count as `stream`
  Echo {"text":"hi"}                  exit 0   {"text": "echo: hi"}
  Count {"text":"n"}                  exit 0   n 1, n 2, n 3
  Missing (control)                   exit 1   no method named "Missing"
  Fail (control)                      exit 69  Code: NotFound, Message: no such text
  Slow, -max-time 1                   exit 68  DeadlineExceeded after 1020 ms;
                                               handler's context deadline set,
                                               token cancelled
```

## Mechanism

None. Every arm behaves as a gRPC server must.

## After

n/a.

## Canary

n/a — no fix. `Missing` and `Fail` are the controls: they show the instrument
reports a failure as a failure, with the code a server chose.

## The verdict questions

1. n/a: an interop matrix, one call per arm.
2. Yes: the failing arms fail with distinct, correct codes.
3. At a third-party client, and inside the handler for the deadline.
4. n/a.
5. n/a.
6. n/a.
7. CLEAN.
8. None.
A1. grpcurl has its own configuration; the server uses the default policy.
A2. Latency for the deadline arm, introduced by a 5 s handler.
L1. NotFound is the handler's own status; DeadlineExceeded is the client's.

## Gate

No library change.

## Not fixed

TLS and client-streaming through grpcurl were not driven. grpcurl's
client-streaming needs a request stream on stdin.

## Links

Lens `../lenses/RPC-15-remeasure-own-record.md` — `applied: [..., 740]`.
Negative `../checked/C-15-grpc-listener-and-cancellation.md`, re-measured in
part. New bench `../probes/P-245-grpcurl-against-rpc-dart.md`.
