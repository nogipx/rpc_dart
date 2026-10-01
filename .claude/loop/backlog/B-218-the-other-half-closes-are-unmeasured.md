---
status: open
round: 552
commit: 144a7f0e
paths: [packages/core/rpc_dart/lib/src/rpc/transports/channel_transport.dart, packages/core/rpc_dart/lib/src/rpc/transports/flow_controller.dart, packages/core/rpc_dart/lib/src/rpc/transports/stream_buffer_ledger.dart]
probe: P-180
reason: "bench — round 552 fixed the server-stream shape and witnessed only that one; the same line is reached by a client stream and a bidi stream at different moments, and the memory question the whole lead is about is still arithmetic rather than a reading"
---

# B-218 — the other half-closes, and what a decoded backlog actually costs

Split out of B-195 when round 552 closed it. Three things that round established as
UNMEASURED rather than as working.

## 1. The two shapes the fix was not witnessed on

Round 552 made an inbound end-of-stream drop a stream's flow-control state only for a stream
WE opened. The defect was found and witnessed on a SERVER stream, which half-closes its
request immediately and so hit it on every call.

A client stream half-closes when the caller finishes uploading; a bidi stream may never
half-close at all. Both reach the same line. What is unestablished:

- whether a client-stream responder's own send window survives the caller's half-close, which
  is the same question one direction over;
- whether a bidi stream that never half-closes now keeps `_advertised` and `_sendCredit` until
  teardown, and whether anything else depended on the old early drop;
- whether the `locallyInitiated` branch is right for a CALLER receiving a client-stream
  response, where the inbound terminal frame is the whole response.

The arm already exists: P-180 varies one shape and would take another with a different
contract method.

**Round 555 discharged the BIDI half of this item for the WINDOW fix.** `bidi 4372 -> 4372,
charged/msg 15 B, sendCredit: 1` with round 552's fix, against `250569 -> 496486, sendCredit: 0`
with it ablated — so the shape did have the defect and the one condition covers it. `P-180` gained
that block, and a witness is in the tree.

**The client-stream half stays open, with its risk now explicit**: 552's change only affects
streams the PEER opened, and for a client-stream upload the sender is the CALLER, which minted the
id and holds it in `_activeStreams`, so its liveness never depended on the dropped state. Lower
risk, not measured.

**Round 554 added one shape to this and left another.** B-216 is closed: a mid-frame half-close
is now answered on the server-stream and client-stream shapes too, from one place in
`StreamProcessor`. **Bidi runs through that same helper and is therefore fixed by construction
and measured by nothing** — `P-155` has no bidi column. That is the cheapest item on this lead:
one more block in an existing probe.

## 2. What a decoded backlog costs, which is the question the lead was about

P-180's `nominal` column is `size x count` and is labelled as arithmetic. The paused stream's
messages stop BELOW the decode, so nothing was shown to retain them, and round 549's rig note
says a zero-filled `Uint8List` is not resident until written anyway.

So nobody has measured the thing an operator reading `flowControlWindowBytes` actually wants:
**how much memory a window's worth of wire bytes becomes.** The honest instrument is RSS with
the payload written one byte per 4 KiB page, one arm per process — exactly the rig round 549
had to build twice. Two arms: a codec that expands (a length reconstituted into a buffer, or
a compressed payload) against one that does not.

This is also what would turn round 552's doc paragraph from a correct statement of the rule
into one with a number behind it.

## 3. `maxBufferedMessagesPerStream` does not reach this path either

Round 550's depth ceiling never fired in ANY of P-180's arms, at its default of 1024 against
backlogs of 4372 and 279623 messages. The pipeline drains the transport's per-stream
controller as fast as it arrives, so the ledger never holds a backlog, and the standing
messages are above the transport where neither bound can see them.

B-217 is the connection-wide queue. This is a THIRD place the same observation lands, and
together they are one question worth asking once: **of the three bounds on un-consumed data,
which one is holding anything for an application consuming through an endpoint?** Round 552's
answer for the window is "wire bytes, exactly". For the other two it is currently "nothing
measured".

## Why it matters

The fix in 552 is correct where it was measured and unmeasured elsewhere on a hot lifecycle
path — the same seam rounds 541, 546 and 547 all worked, and the one where 547 had to revert.
And the memory half is the half every reader of that policy field cares about.

## Witness a round would build

For (1): P-180's rig with a client-stream and a bidi contract, reading
`flowControlStateSizes` on both ends, with the fix ablated as the control — the shape round
552's canary B already has.

For (2): RSS, pages written, one arm per process.

## Owner decision

—
