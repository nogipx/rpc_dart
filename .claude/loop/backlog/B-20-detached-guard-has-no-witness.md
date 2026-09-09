---
status: decided by owner (round 223)
round: 222
commit: b8d934a2
paths: [packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart]
probe: —
reason: owner approved the cost (round 223) — take it; the witness needs a subprocess to assert the isolate survived
---

# B-20 — the detached-future guard has no witness

`_detached` in the responder pipeline wraps every teardown future in
`.catchError`, and its comment records what paid for it: a client abandoning a
coalesced blob download cancels with its own reason, the aborted handler raises
`RpcCancelledException`, and "both replicas exited 255 within hours of each
other". A client must not be able to end a server by hanging up.

Round 222 ablated it — `unawaited(work)` with no handler — and ran the core
suite:

    +1395 ~1, All other tests passed

**Nothing sees its removal.** The sweep in that round confirmed every
`unawaited(` site on a user-code path is currently guarded, across all five
transport packages; what it cannot promise is that they stay guarded. A refactor
that drops one of these `.catchError`s ships green.

## Why this is not coverage for its own sake

The config's bar rules that out, and rightly. This is different in kind: the
failure mode is process death, it has been observed in production, and the guard
that prevents it is one line that no test touches. The ablation is the
measurement that distinguishes the two cases.

## What the witness has to do, and why it is awkward

Asserting "the isolate did not die" from inside that isolate is not possible —
if the defect fires, the asserting process is the one that dies. So the test has
to run the scenario in a SUBPROCESS and assert on its exit code, which is the
shape `close_releases_the_isolate_test.dart` already uses in rpc_dart_isolate;
read that first rather than inventing a harness.

The scenario itself: drive a real client cancellation whose server-side cleanup
throws, with `_detached` reached on the teardown path. `_detached` is private, so
the test drives it through the public cancellation route rather than calling it.

A cheaper partial: assert that the WARNING `_detached` logs on failure is
emitted, through a `RpcConnectionLogger`-style hook. That catches the guard being
deleted outright, and not the guard being narrowed — worth stating in the test
which of the two it pins.

## Owner decision

**Take it — the cost is approved.** (Asked and answered in round 223.)

Do it alongside the isolate half, which needs the identical harness and is
recorded in `B-04-isolate-future-timeout-unaudited.md`'s closing note: fail the
handshake in a child process, assert the child exits rather than hanging on a
live isolate. Two witnesses, one shape, and the shape already exists in
`close_releases_the_isolate_test.dart`.

Say in each test which of the two things it pins — the guard deleted outright,
or the guard narrowed. The cheap logger-hook version only catches the first, and
a test that silently covers less than its name claims is the failure this whole
lead is about.

Generalised as `../lessons/L-04-a-guard-with-no-witness.md`.
