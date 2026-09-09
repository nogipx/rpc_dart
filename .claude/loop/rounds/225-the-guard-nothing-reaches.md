---
round: 225
verdict: CLEAN
packages: [rpc_dart]
lens: RPC-13
bench: none — two probe shapes were built and neither could see the defect; the instrument that answered the question was `_detached` printing on rejection
budget: probes 2/3, canaries 2/3
review: self — the session forbids the Agent tool unless the user asks; the `loop.py review` prompt was answered against the record and the probe. Approved 8 of 10 — Q2 is a NO and is recorded as such in `## Not fixed`, A1 not applicable
commit: yes
---

# Round 225 — the guard nothing reaches

## Target

B-20, the owner decision: write the subprocess witness for `_detached`, the
guard that stops a client hanging up from killing the server.

First correction, rule one: B-20 and its decision both name
`close_releases_the_isolate_test.dart` as the harness to copy, and **there is no
such file at that path**. It is `test/audit/close_releases_the_isolate_test.dart`.
The shape it describes is real and was used.

## Hypothesis

Round 222 removed `_detached`'s `.catchError` and the core suite stayed green,
and read that as a coverage gap. So: drive a real failure whose cleanup throws,
in a subprocess, and assert the child exits 0 — a test that goes red when the
guard is deleted.

## Before

```
Round 222, for reference:
  _detached guard removed, core suite:   +1395 ~1, All other tests passed
```

## Mechanism

**Two witnesses were built and both failed to fail.**

Attempt 1 — the incident's own shape: a client hangs up mid-call, so
`_handleClientCancellation` runs. Ablated, the child still exited 0. Reading
found why: that function calls only `_closeResponder`, which has its own
`try/catch`, and `_cleanupStream`, whose every user-code surface is guarded —
`RpcCallScope.close()` wraps each disposer in `try/catch` with a timeout, and
`releaseStreamId` is wrapped too.

Attempt 2 — aimed at the 7 `_detached(responder.done.whenComplete(...))` sites,
where `whenComplete` propagates its receiver's error: a handler that raises
mid-call. Ablated, the child still exited 0.

Then, instead of a third guess, the guard itself was instrumented to print
whenever the future it wraps rejects:

```
                              detached rejections   ablated: exit code
  handler throws mid-call            0                     0
  client hangs up mid-call           0                     0
  clean call                         0                     0   <- control
```

**Nothing reaches it.** The sweep of all 25 call sites says why — every wrapped
expression is already guarded from the inside:

```
 15  _sendGrpcErrorAndCleanup(...)   try/catch around the send,
                                     finally -> _cleanupStream
  7  responder.done.whenComplete(
       () => _cleanupStream(id))     a handler throw becomes a gRPC error
                                     upstream, so done completes NORMALLY
  3  _cleanupStream(id)              _closeResponder, RpcCallScope.close and
                                     releaseStreamId all catch
  1  _handleClientCancellation(...)  calls only the two above
  1  _respPingHandler.respond(...)   its own try/catch/finally
```

So round 222's green suite was not a coverage gap. It was an unreachable branch,
and B-20's premise does not hold.

## After

n/a — nothing changed. `git diff` empty, `analyze` green.

## Canary

n/a — no fix. The ablation is the instrument, and it is reported above: with
`_detached` reduced to `unawaited(work)`, all three arms still exit 0.

## Gate

No code changed — both the ablation and the print instrumentation were reverted
in place and `git diff` is empty. The gate proper is the one HEAD passed at
round 224.

## Not fixed

**Q2 of the review is a NO, and the verdict has to say so.** The control arm and
the case arms all read zero, so the harness was never shown able to see a
process death — only that it exits 0 on a benign run. Nothing available made a
detached future reject, so that half stays unproven. The claim this round
supports is therefore the narrow one: *on the three scenarios driven, nothing
rejects, and all 25 wrapped expressions are internally guarded by reading*. Not
"no path can ever reject".

That is enough to close B-20, because B-20 asked for a witness and the
measurement says there is nothing to witness. It is not enough to say the guard
is useless — it is the backstop for exactly the refactor round 222 feared, and a
sixteenth call site wrapping something unguarded would reject into it silently,
with still no test to notice. **Keep it.** Recorded as
[C-24](../checked/C-24-detached-guard-is-unreachable.md).

**The isolate half of B-20's decision is untouched.** The owner asked for both
witnesses, "two witnesses, one shape". The `_detached` half is answered by C-24;
the isolate startup-teardown half (B-04's closing note) is a different guard on
a different path and was NOT swept here. Round 223's ablation of it stands
unexplained, and it may be either of L-04's two cases.

## Links

Lead `../backlog/B-20-detached-guard-has-no-witness.md` — closed by this round,
as a negative rather than as the test it asked for.
Negative `../checked/C-24-detached-guard-is-unreachable.md` — new.
Lesson `../lessons/L-04-a-guard-with-no-witness.md` — amended: a green ablation
has two explanations, and telling them apart comes BEFORE writing a witness.
Round `222-every-site-guarded-the-guard-untested.md` — whose reading of its own
ablation this round corrects.
Round `223-the-isolate-exception-closed-and-a-pattern.md` — the isolate half,
still open to the same question.
