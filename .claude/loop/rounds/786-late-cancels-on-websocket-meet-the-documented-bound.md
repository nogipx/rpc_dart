---
round: 786
verdict: CLEAN
packages: [rpc_dart, rpc_dart_websocket]
lens: RPC-05
bench: P-280 — new
commit: yes
release: none
---

# Round 786 — late cancels on websocket meet the documented bound

## Target

The network-audit skill's KV-R-06 (open-and-cancel storms) on the priority
transport. C-32 measured it on http2 only, and only with the reset arriving
before dispatch. The case it leaves is a cancel after the handler starts,
over websocket. RPC-05 is the lens: where a concurrency limit is charged.
Two items were set aside on the way: `decodeRpcStatus` (KV-CD-01/07) is in
`test/fuzz/peer_bytes_decoders_fuzz_test.dart`, read today; Autobahn
(methods §5) needs a Docker daemon, which is not running here.

## Hypothesis

A cancel after dispatch releases the stream slot while the handler runs on,
so a paced cancel storm runs far more handlers than `maxActiveStreams`, and
`maxConcurrentHandlers` fails to bound it on this transport.

## Before

P-280, 200 calls, `maxActiveStreams: 4`:

```
  arm      maxConcurrentHandlers   entered   peak running
  paced    null                    12        4
  late     null                    191-193   92-93
  late     4                       12        4
```

Probe: `packages/transport/rpc_dart_websocket/.dart_tool/probe/rapid_cancel_ws.dart`

## Mechanism

The first half holds, as documented: `maxActiveStreams` counts stream
state, which a cancel releases. The second half does not: the handler bound
is charged at dispatch and released when the handler returns, on websocket
as on the core paths.

## After

n/a.

## Canary

n/a.

## The verdict questions

1. Yes: `late` against `paced` differ in the cancel only; `late` with and
   without the bound differ in `maxConcurrentHandlers` only.
2. Yes: 93 against 4.
3. In the responder's handler, counting its own entries.
4. The bound's 4 is shown able to be exceeded by the arm without it (93).
5. n/a.
6. n/a.
7. CLEAN: the hypothesis's second half failed; the first half is the
   documented behaviour and its default a recorded choice.
8. `decodeRpcStatus` set aside by reading the fuzz test today; Autobahn not
   run (no Docker daemon), not ruled out.
9. None.
A1. One process; the client's caller with defaults, the server with its own
    policy.
A2. Latency, made by the handler's own 300 ms.
L1. The refusals in the bounded arm are RESOURCE_EXHAUSTED from the handler
    bound; the client counted 187 `RpcStatusException`.

## Gate

n/a — no code change.

## Not fixed

Nothing. B-275 still awaits the owner.

## Links

Lens `../lenses/RPC-05-concurrency-limit-charge-point.md`.
Probe `../probes/P-280-late-cancels-over-websocket.md`.
Negative `../checked/C-69-handlers-outlive-cancelled-streams-on-websocket-too.md`.
Negative `../checked/C-32-rapid-reset-dispatches-nothing.md`.
