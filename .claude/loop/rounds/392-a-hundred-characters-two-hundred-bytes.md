---
round: 392
verdict: FIXED
packages: [rpc_dart_websocket]
lens: RPC-07
bench: P-81 — new
commit: yes
---

# Round 392 — a hundred characters, two hundred bytes

## Target

The owner's audit of core and the four transports, W1. Taken over U1 because it
is self-contained and confirmed by reading in one file, where U1's fix removes
an error path a previous round added deliberately and needs its own measurement
first — filed as B-57 with everything this round verified.

RPC-07: the defect's worst arm is on a runtime the ordinary gate does not run.

## Hypothesis

`closeForProtocolError` trims its reason by CHARACTERS against a limit
expressed in BYTES, so a peer-controlled non-ASCII message defeats the close.

## Before

Confirmed by reading first, and the file contradicts itself three lines apart:

```dart
// WebSocket caps the close reason at 123 BYTES and dart:io throws past
// that, turning a tidy protocol close into an exception on the teardown path.
final trimmed = reason.length > 100 ? '${reason.substring(0, 97)}...' : reason;
```

`reason.length` is UTF-16 code units. The text is peer-controlled:
`validateMetadata` throws `'Invalid metadata header name: ${header.name}'`, and
a header name is most often invalid for being non-ASCII;
`channel_transport.dart:705` hands `violation.message` straight to this method.

Measured on a real socket, a reason of **84 characters and 138 bytes** — sized
to sit UNDER the old 100-character trim and OVER the 123-byte cap, or the arm
would prove nothing:

```
Invalid argument (reason): reason must be <= 123 bytes long when encoded as
UTF-8  (package:web_socket/src/utils.dart, checkCloseReason)
...
TimeoutException after 0:00:05.000000: Future not completed
```

Probe: `test/protocol_close_reason_is_bytes_test.dart` (P-81).

**The current SDK's VM behaviour is the owner's BROWSER arm, not their VM one.**
Their reading predicted an over-long control frame and a 1002 from the peer.
`package:web_socket` now validates and THROWS instead — which `catch (_) {}`
swallowed, so `sink.close()` never ran at all while `_closed` was already true,
making the ordinary `close()` a no-op. The socket stays open and the peer is
never told. Worse than predicted, and the same on both platforms.

## Mechanism

Two cuts of one string, disagreeing about the unit. Nothing else.

## After

```
WITNESS: the peer sees our protocol close, not a framing error   passes
         close code 4400, reason <= 123 bytes on the wire
GUARD:   a short ASCII reason is delivered whole                  passes, untrimmed
```

## Canary

Two halves, canaried separately, and the second result is the interesting one.

**The byte trim** removed (`return reason;`): the witness fails with the SDK's
own `Invalid argument (reason): reason must be <= 123 bytes` and then the 5 s
timeout, because the close never happens. So the trim is what carries the fix.

**The fallback** removed (`catch (_) {}` with no second close), trim kept:
**both tests still pass.** The fallback is therefore NOT witnessed here, and
that is recorded rather than glossed — with the trim in place nothing on the VM
rejects the reason. It is kept for the arm this test cannot reach, where
`close()` rejects a reason the trim would accept, in the same class as C-26's
unreachable-but-load-bearing guard.

## Gate

`melos run analyze` clean over 21 packages + wasm — it caught an unused import
in the new test, fixed; `format:check` clean; `license:check` compliant;
workspace suite **SUCCESS in all 15 packages**, rpc_dart_websocket **+173**.

## Not fixed

**B-57 — U1**, the owner's second finding, filed with this round's verification
rather than fixed. Confirmed by reading: `UnaryResponder` subscribes to the
WHOLE connection broadcast and then filters by stream id, while the pipeline
creates it with `id: streamId` and feeds the request itself through
`handleMessage` — so for every pipeline responder the subscription delivers
nothing and costs one `async` callback per frame per live handler.

What stopped the fix here is the part the owner's note assumes: dropping the
subscription also drops its `onError`, which answers the caller with a trailer.
The pipeline's own `onError` **logs only** (`responder_pipeline.dart:403`); only
its `onDone` aborts streams. So the loss is real for a transport error that does
NOT close the stream, and whether that state exists needs measuring. A better
fix than removing it is recorded in the lead: subscribe to
`getMessagesForStream(id)` instead — per-stream, so the fan-out goes, and
`channel_transport.dart:182` already withholds ADVISORY errors from per-stream
controllers, which fixes the second half of U1 at the same time.

Also still open from the owner's list: F3, G1, B-39, B-36, B-53's narrow half,
B-56.

## Links

- RPC-07 — the lens; `applied:` gains 392
- P-81 — the bench; its fixture is sized to the gap between the two units
- B-57 — U1, verified and filed
- C-26 — the precedent for keeping a guard this test cannot reach
