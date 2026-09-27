---
round: 460
verdict: CLEAN
packages: [rpc_dart_http]
lens: RPC-25
bench: P-110 — new
commit: yes
---

# Round 460 — one terminal message, not two

## Target

B-86's remaining half. Round 447 fixed the http2 side and left the HTTP/1.1 side
explicitly unproven, with the lead's own corrected version of the claim — which is
the right way round, because the original sweep had overstated it.

## Hypothesis

The HTTP/1.1 caller builds its terminal message from a trailer set that only
`grpc-status` and `grpc-message` reach, so a response with neither ends the stream
with empty metadata and `isEndOfStream: true` — the same shape that on http2 was
read as a clean end and lost two messages of a server stream.

## Before

Reachability first, by reading: the synthesised status (`:345`) comes from
`grpcStatusFromHttpStatus` and covers non-2xx ONLY. So a 200 with no `grpc-status`
anywhere falls through to the trailer split, which yields nothing.

```
200, no grpc-status   status=14 "The stream closed before the peer sent a status"
200, grpc-status: 0   RETURNED "answer" -- a clean success
200, grpc-status: 5   status=5
```

Probe:
`packages/transport/rpc_dart_http/.dart_tool/probe/a_200_with_no_grpc_status.dart`

So the shape is reachable and the consumer IS told, with a message naming the
cause.

## Mechanism

**The difference from http2 is the NUMBER of terminal messages, not the emptiness
of the metadata** — which is the part worth keeping, because the emptiness is what
the lead reasoned from.

http2 emitted TWO end-of-stream messages: the trailers frame with no status, then a
synthesised one carrying 14. The first closed the consumer and the second was
discarded — `CLEAN END after 2 item(s)`. HTTP/1.1 emits exactly ONE (`:430`), so
there is no ordering to lose, and core's consumer boundary raises on an ending it
never saw a status for.

## After

n/a — no source change. Negative in `checked/C-52`. **B-86 closes.**

## Canary

n/a for a negative. The discriminating arm is the control: the same raw server with
`grpc-status: 0` present returns cleanly, so the refusal is the missing status and
not the harness. The third arm shows an explicit non-OK status is reported as
itself rather than collapsed into the same UNAVAILABLE.

## Gate

No source changed, so the gate is the journal's: `loop.py lint` green.

## Not fixed

**Only the unary shape was driven.** The streaming shapes reach the same single
terminal emit, which is an argument from the code and not a measurement.

## Links

- RPC-25 — the sibling transports differ in something the lead did not name: how
  MANY terminal messages they emit. Same empty metadata, opposite outcomes
- P-110 — a 200 with no grpc-status
- C-52 — HTTP/1.1 tells the consumer when a status never came
- B-86 — closed by this round; its http2 half was fixed in 447
- Round 447 and round 457's core arm — the two measurements this one completes
