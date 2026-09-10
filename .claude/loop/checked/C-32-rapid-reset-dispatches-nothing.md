---
round: 277
commit: dcf9d587
paths: [packages/transport/rpc_dart_http2/lib/**, packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart]
scope: [http2, core]
---

# C-32 — Rapid Reset dispatches no handler

CVE-2023-44487, the 2023 HTTP/2 attack every server implementation had to
answer: `maxActiveStreams` counts LIVE stream state, so a peer that opens a
stream and immediately sends RST_STREAM leaves nothing live, the ceiling never
refuses, and — on a vulnerable server — the handler it dispatched keeps running.
The request is cancelled; the work is not.

Measured with a raw `package:http2` client against `RpcHttp2Server`,
`maxActiveStreams: 4`, a 200ms handler:

    arm      requests  handlers entered  peak concurrent
    normal      200            4               4
    reset       200            0               0

**Nothing is dispatched.** The RST_STREAM is processed before the responder
pipeline reaches dispatch, so the amplification the CVE is about does not exist
here. The `normal` arm is the control and does double duty: it proves the bench
can dispatch a handler at all, and it shows `maxActiveStreams: 4` refusing 196
of 200 concurrent calls, which is the ceiling behaving.

## What this does NOT cover

Only the handler-dispatch half. Each reset stream still costs an HPACK decode
and a stream-state churn, at a rate `maxActiveStreams` cannot bound because
nothing is ever live — that is the CPU half of the same CVE and it was not
measured. A round that takes it needs a throughput observable, not a counter.

## Control

The `normal` arm, and it earned its place twice. Both arms first read
`handlers entered: 0` because the probe's request body was hand-built JSON while
rpc_dart's wire format is CBOR — see
`../lessons/L-10-a-hand-built-peer-needs-the-real-serializer.md`. Without the
control this would have been filed as a negative on the strength of a bench that
could not dispatch a handler at all.

Bench `../probes/P-27-rapid-reset.md`.
