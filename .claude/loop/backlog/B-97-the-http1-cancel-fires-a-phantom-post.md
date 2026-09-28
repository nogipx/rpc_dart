---
status: closed (round 488)
round: 488
commit: d3363ea4
paths: [packages/transport/rpc_dart_http/lib/src/rpc_http_caller_transport.dart, packages/core/rpc_dart/lib/src/rpc/streams/base_processor.dart]
probe: P-127
reason: "closed — the witness was built and CONFIRMED it, 2 requests against a control's 1, and found a worse second window the lead does not name"
---

# B-97 — cancelling a call over HTTP/1.1 sends a brand-new POST to /Unknown/Unknown

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**high**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

The HTTP caller has no `IRpcStreamReset`, so core's cancel falls back to `sendMetadata(endStream: true)`; `_pending` is already empty once the request fired, so `sendMetadata` creates a new pending call with path `/Unknown/Unknown` and fires it — the server answers UNIMPLEMENTED and the real handler is never cancelled.

## The shape

`packages/transport/rpc_dart_http/lib/src/rpc_http_caller_transport.dart:291-298`:

```dart
final methodPath = metadata.methodPath ?? '/Unknown/Unknown';
_pending[streamId] = _PendingCall(methodPath: methodPath, requestHeaders: ...);
if (endStream) {
  await _fireRequest(streamId);
}
```

`_fireRequest` (`:318`) removed the original entry when the request went out.
Core's `_notifyPeerOfCancellation` (`base_processor.dart:77-136`) tries
`IRpcStreamReset` first — this transport does not implement it — then sends
`{x-client-cancelled: true, x-cancellation-reason, grpc-status: 1}` with
`endStream: true`.

## Why it matters

Every ordinary cancel of an in-flight unary call (token, `cancelRequest`,
`cancelMethod`) costs a second HTTP request that the server logs as an
unregistered method, while the first request's handler runs to completion. In a
browser the extra request also triggers a failing CORS preflight:
`x-client-cancelled` and `x-cancellation-reason` are not in
`_requiredGrpcAllowedHeaders`.

## Witness a round would build

HTTP server with a counting middleware; a unary handler parked for 2 s; cancel
the caller's token at 100 ms. Count requests reaching the server and their paths.
Expected today: 2, the second `/Unknown/Unknown`.

## Fix sketch

`sendMetadata` with `endStream` and no pending call: return (nothing to send). For
real cancellation implement `IRpcStreamReset` by aborting the in-flight request
(`http` 1.6's `AbortableRequest`, see B-lead on abandoned calls).

## Owner decision

—

## Closed (round 488) — confirmed, with a second window the lead does not name

The witness was built as designed and read exactly what it predicted: `2`
requests, the second `/Unknown/Unknown`.

```
                       requests reaching the server
after the request fires
  cancel      before   2  [/Svc/slow, /Unknown/Unknown]
  cancel      after    1  [/Svc/slow]
  no cancel            1  [/Svc/slow]

before the request fires
  cancel      before   1  [/Unknown/Unknown]  body 0 bytes
  cancel      after    1  [/Svc/slow]         body 16 bytes
```

**The pre-fire window is the worse half.** The assignment to `_pending[streamId]`
is unconditional, so a notice arriving before `_fireRequest` REPLACES the
pending call: the method path and the whole buffered body go with it and the
real request is never sent. Not a second request but a lost one.

Fixed with the sketch's first clause, generalised one step: not "endStream and
no pending call" but **no methodPath at all**, which is the property that makes
a frame unable to open a call here. That covers the pre-fire window too, where
there IS a pending call.

**The sketch's second clause is NOT done and is deliberately left to B-140**:
implementing `IRpcStreamReset` over `package:http` 1.6's `AbortableRequest`
(present in the lockfile, checked). The server's handler still runs to
completion in every arm. B-140 is the same abort seen from the other side.

The browser half — `x-client-cancelled` failing CORS preflight — is moot rather
than fixed: the request carrying those headers is no longer sent.

**A finding about the core API, found through a test that failed on the fix**:
`methodPath` is a FIELD on `RpcMetadata`, not a header, so
`RpcMetadata([...md.headers])` silently drops it. A first-party test had been
sending its request to `/Unknown/Unknown` for that reason while asserting only
on headers.
