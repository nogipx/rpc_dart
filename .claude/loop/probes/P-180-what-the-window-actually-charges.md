---
file: packages/core/rpc_dart/.dart_tool/probe/b195_what_the_window_bounds.dart
round: 552
commit: 144a7f0e
paths: [packages/core/rpc_dart/lib/src/rpc/transports/flow_controller.dart, packages/core/rpc_dart/lib/src/rpc/transports/channel_transport.dart, packages/core/rpc_dart/lib/src/core/security_policy.dart]
status: valid
---

# P-180 — what does `flowControlWindowBytes` actually charge, and when does it charge at all?

## Why it exists

B-195 reads `185 MiB retained behind a 4 MiB window` and calls the field
"an order of magnitude looser than its own number". That reading came from one
settle time, one message shape and one policy, and the owner's decision — document
what the number means — cannot be written without knowing which quantity it counts.

## The harness

A server-stream handler producing in a tight loop into a consumer that pauses after
one message, over `RpcChannelTransport.pair()`. Four things are varied independently,
and each exists because the lead's reading has an innocent explanation without it:

1. **Settle time**, 1 s against 2 s. A BOUND does not move when the producer is
   given twice as long; a rate doubles. The lead's figure was taken at one time only.
2. **Wire size against decoded size.** The message carries a padding string that is
   serialized and a length the receiver would allocate, so the same window can be
   driven with 18 bytes on the wire standing for 1 KiB, or with 1 KiB standing for
   1 KiB. **This is the arm the lead did not have**: its `_Blob.toJson` emitted
   `{'n': 1024}`, so every "1 KiB message" was 11 bytes on the wire.
3. **The window itself**, swept 16 KiB to 4 MiB.
4. **`initialSendWindowBytes`**, off and four values, with the window held fixed.

The sender's own `flowControlStateSizes` is read at the end. `sendCredit: 0` says
no credit entry exists for the stream, which is the difference between a window
that is generous and one that was never applied.

## The numbers (round 552)

Before the fix — the window is held at 64 KiB in every row and only the initial
send window moves:

```
  initial off      510806 msgs   sendCredit: 0  advertised: 0  waiters: 0
  initial 4 KiB      4372 msgs   sendCredit: 1  advertised: 1  waiters: 1
  initial 16 KiB     4372 msgs
  initial 64 KiB     4372 msgs
  initial 1024 KiB   4372 msgs
```

After:

```
  initial off        4372 msgs   sendCredit: 1  advertised: 1  waiters: 1
  ... every row identical, 4372
```

What the window charges, at 64 KiB, two settle times each:

```
  wire 18 B   decoded 1 KiB     4372 msgs   charged 15 B/msg   wire 4 KiB
  wire 1 KiB  decoded 1 KiB       66 msgs   charged 993 B/msg  wire 66 KiB
  wire 1 KiB  decoded 16 KiB      66 msgs   charged 993 B/msg  wire 66 KiB
```

And the sweep, 1 KiB decoded, 2 s:

```
  16 KiB    1095 msgs    64 KiB   4372 msgs
 256 KiB   17479 msgs  1024 KiB  69908 msgs      15 B/msg throughout
```

## The bidi block (round 555)

A fifth thing varied: the SHAPE. A bidi caller half-closes its request side while the responder
goes on sending, which is the same inbound end-of-stream on a stream whose call is not over.

```
  bidi, initial off     msgs 4372 -> 4372   charged/msg 15 B   sendCredit: 1  advertised: 1
  bidi, initial 64 KiB  msgs 4372 -> 4372   charged/msg 15 B   sendCredit: 1  advertised: 1

round 552's fix ablated:
  bidi, initial off     msgs 250569 -> 496486   sendCredit: 0  advertised: 0
```

Same `15 B` charge as the server-stream sweep, same bound, and the ablation shows the arm can see
the defect — which is what makes the clean rows a measurement rather than a restatement.

## Measures

Messages the handler produced, counted inside the handler — the only place that
knows what the application generated. Then the IMPLIED charge per message, window
divided by count, which is what makes "the window is exact" readable without
arithmetic in prose: `66 x 993 B = 65 538` against a 65 536-byte window.

## Control

Four, and the round needed all of them:

- **TIME.** `4372` at 1 s and at 2 s is a bound; `251292 -> 487856` with the field
  off is a rate. Without this arm a single reading cannot tell them apart, which is
  how the lead came to read a rate as a multiplier.
- **THE FIELD OFF**, which is also the canary's shape.
- **WIRE HELD, DECODED VARIED.** `66` messages at both 1 KiB and 16 KiB decoded.
  Same window, same count, 16x the backlog — the only arm that separates "the
  window is loose" from "the window counts something else".
- **RESUME.** `4372 -> 182174, all received`. A bound that never releases is a
  wedge, and the witness cannot tell those apart either.

## What it establishes, and what it does not

Establishes that the window charges WIRE bytes and holds to them within one
message; that the count it admits therefore varies with the message's serialized
size and is blind to what it decodes to; and that before this round it did not
apply at all unless `initialSendWindowBytes` was set, because that seed was the
only thing that ever created a credit entry.

Does NOT measure MEMORY. The `nominal` column is size x count and is labelled as
arithmetic: the paused stream's messages are stopped below the decode, so nothing
was shown to retain them, and a zero-filled `Uint8List` would not be resident even
if it were (round 549). **The lead's 185 MiB is that same arithmetic**, which is
why this probe prints the wire column beside it.

Does NOT cover the other call shapes. A client stream and a bidi stream half-close
at different moments, and the defect this probe found is about when a half-close
lands.
