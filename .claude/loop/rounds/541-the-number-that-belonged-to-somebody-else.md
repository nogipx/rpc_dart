---
round: 541
verdict: FIXED
packages: [rpc_dart_websocket, rpc_dart]
lens: RPC-03
bench: P-174 — new
budget: probes 1/5, canaries 3/5
commit: yes
release: changelog
---

# Round 541 — the number that belonged to somebody else

## Target

B-199, an owner decision and therefore the round's first target: **make the dropped
connection's peer state unreachable before the new one can mint anything.** Not the id
translation — the owner declined a per-frame map lookup in both directions on the priority
transport.

Lens RPC-03: stream ids restart on reconnect.

**Scope, decided before the fix.** B-199 was measured at the transport alone, and `P-161`
says in its own record that it never drove a pipeline. So the round's first arm is the
pipeline-level witness the lead asks for, and the scope is whatever that witness shows —
which turned out to be three mechanisms at three layers rather than one.

## Hypothesis

The wrapper keeps `incomingMessages` stable across a reconnect, so the responder pipeline
never learns the socket dropped. Its peer-initiated calls stay live, and the peer restarts
its numbering on the new socket, so the number comes round again while the old answer is
still owed.

## Before

```
  arm                                   "two" got       handler started / cancelled
  reconnect, id REUSED, old answer late  answered one   [one]         / []
  reconnect, first call already done     answered two   [one, two]    / []
  CONTROL no reconnect (ids 2 and 4)     answered two   [one, two]    / []
```

**The caller asking `two` was handed the answer to `one`** — a different call, from a
different caller, on a connection that no longer exists — and its own request was never
dispatched at all. Bench `../probes/P-174-what-a-reused-peer-id-answers.md`.

Row 3 is the control that makes row 1 mean a collision rather than out-of-order release
being broken by itself; row 2 is the sharper one, the same reuse of id 2 with nothing left
parked.

The collision is not contrived: a dropped connection gets a FRESH server endpoint, which
numbers its first stream from the bottom.

## Mechanism

**Three, and each one is load-bearing.** Each was found by fixing the one in front of it and
re-measuring. Removing any one puts the
defect back in a different shape, which is what the three canaries below show.

**1. The drop is never told to the responder.** The pipeline's only notice that a peer is
unreachable is `incomingMessages` ending or erroring, and the wrapper suppresses both by
design — a stable stream across reconnects is what lets subscribers survive one. So
`_abortActiveStreams` never ran, the old stream state stayed in `_respStreams`, and the new
call's opening frame on the same id read as a repeat opening frame and was ignored.

Fixed by saying it in the protocol the responder already speaks: for each id in
`_peerStreamIds`, the wrapper emits the peer's own cancellation notice
(`x-client-cancelled`) into its stable stream. That cancels the handler's token, closes its
responder and reclaims the stream state — no new interface, and no error on a stream whose
whole purpose is to survive.

Emitted BEFORE the reconnect's awaits, from both places a drop is learned (`onDone` for a
peer-started drop, the top of `_reconnectOnce` for a local one), so the cleanup has the
whole handshake to run in rather than racing the new socket's first frame.

**2. A closed responder still wrote.** `UnaryResponder.close()` cancelled subscriptions and
nothing else, so a handler parked inside `handleMessage` resumed afterwards and took the
`_callIsOver` branch — which answers CANCELLED with the token's reason. That trailer went
out on the old id and reached the new caller: `status 1: WebSocket reconnecting`, for a call
that had cancelled nothing.

Fixed with a `_closed` flag, checked before both post-handler branches. The other three
shapes had this already — `StreamProcessor.close` clears `_isActive`, which gates every
write it makes — so this is the one class that was missing it.

**3. The old call's tail cleanup acted on whatever the id named now.**
`_ensureUnaryResponder` ends with `await _cleanupStream(streamId)` AFTER awaiting the
handler. With the handler parked across the reconnect, that line ran when the number already
named the new call: it closed the new responder, released its id and remembered it as torn
down, mid-answer. The new caller then waited out its own deadline.

