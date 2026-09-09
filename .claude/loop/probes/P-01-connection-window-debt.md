---
file: packages/core/rpc_dart/.dart_tool/probe/conn_window_leak.dart
round: 206 — the validating round
commit: c48a14d8
paths: [packages/core/rpc_dart/lib/src/rpc/transports/**]
status: valid
---

# P-01 — how much a sender gets out before the connection pool wedges

Two `RpcChannelTransport`s over `RpcFrameMultiplexedChannel.pair()`, each with
its OWN policy object. The client opens 12 sequential streams and sends
256 KiB of 32 KiB chunks on each; a `sendMessage` that does not return within
5 s counts as wedged, and the run stops there.

Run it with `melos exec --scope=rpc_dart -- fvm dart run
.dart_tool/probe/conn_window_leak.dart`. The three knobs are `receiverConsumes`
(the control), `perStream` (null out `flowControlWindowBytes` to isolate the
pool) and the two window constants at the top. For another hypothesis on these
paths, change what the receiver does with the per-stream view — that is the
axis the bench is built around.

## Measures

Total bytes the client's `sendMessage` ACCEPTED before it stopped returning,
and which call it stopped on. Counted on the sender, incremented only after the
transport's future completes, so what it reads is the library's send admission
(`_fcTryConsume` / `_fcAwaitCredit`), not a bench-side queue.

## Control

The receiver drains the per-stream view it binds, instead of binding it and
never pulling. Nothing else differs — same rig, same policy values, same
volume. At validation:

```
CONTROL — receiver drains
  KiB per call : [256 x 12]   total 3072 KiB   wedged: never

CASE A — receiver binds the view, never reads
  KiB per call : [256, 256, 256, 256, 0]   total 1024 KiB   wedged at call 4

CASE B — receiver drains, flowControlWindowBytes: null
  KiB per call : [256, 256, 256, 256, 0]   total 1024 KiB   wedged at call 4
```

1024 KiB is exactly the configured `flowControlConnectionWindowBytes`, which is
what names the control under test: no other limit in the policy has that value
(32 KiB chunks against a 16 MiB frame ceiling, 12 streams against 4096).
