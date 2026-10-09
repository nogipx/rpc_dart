---
round: 787
verdict: FIXED
packages: [rpc_dart]
lens: RPC-19
bench: P-281 — new
commit: yes
release: changelog
---

# Round 787 — an empty unary payload was never answered

## Target

The network-audit skill's methods §4, level 3: a stateful fuzz against a
real responder with a liveness oracle. The gate's
`test/fuzz/hostile_peer_and_chaos_test.dart` sends metadata, data and
end-of-stream frames only, and accepts a closed connection as a pass; it
never checks what an OPEN connection still holds after an honest peer
finishes. Widened into `.dart_tool/probe/fuzz_control_frames.dart`
(cancels, grants with hostile values, finished ids, and an epilogue that
half-closes and credits every id), its control arm alone held responders on
2 of 60 sessions; the minimiser reduced one to four frames on one id, and
P-281 to the class. Set aside on the way, each by reading current code: the
CBOR decoder's indefinite-length reassembly (`StringBuffer`,
`BytesBuilder`, linear) and its bounds checks (`_readByteFast`,
`_consumeBreakMarker`); the refused-frame desync shape (round 553, every
parser refusal clears first); `decodeRpcStatus` (in the gate's fuzz).

## Hypothesis

A unary call whose only DATA frame is empty, then half-closed, is answered
by nobody and holds its stream slot until the connection closes; the other
three shapes are not affected.

## Before

P-281, n=100, one open connection:

```
  shape  empty                    truncated        complete
  u      held 100, SILENCE        held 0, 3        held 0, 0
  s      held 0, 3                held 0, 3        held 0, 0
  c      held 0, 0                held 0, 3        held 0, 0
  b      held 0, 0                held 0, 3        held 0, 0
```

At n=5000 (`reopen_leak.dart`, the fuzz's own four frames) the held count
stops at 4096, `maxActiveStreams`, and a later honest call on that
connection is refused RESOURCE_EXHAUSTED. Nothing is held after close.

Probe: `packages/core/rpc_dart/.dart_tool/probe/empty_payload_all_shapes.dart`

## Mechanism

`UnaryResponder.handleMessage` waits after an empty chunk on purpose ("an
EMPTY chunk waits too"), and the parser buffers nothing for it.
`isAwaitingRequest` asked the parser alone (`holdsPartialFrame`), so it read
false for a stream that was waiting. The pipeline's `_handleEndOfStream`
answers an incomplete unary request only when `isAwaitingRequest` is true,
and its "closed without payload" refusal needs `state.responder == null`;
the half-open reclaim is cancelled once a responder exists. No branch was
left that answers. One state, two readers, one of them blind to half of it.

## After

```
  shape  empty                    truncated        complete
  u      held 0, 3                held 0, 3        held 0, 0
  (s, c, b unchanged)
```

`unary_empty_payload_slot.dart`, n=200: `empty` held 0 answered 3;
`emptyNoEos` (no half-close at all) still held 200 — the documented
`halfOpenStreamTimeout` limitation, a request stream that never half-closes.

## Canary

`an_empty_unary_payload_is_answered_test.dart`, `isAwaitingRequest` with
the new flag ANDed with `false`: the witness failed with
`Expected: '3' Actual: <null>`; both guards stayed green. Fix restored:
3 of 3 green.

## The verdict questions

1. Yes: `u truncated` against `u empty` differ in the DATA frame's bytes
   only (5 against 0); same position, same half-close, same connection.
2. Yes: held 0 against held 100, answered 3 against no status.
3. Library side: `activeResponderCount` and `openStreams` read from the
   responder, the status read from the frames it sent.
4. The zero after the fix: the same bench showed 100 before it, and the
   window (800 ms) is four times `halfOpenStreamTimeout`.
5. Yes: `Expected: '3' Actual: <null>`.
6. One mechanism (the predicate); the message split is wording, covered by
   the witness's `contains('empty payload frame')` and the guard's
   `contains('mid-message')`.
7. FIXED: the numbers moved on the one cell and on no other.
8. CBOR reassembly and bounds, the refused-frame desync shape and
   `decodeRpcStatus`, each by current code (named in Target). Round 553's
   record was used as a pointer to `parser.dart`, which was read.
9. None.
A1. One process; the peer is a hand-built channel feeding frames, the
    responder its own default policy plus `halfOpenStreamTimeout`.
A2. Volume: ids per connection.
L1. The refusal is the new INVALID_ARGUMENT with its own message, distinct
    from the mid-frame one the guard pins.

## Gate

`melos run analyze` green; `melos run test:unit --no-select` green (15
packages, core +2118 ~1); `melos run format:check` green; `melos run
license:check` green. `fvm dart test -p node` on the witness and
`unary_tolerates_a_fragmented_frame_test.dart`: 14 of 14.

## Not fixed

The class is one shape; P-281 measured the other three, all answer.
`emptyNoEos` is the documented half-open limitation, not this defect.
B-275 still awaits the owner.

## Links

Lens `../lenses/RPC-19-one-flag-two-lifecycle-meanings.md`.
Probe `../probes/P-281-an-empty-payload-on-every-shape.md`.
Round `553-the-parser-knew-all-along.md`.
Negative `../checked/C-69-handlers-outlive-cancelled-streams-on-websocket-too.md`.
