---
round: 638
verdict: FIXED
packages: [rpc_dart]
lens: RPC-14
bench: none — the witness reads every status a raw client gets, and the probe reads what an rpc_dart caller raises
budget: probes 2/5, canaries 1/5
commit: yes
release: changelog
---

# Round 638 — the deadline answers itself

## Target

B-234, owner's decision: the server answers DEADLINE_EXCEEDED, and the rpc_dart
caller maps a status-4 trailer to `RpcDeadlineExceededException`.

## Hypothesis

`_onDeadlineExceeded` cancels the handler's token and sends nothing of its own,
on purpose, so the handler's `RpcCancelledException` decides what the peer hears.

## Before

```
raw client, grpc-timeout 200m, handler checks its token every 20 ms
  unary          status 1 (CANCELLED), 3 of 3
  server-stream  no status at all, 3 of 3
rpc_dart caller, 100 ms timeout   DeadlineExceeded(4) 40/40 on both shapes
```

## Control

The rpc_dart caller row: its own timer wins today, which is why only a foreign
client or a proxy saw the wrong answer.

## Mechanism

RPC-14, a timeout that abandons work without answering: the doc called the
silence deliberate, to keep a trailer from racing the caller's own timer. The
unary shape sent a trailer anyway, CANCELLED, so the race existed already with
the wrong code; the server-stream shape lost even that.

## After

The server sends DEADLINE_EXCEEDED through `_sendGrpcErrorAndCleanup` (the stream
is remembered closed before the send and torn down after it) and then cancels
the token. A raw client reads exactly `[4]` on unary and server-stream, no second
trailer from the unwinding handler. `RpcCallerTrailer.errorOf` takes the call's
context, and on a call with a deadline a status-4 trailer is the
`RpcDeadlineExceededException` the caller's own timer raises; every caller shape
passes it, the zero-copy unary path included. The probe still reads
`DeadlineExceeded(4) 40/40`.

The zero-copy unary path (`_executeUnaryCall`) also kept the LAST response, the
fifth copy of round 637's rule; it now fails on a second one too.

## Canary

The mapping disabled: the deterministic arm (a status-4 trailer long before the
caller's deadline) reads `RpcStatusException(4): Unknown error` instead of
`RpcDeadlineExceededException`. The server arms' before lines are the same
witness against the old `_onDeadlineExceeded`.

## Gate

`melos run analyze` green, `format` on rpc_dart green, `melos run test:unit` and
`melos run test:web` green (exit 0 each).

## Not fixed

A handler that ignores its token still runs after the answer; the reclaim
backstop is unchanged, and its slot is now freed at the answer rather than after
the grace.

## Links

Lead `../backlog/B-234-a-server-deadline-answers-the-wrong-status.md` — closed.
Lens `../lenses/RPC-14-timeout-abandons-work.md` — `applied: [..., 638]`.
Test `packages/core/rpc_dart/test/endpoint/a_server_deadline_answers_deadline_exceeded_test.dart`.
