---
round: 570
verdict: FIXED
packages: [rpc_dart_http2]
lens: RPC-17
bench: P-191 — new
budget: probes 1/5, canaries 1/5
commit: yes
release: changelog
---

# Round 570 — the half nobody closed

## Target

`B-180`, whose first claim round 568 had already discharged without knowing it: "`onDone` removes
`_activeStreams`/`_halfClosedLocal` but not `_outgoingPumps`" was fixed there, measured against
all seven maps. What remained is the part that still held — the local half left open — and it is
the one the lead's own severity line is about ("stream and pump leak against servers that do not
RST").

Taken because the rigs from rounds 567-569 already answer it and because the cost is at the PEER,
which is the class of defect nothing on this side can see.

Lens RPC-17: a ledger whose growth nothing watches — here the ledger belongs to the server.

## Hypothesis

When the server answers and ends first, `onDone` removes the id from `_activeStreams`, so
`releaseStreamId`'s RST branch cannot fire and `finishSending` returns early. Nothing closes our
half, and the server holds a half-open stream per call.

## Before

```
WITNESS  3 uploads, the pipeline releases each id
    streams the server accepted   3
    whose incoming side ENDED     0
    transport maps                all 0

ARM      3 uploads, nothing released (a direct user)
    whose incoming side ENDED     0

CONTROL  3 uploads that half-close with the request
    whose incoming side ENDED     3
```

**0 of 3 against the control's 3 of 3**, with one variable: whether the client's request carried
`endStream`. Every per-stream map on our side reads 0 in both arms, which is why nothing here ever
caught it — the leak is entirely in the peer's stream table, one
`MAX_CONCURRENT_STREAMS` slot per call for the life of the connection.

Probe:
`packages/transport/rpc_dart_http2/.dart_tool/probe/b180_local_half_stays_open.dart`.

**The first version of this probe read the counts AFTER `transport.close()` and got 0 against 3
the wrong way round** — `close()` terminates whatever the transport still tracks, so the teardown
ended the streams and the arm that released its ids looked worse than the one that did not. The
counts are now captured before the teardown.

## Mechanism

The inline release in the stream's `onDone` removes the `_activeStreams` entry. Both paths that
could close our half need it: `releaseStreamId` terminates only `if (stream != null && !halfClosed)`,
and `finishSending` returns early on `_activeStreams[streamId] == null`. So after the server ends
first, no code path can reach the stream again.

## After

```
WITNESS  whose incoming side ENDED  3
ARM      whose incoming side ENDED  3
CONTROL  whose incoming side ENDED  3   unchanged
```

The inline release now terminates the stream when it is still open and we have not half-closed —
`RST_STREAM`, for the reason `releaseStreamId` already gives: a stream whose request side never
finished is one RST is the legal way to drop. The `_halfClosedLocal` guard is the same one that
site uses, which is what keeps a normal unary call from being reset after a clean finish.

## Canary

```
`&& 1 < 0` on the terminate condition

  our half closes when the server ends the response first
    Expected: <3>
      Actual: <0>
    a stream left half-open at the peer holds a MAX_CONCURRENT_STREAMS slot for
    the life of the connection, and nothing on this side can see it

  CONTROL passes
```

## Gate

```
melos run analyze                SUCCESS   21 packages + rpc_dart_wasm
melos run test:unit --no-select  SUCCESS   15 packages; rpc_dart_http2 +270
melos run format:check           SUCCESS   0 changed
melos run license:check          SUCCESS   2174 / 2174, REUSE compliant
```

The whole `rpc_dart_http2` suite was run before the test was written, because this changes a path
every stream takes: `+268`, green.

## Not fixed

**Whether the server frees the slot is inferred, not measured.** What the probe reads is the
server's incoming side ending, which is the client's half-close arriving; that a conforming server
then releases its `MAX_CONCURRENT_STREAMS` slot is HTTP/2's rule rather than something this rig
establishes. The honest claim is "the client now closes its half", and the slot follows from the
protocol.

**Only the clean-end path is driven.** `onDone` also fires after an error (`onError` then `onDone`,
since `cancelOnError` is false), where the peer has usually reset the stream already and the
`_activeStreams` entry may be gone for a different reason. Not varied here.

**The lead's "later sends fail with 'Send metadata first'" is untouched** — it describes what a
caller sees after the id is gone, which is now moot for the leak but was never measured as a
complaint.

## Links

Lead `../backlog/B-180-http2-server-first-end-leaves-the-local-side-open.md` — CLOSED, its first
claim by round 568 and the rest here.
Round `568-the-send-that-went-nowhere.md` — where `_outgoingPumps` on this path was fixed.
Bench `../probes/P-191-does-our-half-close-when-the-server-ends-first.md` — new.
Lens `../lenses/RPC-17-limit-fires-after-residency.md` — `applied: [570]`.
Lesson: none. The probe's own error — counts taken after the teardown — is `measurement.md` item 5
("ask which SIDE of the system the number was taken on"), already written.
