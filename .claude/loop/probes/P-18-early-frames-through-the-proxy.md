---
file: packages/core/rpc_dart/.dart_tool/probe/rpc20_proxy_window.dart
round: 240
commit: c84ff1cf
paths: [packages/core/rpc_dart/lib/src/resilience/**, packages/core/rpc_dart/lib/src/rpc/transports/**, packages/core/rpc_dart/lib/src/core/buffered_broadcast.dart]
status: valid
---

# P-18 — do frames that arrived before the app subscribed survive a hop?

An in-memory pair, the peer greeting once, and three arms that differ by ONE
thing each. Run it with `fvm dart run` from `packages/core/rpc_dart`. To ask the
same question of another hop, keep arm C (the direct read) and point arms A and
B at the wrapper under suspicion — the shape is "who drains the inner buffer,
and does that drain have a listener".

## Measures

How many `RpcTransportMessage`s the consumer's own `incomingMessages` delivers.
Counted on the library's side, not the probe's: the probe only subscribes.

## Control

Two, because a single one cannot separate "the frame never existed" from "the
frame was dropped here":

- **B** subscribes BEFORE `connect()` — same proxy, listener attached first.
- **C** subscribes at the same lateness DIRECTLY on the inner transport — same
  frame, same 100 ms, no proxy hop.

```
                                        before   after
A  late, through RpcClientConnection        0       1
B  early, through RpcClientConnection       1       1
C  late, straight off the transport         1       1
```

**Its first build measured nothing** — A=B=C=1 — because `await sendMetadata`
returns when the frame is written, not when it lands, so the frame was still in
flight when the proxy attached and every ordering passed. The 50 ms settle
before the arms is what makes the window real; without it this bench is a
tautology.
