---
status: closed (round 570)
round: 570
commit: b938fb5e
release: changelog
paths: [packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart]
probe: P-191
reason: "bench — CONFIRMED at the PEER, which is the only place it is visible: 0 of 3 streams had their incoming side ended against a control's 3 of 3, with every map on this side reading 0. The `_outgoingPumps` half was already fixed in round 568"
---

# B-180 — http2 caller: when the server ends first, the request side is never ended or reset

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**medium**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

`onDone` removes `_activeStreams`/`_halfClosedLocal` but not `_outgoingPumps`; `releaseStreamId`'s RST branch needs the stream in `_activeStreams`, `finishSending` returns early — the local half stays open unless the server RSTs; later sends fail with "Send metadata first".

## The shape

`packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart:765-777, 975-979, 1015, 1196-1202`.

## Why it matters

Stream and pump leak against servers that do not RST (non-rpc_dart servers).

## Witness a round would build

grpc-go server answering a client-stream before the client half-closes; inspect
stream state.

## Fix sketch

End or reset the local side in `onDone` when it is still open.

## Outcome (round 570) — CONFIRMED at the peer, and fixed

`../rounds/570-the-half-nobody-closed.md`. Bench `P-191`.

```
                                         before   after
WITNESS  3 uploads, ids released          0 of 3   3 of 3
ARM      3 uploads, nothing released      0 of 3   3 of 3
CONTROL  3 uploads that half-close        3 of 3   3 of 3
         transport maps, every arm        all 0    all 0
```

**The observable had to be at the SERVER**, because every per-stream map on this side reads 0 — the
leak lives in the peer's stream table, one `MAX_CONCURRENT_STREAMS` slot per call for the life of
the connection. The control differs by one thing, whether the request carried `endStream`.

**Its first claim was already fixed in round 568** — `_outgoingPumps` on this path — measured there
against all seven maps rather than the one the lead named.

Fixed by terminating the stream in the inline release when it is still open and we have not
half-closed, with `releaseStreamId`'s own guard and its own reason: RST_STREAM is the legal way to
drop a stream whose request side never finished. The whole http2 suite was run before the test was
written, since this is a path every stream takes.

**A rig note worth keeping**: the first probe read its counts AFTER `transport.close()` and
reported the arms backwards, because `close()` terminates whatever the transport still tracks and
so ended the streams itself.

Not established: that the server frees the slot. What is read is the half-close arriving; the slot
is HTTP/2's consequence. And `onDone` after an ERROR is not driven.

## Owner decision

—
