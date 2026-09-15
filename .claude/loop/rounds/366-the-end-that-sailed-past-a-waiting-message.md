---
round: 366
verdict: FIXED
packages: [rpc_dart]
lens: RPC-01
bench: P-58 — new
commit: yes
---

# Round 366 — the end that sailed past a waiting message

## Target

Brought in from outside the journal: a downstream consumer's blob uploads
started failing on the release that bumped this library 5.0.1 → 6.0.0, and on
nothing else — that bump is the only functional change in it. The server refused
the same blob fifteen times over with

    Bad state: Declared length 2442197 does not match received 524288 bytes.

and there is not one reconnect in those logs to explain it. Single-frame blobs
arrived as an empty stream.

RPC-01 because its shape is credit accounting whose release is decided
elsewhere, and its stated break is "a wedged connection — a hang".

## Hypothesis

An end-of-stream carries no payload, so nothing meters it. A send with no credit
parks. If the end goes out while a message is still parked, the peer sees a
stream that finished, counts what arrived, and refuses a blob short of its
frames — while the sender is told nothing, because the parked send is not woken
either.

## Before

Two measurements, because one of them is about the version and the other about
the defect.

**The version delta — P-58.** Over a real socket through a delaying relay, at
256 KiB a frame:

| frames | 6.0.0 defaults | 5.0.1 shape |
|---|---|---|
| 2, 3, 8 | parks ~1×RTT | never parks |

Park duration tracks RTT exactly (20/40/200 ms), so it is the wait for the
peer's first grant. `initialSendWindowBytes` did not exist in 5.0.1. The parked
state is new in 6.0.0, on any link with a round trip.

**The defect — witness.** `test/transports/parked_send_after_finish_test.dart`
on pristine HEAD:

    Expected: RpcStatusException with statusCode 14
      Actual: 'never completed'

The parked sender is never woken at all, and `finishSending` has already written
the end.

A correction worth recording, because it cost two wrong conclusions: the credit
gate admits on `credit > 0`, not on whether the message FITS. So the OPENING
frame never parks — it passes and drives the balance negative — and the second
one always does. Reading the constants alone predicts the opposite. It did.

## Mechanism

`finishSending` wrote the terminal frame immediately. A `sendMessage` parked
inside `_fcAwaitCredit` was simply overtaken: the peer's stream ended with N-1
messages and a clean end, which is indistinguishable at the receiver from a
sender that had nothing more to say. The blob's declared length then did not
match what arrived, and since this library's chunker carries `blobId` and
`totalLength` on the first frame only, a stream that lost one looked to the
server like a blob it could not identify at all.

## After

`finishSending` marks the stream finished and then WAITS for a parked send on
that stream before the end goes out. `_fcAwaitCredit` takes credit before it
looks at the mark, so a grant landing during the wait still sends the message —
ahead of the end, which is the outcome worth having. A sender still parked when
the transport is torn down is refused by `_refuseIfClosed` on its way out.

Only parked sends are tracked (`_parkedSends`). The unparked path stays
synchronous: an unconditional await there adds a microtask hop to every send,
and that hop has reordered frames on this transport before.

Both halves have a test: the refusal, and — the one that must not regress — a
grant arriving during the wait putting the message out before the end.

## Canary

Two, because the fix has two parts and only one of them turned out to carry
weight.

**The wait, removed in place:**

    Expected: <4>
      Actual: <3>
    the end-of-stream must come after all four payloads, not after 3 of them

That is the truncation, reproduced on command.

**A second refusal in `_fcAwaitCredit`, removed in place: both tests still
passed.** It carried nothing — a sender parked at teardown is already refused by
`_refuseIfClosed`. It was dropped rather than committed, because a change no
canary can kill is a change with no evidence behind it.

## Gate

`melos run analyze` clean. Workspace `test:unit` green. `license:check` green.
`fvm dart test -j 8` in the changed package: 1485 passed, 1 skipped.

**`format:check` was RED before this round touched anything**, in seven files,
all of them last written by rounds of my own that did not run the gate
(`c7eff97b`, `2ec53853`). Whitespace only, none of them this round's subject —
formatted here rather than left, because a gate that has been failing for two
commits reports success for work CI rejects, which is the exact reason
`license:check` was added after round 231.

## Not fixed

**Parking itself.** `initialSendWindowBytes = 64 KiB` is smaller than a single
message this library's own users send, so it guarantees a park on the second
frame of every stream while bounding nothing — the data goes out regardless,
just a round trip later. Removing or raising it is a policy default change with
a compatibility surface, and the owner asks to be consulted before trades of
that kind. Filed as a lead.

**The last link to the field.** What ENDS a stream while a send is parked, in
the consumer's client, is still not established — the caller pauses its request
subscription for the duration of each send, so the ordinary path cannot reach
it. A deadline or a cancellation can. That is their repository's question, and
this round does not claim to have answered it.

## Links

- P-58 — does a sender park over a real socket
- Witness: `test/transports/parked_send_after_finish_test.dart`
- Guard: `test/endpoint/client_stream_must_not_end_short_test.dart` — green
  before and after; it pins the endpoint-level shape at production frame sizes
- Probe harness: `packages/transport/rpc_dart_websocket/test/first_frame_park_over_socket_test.dart`
