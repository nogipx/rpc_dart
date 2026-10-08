---
round: 742
verdict: CLEAN
packages: [rpc_dart_http2]
lens: RPC-15
bench: P-246 — new
commit: yes
release: none
---

# Round 742 — rpc_dart calls grpc-go

## Target

Round 740's mirror: rpc_dart as the CLIENT, against a real gRPC server.
grpc-go v1.80.0 is in the local module cache, so the server builds offline.
That direction was never driven against a third-party server in the journal.

## Hypothesis

The h2 caller fails against grpc-go on a call shape, on a non-OK status with a
non-ASCII message, or on deadline propagation (`grpc-timeout`).

## Before

Probe: `packages/transport/rpc_dart_http2/.dart_tool/probe/r742_against_grpc_go.dart`
with `r742_go/main.go`, a grpc-go server with `UnknownServiceHandler` and a
raw-bytes codec, whose behaviour is chosen by the method name.

```
  unary           echo:hi
  server stream   n 1, n 2, n 3
  client stream   a+b+c
  bidi            X, Y
  error status    status 5: no such thing: ünïcode
  deadline 1 s    status 4 after 1006 ms; grpc-go: deadline from grpc-timeout
                  in 999ms, then context canceled
  unknown         status 12: unknown /svc.S/Nope
```

## Mechanism

None. The deadline reaches grpc-go as `grpc-timeout`. The server's context
reads "canceled" rather than "deadline exceeded" because the caller's own
deadline fires first and resets the stream.

## After

n/a.

## Canary

n/a — no fix. The error, deadline and unknown arms are the controls: each
fails with its own status.

## The verdict questions

1. n/a: an interop matrix.
2. Yes: three distinct failing statuses alongside the four successes.
3. At the caller, and inside grpc-go for the deadline.
4. n/a.
5. n/a.
6. n/a.
7. CLEAN.
8. None.
A1. grpc-go's own defaults; the caller uses the default policy.
A2. Latency for the deadline arm (a 5 s handler).
L1. Each status is the one grpc-go chose.

## Gate

No library change.

## Not fixed

TLS to grpc-go was not driven. `secureConnect` is covered by round 692 and
the transport's own tests.

## Links

Lens `../lenses/RPC-15-remeasure-own-record.md` — `applied: [..., 742]`.
New bench `../probes/P-246-rpc-dart-against-grpc-go.md`.
