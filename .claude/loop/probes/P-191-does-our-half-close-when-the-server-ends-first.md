---
file: packages/transport/rpc_dart_http2/.dart_tool/probe/b180_local_half_stays_open.dart
round: 570
commit: b938fb5e
paths: [packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart]
status: valid
---

# P-191 — does our half close when the server ends the response first?

## Why it exists

B-180 asked for "a grpc-go server answering a client-stream before the client half-closes; inspect
stream state". The stream state that matters is not ours — every per-stream map on this side reads
0 either way, which is exactly why nothing caught this. **The observable is at the server**: whether
each accepted stream's incoming side ever completes.

## The harness

A raw `http2.ServerTransportConnection` that answers in full as soon as the first DATA frame
arrives, without waiting for the client to half-close — what a server does when it can answer
early. `onDone` on its incoming side is the measurement: it fires when the client ends its half,
and not otherwise.

Three arms, three uploads each: the pipeline's shape (release the id after the call), a direct
user's (release nothing), and a CONTROL whose request carries `endStream` the way a unary call does.

## The numbers (round 570)

Before:

```
WITNESS  accepted 3, incoming side ENDED 0, transport maps all 0
ARM      accepted 3, incoming side ENDED 0
CONTROL  accepted 3, incoming side ENDED 3
```

After:

```
WITNESS  ENDED 3
ARM      ENDED 3
CONTROL  ENDED 3     unchanged
```

## Measures

Streams accepted at the server, and how many of their incoming sides completed. Plus the four
per-stream maps on our side, which read 0 throughout and are the reason this needed a peer-side
observable at all.

## Control

**The control differs by one thing: whether the request carried `endStream`.** It reads 3 of 3
before and after, so the witness's 0 is about the missing half-close and not about the server
failing to notice one.

**The accepted count is a second control, on the premise**: 3 in every arm, so the uploads
happened and a 0 is not three calls that never left.

## What it establishes, and what it does not

Establishes that a server answering before the client half-closed was left holding the client's
half open — 0 of 3 against a control's 3 of 3 — and that terminating the stream in the inline
release closes it without moving the control.

Does NOT establish that the server frees its `MAX_CONCURRENT_STREAMS` slot. What is read is the
half-close arriving; the slot is HTTP/2's consequence of that, not this rig's reading.

Does NOT drive `onDone` after an ERROR, where the peer has usually reset the stream already and the
entry is gone for another reason.

**A note on where the number is taken.** The first version read the counts AFTER
`transport.close()` and reported the two arms backwards: `close()` terminates whatever the
transport still tracks, so the teardown ended the streams and the arm that released its ids looked
worse. `measurement.md` item 5 in one line.
