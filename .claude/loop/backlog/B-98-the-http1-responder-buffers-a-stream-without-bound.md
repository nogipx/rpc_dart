---
status: closed (round 489)
round: 489
commit: 9b6a5357
paths: [packages/transport/rpc_dart_http/lib/src/rpc_http_responder_transport.dart]
probe: P-128
reason: "closed — the witness was built and CONFIRMED both halves: retention tracks production, and the caller received 0 of it"
---

# B-98 — the HTTP/1.1 responder buffers a streaming response with no ceiling

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**high**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

`sendMessage` appends every response frame to `pending.bodyBuffer` until end-of-stream and nothing caps it, so any client calling an unbounded server-stream method grows server memory for as long as the handler produces — while the caller will refuse any body over one message anyway.

## The shape

`packages/transport/rpc_dart_http/lib/src/rpc_http_responder_transport.dart:469-486`:

```dart
pending.bodyBuffer.add(data);
if (endStream) {
  await _flushResponse(streamId);
}
```

## Why it matters

Memory DoS reachable by any client: open a server-stream call on a method that
streams until cancelled (subscriptions, tails, feeds). HTTP/1.1 cannot flush
before the end, so the handler's whole output is resident. The caller rejects the
body once it passes `maxFramedMessageBytes` (see the lead on one-message bodies),
so everything past that point is buffered for nothing.

## Witness a round would build

Server-stream handler emitting 64 KiB messages forever over `RpcHttpServer`;
sample RSS at 1 s intervals for 10 s. Expected: linear growth.

## Fix sketch

Fail the stream (RESOURCE_EXHAUSTED trailer, cancel the handler token) once the
buffer exceeds the caller-side ceiling; document that HTTP/1.1 server streams are
bounded.

## Owner decision

—

## Closed (round 489) — both halves confirmed in one table

```
produced   peak RSS      caller received
 512 KiB    +8720 KiB    0    (status 8)
2048 KiB   +12608 KiB    0    (status 8)
8192 KiB   +40208 KiB    0    (status 8)
  32 KiB       +0 KiB    4    ok        <- control, a stream that fits
```

The lead's own reasoning is what the second column proves: the caller refuses
any body over the same ceiling, so every retained byte past it was retained in
order to be thrown away. There is no trade to weigh.

Fixed as the sketch says — RESOURCE_EXHAUSTED once the buffer passes the
caller-side ceiling — with two details the sketch does not carry:

- **the status rides ordinary response headers**, not a 413. An HTTP status is
  translated by `grpcStatusFromHttpStatus` and reaches the caller as whatever
  that mapping says today (see B-147); the header is what this wire format uses
  for a status.
- **the pending entry stays in `_pending`, marked answered.** Removing it made
  every later frame log "no pending response", a line per message for a stream
  that runs until cancelled.

**"Cancel the handler token" is NOT done**: this transport has no reset, so the
handler runs to completion with its output dropped. A test pins that
deliberately — it is the cost of the fix and the thing that changes when B-140
lands the abort.

**A behaviour change worth naming**: the ceiling is the EFFECTIVE policy, so a
responder built with no `securityPolicy` now bounds responses at the default
16 MiB where it had none. Nothing deliverable is lost by it. B-150 owns that
null default.

Measuring this needs the largest arm FIRST — RSS does not return, so ascending
order reads `+0` for everything after the first.
