---
round: 277
verdict: CLEAN
packages: [rpc_dart_http2]
lens: RPC-22
bench: P-27 — new
commit: yes
---

# Round 277 — Rapid Reset dispatches nothing

## Target

CVE-2023-44487, HTTP/2 Rapid Reset. A grep of the whole journal for
`RST_STREAM`, `rapid reset` and `44487` returned **one** file — round 208, which
uses RST_STREAM as a mechanism and never as an attack. So the 2023 attack that
every HTTP/2 server implementation had to answer has never been measured here,
on the transport that is this library's gRPC face.

The shape is RPC-22's: `maxActiveStreams` counts LIVE stream state, so a peer
that opens a stream and resets it immediately is beneath the ceiling by
construction, and the ceiling is the only thing counting.

## Hypothesis

A stream opened and reset before its handler finishes leaves the work running
while the stream state goes, so 200 resets dispatch 200 handlers against a
ceiling of 4.

## Before

Raw `package:http2` client, `maxActiveStreams: 4`, a 200ms handler.

```
arm      requests  handlers entered  peak concurrent  still running
normal      200            4               4               0
reset       200            0               0               0
```

Probe: `packages/transport/rpc_dart_http2/.dart_tool/probe/rapid_reset.dart`

**Refuted.** Nothing is dispatched: the RST_STREAM is processed before the
responder pipeline reaches dispatch. The `normal` arm is the control and does
double duty — it proves the bench can dispatch a handler at all, and it shows
`maxActiveStreams: 4` refusing 196 of 200 concurrent calls.

## Mechanism

n/a — there is nothing to explain, which is the result.

## After

n/a.

## Canary

n/a. The control is what carries this round, and it earned its place: **both
arms first read `handlers entered: 0`.** The probe's request body was hand-built
JSON while rpc_dart's wire format is CBOR, so every request came back
`grpc-status: 13, grpc-message: Internal server error` — `wireStatusFor`'s
DEFAULT DENY, which deliberately says nothing to a peer. Two fixture rebuilds
and a `diagnose` arm printing every response header separated "the server
refused me" from "my bench cannot dispatch a handler". Without a control this
round would have filed the right conclusion on evidence that proved nothing.
Recorded as `L-10`.

## Gate

n/a — no code changed. `loop.py lint` green.

## Not fixed

Nothing to fix, and one half deliberately not measured: each reset stream still
costs an HPACK decode and a stream-state churn at a rate `maxActiveStreams`
cannot bound, because nothing is ever live. That is the CPU half of the same
CVE. It needs a throughput observable rather than a counter, and this round's
bench budget was spent on the fixture. Recorded in C-32 rather than opened as a
lead, because a lead with no probe design is the B-09 objection.

## Links

RPC-22 (`applied:` gains 277). Bench P-27, new — and the only bench here that
speaks HTTP/2 to the server without rpc_dart's own caller, so it is the one to
reuse for anything needing frame-level control. Negative C-32. Lesson L-10.
