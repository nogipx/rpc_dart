---
round: 596
verdict: CLEAN
packages: [rpc_dart_websocket]
lens: RPC-15
bench: P-213 — new
budget: probes 0/5, canaries 0/5
commit: yes
release: none
---

# Round 596 — the rebroadcast that carries nothing

## Target

B-203, the one open lead filed against the websocket transport's hot path: the
wrapper "re-broadcasts every frame the core transport already routed". Taken
because it is in the rpc_dart_websocket scope and measurable with P-146's
counting shape, which the lead itself prescribed.

## Hypothesis

`RpcWebSocketCallerTransport._attach` forwards everything `_inner.incomingMessages`
emits into its own controller with a set lookup each. Round 508 made the core
transport stop broadcasting a message it already routed to the stream's own
controller. If that holds through the wrapper, the wrapper forwards nothing on an
ordinary call and the claim is refuted.

## Before

```
                                    per unary call   per 100-message stream
WRAPPER  RpcWebSocketCallerTransport       0.00              0.00
CONTROL  bare RpcChannelTransport          0.00              0.00
ABLATED  core skip off, wrapper            3.00            101.00
ABLATED  core skip off, bare               3.00            101.00
```

Events on `incomingMessages` over a real socket to `RpcWebSocketServer`, 500 unary
calls and 50 server streams after a warm-up. Probe:
`packages/transport/rpc_dart_websocket/.dart_tool/probe/b203_what_the_wrapper_rebroadcasts.dart`.

The ablation is the round-508 condition (`if (!(locallyInitiated && wasRouted))`
forced true) switched off in place and restored; it shows the bench can see every
frame of a call — metadata, data, trailer — when the core does broadcast them.

## Mechanism

The wrapper forwards only what the core broadcasts, and the core broadcasts only
peer-initiated or un-routed messages. On a caller those are the rare cases the
`_peerStreamIds` membership exists for, so the per-message cost the lead
describes is no longer paid on any ordinary call.

## After

n/a — nothing changed.

## Canary

n/a — no fix. The ablation above is the bench's control.

## Gate

Not run: `lib/` and `test/` are byte-identical to the previous commit after the
ablation was restored (`git status` clean).

## Not fixed

The lead's design question — `startCallerListening` now only drains the buffer
and observes errors — has no failure behind it and stays a design note in C-62.

## Links

Lead `../backlog/B-203-the-websocket-wrappers-second-broadcast.md` — closed.
Negative `../checked/C-62-the-websocket-rebroadcast-carries-nothing.md` — new.
Bench `../probes/P-213-what-the-wrapper-rebroadcasts.md` — new.
Lens `../lenses/RPC-15-remeasure-own-record.md` — `applied: [596]`.
