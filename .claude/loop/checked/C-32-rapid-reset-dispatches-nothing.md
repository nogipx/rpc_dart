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

## The CPU half — measured in round 283, also clean

Round 277 covered only handler dispatch and left the churn half open. Round 283
measured it, with an unrelated connection's call latency as the observable
rather than CPU:

    arm      attack streams  victim median  victim worst
    idle                  0        1241 us       2367 us
    reset              2000        1046 us     373458 us
    normal             2000         648 us     679531 us

**The control moved further than the subject.** The same 2000 streams NOT reset
stall the victim for 679 ms against the reset arm's 373 ms, so the stall belongs
to concurrent admitted work and resetting REDUCES what the server spends — the
cancel lands before dispatch, which is this record's own mechanism seen from the
other side. Resets do not buy an attacker work beyond the ceiling.

Only the WORST case moves; the medians are flat and their ordering is noise. A
bench reporting a median alone would have called all three arms identical.

The 679 ms itself is `maxActiveStreams` at its 4096 default behaving: 2000 is
under the ceiling, so that is work the server agreed to. Capacity and tuning,
not a defect.

**RPC-18's caveat bounds this**: an in-process flood yields the event loop, so
absolute starvation is muted against a cross-process attacker. The comparison
between arms is what holds, all three running in one harness.
Bench `../probes/P-32-rapid-reset-cpu.md`.

## Control

The `normal` arm, and it earned its place twice. Both arms first read
`handlers entered: 0` because the probe's request body was hand-built JSON while
rpc_dart's wire format is CBOR — see
`../lessons/L-10-a-hand-built-peer-needs-the-real-serializer.md`. Without the
control this would have been filed as a negative on the strength of a bench that
could not dispatch a handler at all.

Bench `../probes/P-27-rapid-reset.md`.
