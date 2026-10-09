---
round: 763
verdict: FIXED
packages: [rpc_dart_log]
lens: RPC-18
bench: P-264 — new
commit: yes
release: changelog
severity: S1
---

# Round 763 — the collector assembled what the transport cuts

## Target

`rpc_dart_log`, which no round had read as a server. Started on
`LogCollectorMcpBuffer.maxRecords`, a bound counted in records, not bytes.
Reading what feeds it, `LogCollectorServer._start` upgrades with
`WebSocketTransformer.upgrade` and its own adapter instead of
`rpcWebSocketConnections`. The class, by `find_references` over lib: one
`WebSocketTransformer.upgrade` and one `RpcWebSocketServer` outside the
transport, both here.

## Hypothesis

dart:io assembles a whole WebSocket message with no ceiling, so a peer that
never sends FIN is buffered by the collector for as long as it writes, while
the same server built on `rpcWebSocketConnections` cuts it at the policy's
message size.

## Before

P-264, 1 MiB frames with FIN clear, 256 MiB offered:

```
  collector  256 MiB accepted, connection open   rss +264 / +317 / +323 MiB
  library     16-17 MiB, closed by server         (control)
```

## Mechanism

The hand-rolled upgrade skipped every guard `rpcWebSocketConnections` adds:
the frame guard (`upgradeBounded`), compression off (dart:io's default is
on, and it inflates without limit), the keepalive ping, and the 400 for a
non-upgrade request answered without a stream error. Fix: the collector
passes `rpcWebSocketConnections(_httpServer!)` to `RpcWebSocketServer` and
the adapter classes are deleted.

## After

```
  collector  16-17 MiB, closed by server   rss +57..60 MiB   (3 of 3)
  library    16-17 MiB, closed by server                    (3 of 3)
```

## Canary

`packages/core/rpc_dart_log/test/an_unfinished_message_to_the_collector_is_bounded_test.dart`,
5 of 5 green. Fix stashed: `the collector kept the connection after 64 MiB
of one message`.

## The verdict questions

1. The arms differ in the upgrade path only: same `RpcWebSocketServer`,
   default policy, same client.
2. Yes: 256 MiB against 16-17 MiB.
3. At the peer: the server ends the connection (L-11); RSS is the process's,
   with the client's buffer reused.
4. n/a, not a zero.
5. Yes, the message above.
6. One half.
7. FIXED from the numbers.
8. `maxRecords` counting records, not bytes, was the opening target and is
   not ruled out: it is round 764's.
9. None.
A1. The client is a raw socket with no policy; the victim's is
    `RpcWebSocketServer`'s default.
A2. Volume.
L1. The refusal is the frame guard's (the connection closes mid-message,
    before any RPC frame exists); no RPC limit can fire on an unfinished
    WebSocket message.

## Gate

`melos run analyze`, `format:check`, `test:unit` green; rpc_dart_log 92/92.

## Not fixed

The guard reaches the collector only with an rpc_dart_websocket released
after 0.5.0; with 0.5.0 it gets compression off and the ping, not the frame
guard. At release the rpc_dart_log floor on rpc_dart_websocket moves to the
version that ships `upgradeBounded`.

## Links

Probe `../probes/P-264-an-unfinished-message-to-the-log-collector.md`.
Lens `../lenses/RPC-18-dependency-buffers-below-your-limits.md` — `applied: [..., 763]`.
Round `756-the-client-had-no-message-ceiling.md` (the client side of the same guard).
