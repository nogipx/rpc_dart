---
round: 382
verdict: CLEAN
packages: [rpc_dart]
lens: RPC-05
bench: P-70 — new
commit: yes
---

# Round 382 — both request paths are bounded, by different things

## Target

B-51, third of the three the owner named, in order. Filed from the consumer:
the request direction is the one their upload travels, roughly 8 MB in against
400 bytes out, while the direction four rounds have measured is the cheap one.

RPC-05 — where a limit is charged and released across a lifecycle.

## Hypothesis

The request relay buffers the way the response relay did (2000 messages /
31.3 MB against a 1 MB window, P-65), so a handler slow for an ordinary reason —
an object-store write — lets the pipeline pull the client's whole batch into
server memory.

## Before

A handler that reads one message and stalls, a 1 MB window, 16 KiB messages,
2000 offered, counted inside the CALLER's producer:

```
arm             pulled of 2000      MB
bidi-stall            66           1.0
bidi-drain          2000          31.3     <- control
client-stall          66           1.0     <- control
```

Probe: `packages/core/rpc_dart/.dart_tool/probe/bidi_request_direction.dart`
(P-70).

**Bounded, at the window.** `bidi-drain` is the control that makes the 66 mean
something: the same rig with a handler that drains everything pulls the producer
dry, so 66 is a bound rather than a slow producer.

## Mechanism

Nothing is broken — but the ablation corrected the lead's premise, which is the
finding worth recording.

Removing `deferFlowCredit` from `_pipelineFedRequestStream`:

```
arm             fixed   ablated
bidi-stall         66        66      <- unchanged
client-stall       66      2000      <- the bound was here
```

**`_pipelineFedRequestStream` is the CLIENT-STREAM path, not bidi's.** B-51
names it as "the direction a file upload travels" for a bidirectional handler,
and that is wrong: `_ensureBidirectionalResponder` binds through
`_stateBoundStream`, so a bidi handler is fed by the transport's own per-stream
metering, and only client-stream goes through the pipeline-fed relay with its
`deferFlowCredit` accounting.

So there are two request paths, both bounded, by two different mechanisms — and
the ablation is what separated them. Ablating the one the lead named moved the
arm the lead did NOT name, and left the arm it did name untouched.

For the consumer the answer is still the one they wanted: their upload is a
bidirectional handler, and that path is bounded.

## After

n/a — no change made.

## Canary

n/a — no fix. The ablation is the variation, and it did more than confirm
sensitivity: it re-attributed the mechanism. A round that had only seen `66` and
stopped would have reported the right number about the wrong code.

## Gate

`fvm dart test -j 8` in the package green. No library code moved —
`git diff --stat` empty before the verdict — so round 381's gate stands.

## Not fixed

Nothing found. Two things this does NOT cover:

- **Latency.** Taken on `RpcChannelTransport.pair()`. Round 378 established that
  this particular question survives an RTT for the response direction, and the
  same argument applies here — the bound is a `pause`/credit on the consuming
  side, not a state that exists only in flight — but it was not re-run through
  the proxy.
- **The transport's own metering for bidi**, which is what the `bidi-stall` arm
  actually exercised. It came back bounded; nobody ablated it separately to see
  which of its parts carries the bound.

## Links

- RPC-05 — the lens; `applied:` gains 382
- B-51 — closed by this round, with its premise corrected
- P-70 — the bench; its ablation re-attributed the mechanism
- P-65 — the response-direction bench this mirrors
- Round 380 — the other lead this session whose premise did not survive being
  measured
