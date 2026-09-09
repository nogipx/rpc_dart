---
file: packages/core/rpc_dart/.dart_tool/probe/conn_window_leak.dart
round: 228 — the validating round for the new arm
commit: af64eeac
paths: [packages/core/rpc_dart/lib/src/rpc/transports/**]
status: valid
---

# P-11 — does the connection pool come back from a consumer that stops?

Round 206's connection-window bench, extended in round 228 with the arm the
original two did not cover.

Two `RpcChannelTransport`s over an in-memory channel pair, each with its OWN
policy object so nothing in the result can be self-harm through shared config:
1 MiB connection pool, 256 KiB per-stream window, 32 KiB chunks, 12 sequential
calls of 256 KiB each. Each call ends with `finishSending`, so `_fcForget` runs
for every stream.

Run it with `melos exec --scope=rpc_dart -- fvm dart run
.dart_tool/probe/conn_window_leak.dart`.

## Measures

KiB accepted per call before a send stops completing (2 s timeout), and the call
index at which the connection wedges. Both are taken on the SENDER, which is the
side the pool actually throttles.

## Control

Three of the four arms are controls, and all three reach the full 3072 KiB:

```
  receiver drains                     12 calls, 3072 KiB, never wedged
  receiver never binds a listener     12 calls, 3072 KiB, never wedged
  receiver drains, per-stream OFF     12 calls, 3072 KiB, never wedged
  receiver BINDS and PAUSES            4 calls, 1024 KiB, wedged at call 4
```

The case differs from the first control by one call — `subscription.pause()` —
so the wedge is the pause and nothing else. 1024 KiB is exactly the pool, which
is what says the connection level is the one exhausted rather than the stream
level.

**The "never binds" arm is the one that makes this bench worth keeping.** It is
the branch round 206 fixed, and it still passes; without it a red CASE C could
be read as 206 having regressed, when in fact it is a different branch of the
same `if`.

Lead: `../backlog/B-22-paused-consumer-never-repays-the-pool.md`.
