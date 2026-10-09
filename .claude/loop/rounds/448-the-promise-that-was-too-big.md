---
round: 448
verdict: FIXED
packages: [rpc_dart]
lens: RPC-25
bench: P-102 — new
commit: yes
severity: S2
---

# Round 448 — the promise that was too big

## Target

B-81, next on the rank. Premise checked against the tree first: nothing has
touched either file since the lead's commit, and both comments are still there.

Scope: the two orderings the lead names. Both were read before anything was
changed, and `_notifyPeerOfCancellation` turned out to be ONE shared function
already — so this is not a duplicated helper, it is one helper called two ways.

## Hypothesis

`_notifyPeerOfCancellation` awaits `transport.sendMetadata`. Its own try/catch
makes "never throws" literally true and irrelevant: a catch does not catch a
hang. So on a transport whose end-of-stream send never completes, the unary
path's `await cancellationNotice` in `finally` leaves the CALL unsettled, while
the streaming sibling's `unawaited` returns.

## Before

```
unary,  hanging notice    NEVER SETTLED (hung)
unary,  normal notice     RpcCancelledException     <- control 1
stream, hanging notice    RpcCancelledException     <- control 2, the sibling
stream, normal notice     RpcCancelledException
```

Probe: `packages/core/rpc_dart/.dart_tool/probe/cancel_with_a_hanging_notice.dart`

Control 2 is what makes this about ordering rather than about the transport:
identical hanging send, opposite outcome, which is the claim the two comments
were arguing over.

## Mechanism

**Both comments are right about their own concern, and the unary one solved its
concern with the wrong instrument.** The ordering that is real is
notice-before-id-release: the notice is a frame on that stream id, and releasing
the id first means the frame lands on whatever call next holds the number.
Awaiting the notice in the call's `finally` sequenced it correctly — and in doing
so promoted it into notice-before-RETURN, which is a far larger promise, and one
a stalled write can break for ever.

## After

The release is CHAINED onto the notice instead of blocking on it, so the call
returns at once and the frame still precedes the reclaim. Bounded at 5 s, because
the leak the release exists to prevent is otherwise just moved: a wedged send
would hold the id for the life of the process.

`unary, hanging notice` reads `RpcCancelledException`.

## Canary

The old ordering put back in place:

    Expected: 'RpcCancelledException'
      Actual: 'hung'
    the cancellation is a local fact; a caller must learn of it without
    waiting on a network write that may never finish

`+2 -1`: the control and the id-release guard both stayed green.

The guard matters as much as the witness here, because the fix removes an
`await` that was doing something real. It polls `health()['activeStreams']` back
to 0 rather than sleeping once — the release now lands a microtask after the call
returns, so a single sleep would be a race.

## Gate

`melos run analyze` clean over 21 packages plus rpc_dart_wasm. `test:unit`
SUCCESS over 14 packages; `rpc_dart` 1666 passed 1 skipped. `format:check` and
`license:check` SUCCESS. In the package: `analyze lib test` clean.

## Not fixed

**No shipping transport was shown to hang this way.** The wrapper is built for
the bench. `base_processor`'s comment asserts that a transport whose send awaits
a platform reply can do it, and that assertion is still unverified — this round
shows only what happens if one does. Round 445 did WIDEN the window, though:
`sendMetadata(endStream: true)` now waits for a credit-parked send, so a notice
on a stream with a parked frame waits for the peer's grant.

**The 5 s bound is a number with no measurement behind it.** It is a backstop on
a path that normally settles immediately, so nothing here could size it. If it
ever matters, it is the wrong shape and should become a policy field.

## Links

- RPC-25 — one helper, two call orderings, and the comments arguing with each
  other (U-01: a comment justifying deliberateness is a lead, not a closed door)
- P-102 — cancel against a send that never completes
- B-81 — closed by this round
- L-16 — copy what the sibling AVOIDS: the sibling's `unawaited` was the answer,
  but copying it alone would have dropped the id ordering it never had to keep
- Witness: `test/streams/cancel_does_not_wait_for_the_notice_test.dart`
- Helper added: `HangingEndOfStreamTransport` in `test/utils/transport_wrappers.dart`
