---
round: 673
verdict: FIXED
packages: [rpc_dart_http]
lens: RPC-14
bench: none — the witness round 584 could not build, now built: `rpc_dart_http/.dart_tool/probe/b223_slow_versus_stalled.dart`
commit: yes
release: changelog
---

# Round 673 — a slow upload is not a stalled one

## Target

B-223, http1 in the owner's order. The lead owed the witness at two budgets,
then a design choice. Round 584's rig deadlocked on `socket.close()`;
`destroy()` does not.

## Hypothesis

`bodyReadTimeout` bounds the whole body read, so it refuses an honest slow
upload at the same deadline as a stalled client.

## Before

`RpcHttpServer`, a raw-socket client posting a valid 1 MiB gRPC frame at a
steady ~256 KiB/s (about 4 s), or 5 bytes and then nothing:

```
total 2s   slow 1 MiB   408 after 2030 ms
total 2s   stalled      408 after 2003 ms
total 8s   slow 1 MiB   200 after 4107 ms
total 8s   stalled      408 after 8006 ms
```

Indistinguishable at a short budget; at a generous one the stall is held for the
whole of it. The default was no bound at all.

Put to the owner with the measurement; decided: **an idle bound with a default,
the total kept as an opt-in ceiling**.

## Mechanism

`readBody().timeout(total)` measures size times throughput. A per-chunk idle
deadline measures the thing slowloris does.

## Fix

`bodyIdleTimeout` on `RpcHttpResponderTransport` and `RpcHttpServer`, default 30
seconds, re-armed by every chunk, on both the body read and the rejection
drain. `bodyReadTimeout` unchanged, default null.

The first version used `Stream.timeout`, and the stalled client read `closed`
instead of `408`: expiring that way cancels the body subscription, and dart:io
drops the connection before the status goes out. The deadline now RACES the
read (`Future.any`) the way the total does, and leaves the read to end when the
response completes.

## After

```
idle 2s    slow 1 MiB   200 after 4045 ms
idle 2s    stalled      408 after 2005 ms
```

## Canary

`packages/transport/rpc_dart_http/test/a_slow_upload_is_not_a_stalled_one_test.dart`:

- the idle deadline never armed: `a client that stops sending gets its 408`
  red, `Expected: contains '408' Actual: 'NOTHING'`.
- expiry by cancelling the read (`Stream.timeout`): the same test red,
  `Actual: 'closed'`.

Restored: 4 of 4 green, including the CONTROL (a 1 s total refuses the honest
upload) and the default-on check.

## The verdict questions

1. Yes: one mechanism per canary; the CONTROL is the total bound on the same
   upload.
2. Yes: 408 against 200 for the same slow upload.
3. Yes: the status line the client socket read.
4. Not zero-valued.
5. Yes, quoted.
6. Two halves, two canaries.
7. Yes; the design is the owner's choice of three.
8. None.

## Gate

`analyze`, `test:unit` (15 packages, http +227), `format:check`,
`license:check` green. README and `docs/transports/http.md` now teach the idle
bound.

## Not fixed

Nothing on B-223.

## Links

Lead `../backlog/B-223-a-whole-body-deadline-cannot-separate-slow-from-stalled.md` closed.
Lens `../lenses/RPC-14-timeout-abandons-work.md` -- `applied: [..., 673]`.