Fixed by giving `_cleanupStream` an `only:` parameter — the state the caller was issued for
— and passing it at every site that can run after an await. **13 of the 18 call sites.** The
five that do not pass it are the bulk teardowns (`_abortActiveStreams`,
`closeResponderResources`, the drain's forced cleanup) plus `_sendGrpcErrorAndCleanup`, which
holds no state and is reached for ids that have none; those run when the connection or the
endpoint is ending, so no new call can take the number. The two reclaim timers got the same
treatment by identity rather than presence, since `_respStreams[id] != null` is true for the
WRONG call just as readily.

A stale cleanup now returns before `_rememberClosedStream` and `_releaseHandlerSlot`, not
after: remembering the id would make the pipeline ignore the live call's own frames, and
releasing the slot would give away one that call is holding.

## After

```
  arm                                   "two" got       handler started / cancelled
  reconnect, id REUSED, old answer late  answered two   [one, two]    / [one]
  reconnect, first call already done     answered two   [one, two]    / []
  CONTROL no reconnect (ids 2 and 4)     answered two   [one, two]    / []

  zone errors: 0
```

The two control rows are unchanged, which is what says the bench still sees the mechanism.
The pipeline's own records name the two new decisions in row 1: `Operation cancelled,
stopping request handling [id: 2]` and `Skipping a stale cleanup for stream 2: the id now
names another call`.

## Canary

Three, one per mechanism. Each was switched off in place with `Edit` and restored the same
way; the guards stayed green under all three, which is what says the witness isolates each
defect rather than re-checking the others.

```
1. the wrapper says nothing (_abandonPeerStreams returns immediately)

   WITNESS the new call is not ignored as a repeat opening frame
     Expected: empty
       Actual: ['Ignoring a repeat opening frame on stream 2: the stream is
                already bound to Reverse.Ask']
     Both reconnect tests; both guards green.

2. a closed responder writes anyway (the `if (_closed) return` removed)

   WITNESS  RpcStatusException(1): WebSocket reconnecting
     the parked handler's CANCELLED notice, addressed to a caller that is gone,
     delivered to the new one. Both reconnect tests; both guards green.

3. the stale cleanup is not skipped (`only` never consulted)

   WITNESS  Expected: 'answered two'
              Actual: 'TIMEOUT'
     the old call's tail cleanup closed the new call's responder mid-answer.
     Only the first test; the cancellation half stayed GREEN, which is the split
     between mechanisms 1 and 3.
```

Canary 3 is the one worth having: mechanisms 1 and 2 are both visible as a wrong or missing
answer, and without the third the fix looks complete while the new call is torn down by a
teardown issued for another one.

**Canary 1's witness was rewritten during the verdict check**, and that is the one change the
review questions forced. It first failed with `Bad state: timed out waiting for the second
handler` — a timeout by form, because the wait for the second handler was fatal and threw
away the records that say WHY it never started. The wait is now a poll that does not throw,
and the assertion reads the pipeline's own warning. The observable was there all along; the
rig was discarding it.

## Gate

```
melos run analyze                No issues found!            21 packages + wasm
melos run test:unit --no-select  All tests passed            14 packages
melos run format:check           0 changed                   21 packages + wasm
melos run license:check          2098 / 2098, REUSE compliant
```

`format:check` failed once on `responder_pipeline.dart` and was re-run green.

In the changed packages: `rpc_dart_websocket` 241 tests, `rpc_dart` 1806 (1 skipped) — both
inside `test:unit` and both green.

## Not fixed

**The streaming shapes are unmeasured.** Only unary was driven. Their six
`responder.done.whenComplete(() => _cleanupStream(...))` sites got `only:` by inspection,
which is the same shape as the one that fired, but by construction rather than by
measurement. Filed as part of B-212.

**Whether the cleanup can lose the race is not priced.** The notice is emitted before the
reconnect's awaits, so in every run here the pipeline reclaimed the old state while the new
socket was still being opened. The rig does not vary the handshake latency, and if the new
call's opening frame ever won, the outcome would be the new call cancelled rather than a
wrong answer — the failure mode the owner's decision warned about, one step milder. Filed as
B-212.

**`melos run test:web` is RED, and was before this round.** Six failures, all in
`rpc_dart`'s `test/core/compression_never_makes_a_message_bigger_test.dart`:
`RpcStatusException(12): Unsupported grpc-encoding: gzip. Supported: identity. On web/dart2js
the built-in gzip is unavailable`. Round 513 wrote that file with no `@TestOn('vm')` and
never ran the web target, so it has been failing there since. Nothing in this round touches
compression, and `test:web` is not in the config's gate sequence. Filed as B-211.

## Links

Lead `../backlog/archive/B-199-a-reused-peer-id-defeats-the-stale-id-guard.md` — closed by this
round; its owner decision is what the fix carries out.
Lead `../backlog/B-211-the-web-target-has-been-red-since-round-513.md` — new.
Lead `../backlog/B-212-the-streaming-shapes-tail-cleanup-is-unmeasured.md` — new.
Bench `../probes/P-174-what-a-reused-peer-id-answers.md` — new.
Bench `../probes/P-161-does-a-stale-id-reach-the-new-socket.md` — the transport-level
question this one takes up at the pipeline.
Lens `../lenses/RPC-03-stream-ids-restart-on-reconnect.md` — `applied: [541]`.
Round `218-generation-tagging-cannot-work.md` — why tagging by id could not be the fix, and
why the answer had to be making the old state unreachable instead.
Round `224-refuse-a-transport-that-cannot-carry-the-watermark.md` — the same shape closed
the same way in the outbound direction.
