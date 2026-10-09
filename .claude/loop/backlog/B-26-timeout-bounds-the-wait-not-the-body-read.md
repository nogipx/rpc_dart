---
status: closed (round 273) — REFUTED
round: 272
commit: eac7dde2
paths: [packages/transport/rpc_dart_http/lib/src/rpc_http_responder_transport.dart]
probe: packages/transport/rpc_dart_http/.dart_tool/probe/read_after_the_408.dart
reason: "not measured — round 272's bench answered the refusal path; this is the accepted path, read off the code and worth one arm of the same probe"
---

# B-26 — `bodyReadTimeout` bounds the wait, not the body read

Round 272 fixed the REFUSAL path's missing deadline and, in doing so, had to
learn the difference between timing a future out and cancelling its
subscription. The accepted path still does the first:

```dart
body = await readBody().timeout(
  bodyReadTimeout!,
  onTimeout: () => throw TimeoutException(...),
);
```

`.timeout` on a future completes the caller early; `readBody`'s own `await for`
is untouched and stays subscribed. So after the 408 goes out and
`_pending[streamId]` is released, the loop should keep consuming the peer's
chunks and appending them to a `BytesBuilder` nobody will read — bounded per
request by `maxMessageLengthBytes` (the check inside the loop still clears the
builder), and bounded across requests by nothing, since the stream is no longer
counted.

If that holds it is exactly RPC-14 — a timeout that drops the wait but not the
work — on a path RPC-14's sweeps never covered, and the same read-loop leak
round 272 removed from `_reject`, left behind on its sibling.

## What round 272 actually measured

Its `accept` arm settled 16 of 16 with a real 408 inside the window, which is
the evidence that the TIMEOUT fires. It says nothing about what the loop does
afterwards, because the probe's sockets were destroyed at teardown.

## The probe that settles it

`refusal_path_has_no_deadline.dart` with one arm added: after the 408 arrives,
keep WRITING body bytes on the same socket and count how many the server
consumes. Instrument `readBody`'s loop with a counter, or watch the socket's
write pressure — a server that has stopped reading stops draining the send
buffer.

Pre-fix expectation: the writes keep being accepted. Post-fix: they back up.

## Round 273 measured it — REFUTED

The read stops. 384 KiB accepted after the 408, then a 3s stall, reproduced on
two runs; the control with the deadline off took all 16384 KiB in 49 ms. dart:io
detaches the body of a finished exchange, so the RESPONSE ends the loop that the
timeout does not. `_reject` differed because its drain runs before any response
exists.

The prediction above was made from our code alone and was wrong for a reason
that is not in our code at all. Kept as
`../checked/C-31-the-408-really-does-stop-the-read.md`; bench
`../probes/P-24-read-after-the-408.md`.

## Owner decision

—
