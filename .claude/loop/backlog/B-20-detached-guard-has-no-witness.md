---
status: open
round: 222
commit: b8d934a2
paths: [packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart]
probe: —
reason: cost — the witness needs a subprocess to assert the isolate survived, which is a round of its own
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

—
