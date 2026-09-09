---
file: packages/core/rpc_dart/.dart_tool/probe/zero_grant_reads_as_legacy.dart
round: 229 — the validating round
commit: e6d5cd79
paths: [packages/core/rpc_dart/lib/src/rpc/transports/**]
status: valid
---

# P-12 — is a zero grant read as a peer that does not participate?

One `RpcChannelTransport` sending into a **foreign peer driven at the channel
level**, which is the whole point: rpc_dart never sends a zero grant itself, so
nothing built out of two rpc_dart transports can reach this path.

64 KiB connection window, 16 KiB initial send window, 300 ms legacy grace, 4 KiB
chunks, 200 of them. The peer reads nothing and answers the first frame it sees
with exactly one grant.

Run it with `melos exec --scope=rpc_dart -- fvm dart run
.dart_tool/probe/zero_grant_reads_as_legacy.dart`.

## Measures

Bytes the sender manages to push before a send stops completing. Taken on the
SENDER, which is the side the window throttles. The 1 s per-send timeout is
deliberately longer than the 300 ms grace, so a park the grace would release
counts as accepted rather than as a stall — otherwise the defect would hide as a
timeout.

## Control

The same peer, same rig, granting `1` instead of `0`:

```
  peer grants 1     20 KiB accepted     <- bounded
  peer grants 0    800 KiB accepted     <- 12.5x the window, before the fix
  peer grants 0     16 KiB accepted     <- after
```

The arms differ by one character, so the flood is the grant's VALUE and nothing
else. 800 KiB against a 64 KiB window is what makes it a bound that was switched
off rather than one that was merely loose; 16 KiB afterwards is exactly the
seeded initial window, which is what says the sender is now spending only what
it had before the peer spoke.

Lead: `../backlog/B-05-isolate-null-credit-silent.md`.
