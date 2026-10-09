---
file: packages/transport/rpc_dart_http2/.dart_tool/probe/b178_discarded_terminate.dart
round: 557
commit: 8160c941
paths: [packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart]
status: valid
---

# P-182 — does the future `_discardConnection` drops ever carry an error?

## Why it exists

`TransportConnection.terminate` is declared `Future terminate([int?, String?])` and
`_discardConnection` drops what it returns. A reader sees an unhandled async error waiting to
happen — and the method's own doc claimed it ran inside `runZonedGuarded`, which it never did.

Two questions the lead conflates, and only a measurement separates them: does `terminate()` error
at all on a connection whose socket is gone, and if it does, does the error arrive ON the returned
future (`.catchError` is enough) or asynchronously outside it (only a zone can see it)?

## The harness

`runZonedGuarded` around a real `http2.ClientTransportConnection.viaSocket`, with the escapes
collected and the call-site catches recorded SEPARATELY — the distinction between the two is the
whole question, so one list that merged them would answer neither.

Four arms on `terminate()`: healthy or socket destroyed, future dropped or awaited.

**The peer must be a real `RpcHttp2Server`.** The first version used a bare TCP listener, and the
positive control — `finish()` — never completed against it, because it waits for a graceful
handshake a non-HTTP/2 peer never performs. Four silent rows with a control that hung would have
read as "terminate is safe".

## The numbers (round 557)

```
  CONTROL healthy, future discarded            nothing escaped
  CONTROL healthy, future awaited              nothing escaped
  socket destroyed, future DISCARDED           nothing escaped
  socket destroyed, future AWAITED in try      nothing escaped
  POSITIVE CONTROL finish() on a live socket   ZONE: Bad state: Cannot add event after closing
  POSITIVE CONTROL finish() then terminate()   ZONE: Bad state: Cannot add event after closing
```

## Measures

Where an error ARRIVES, by destination: the zone handler, the call site's `catch`, or nowhere.
Nothing numeric — the finding is which of three places receives a throw.

## Control

**The positive control is the whole probe.** Four clean rows mean "terminate is safe" or "this rig
cannot produce the condition", and only a call known to escape separates them. `finish()` is that
call, characterised by `finish_throws_into_the_zone_test` since round 347, and it escapes here with
the same `Bad state` — so the rig can see a zone error and `terminate()` does not produce one.

The healthy rows are the second control: without them, a silent destroyed-socket row could be a
teardown that never ran.

## What it establishes, and what it does not

Establishes that dropping `terminate()`'s future costs nothing observable at either state
`_discardConnection` can be in, and therefore that the lead's "potential process kill on reconnect"
does not hold. What survives is the prose: the doc described a zone that was not there, with a
reason that belongs to `finish()`, a call this method does not make.

Does NOT drive `_discardConnection` through the transport's own `reconnect()`. The arms call
`terminate()` at the http2 layer in the two states that method can be in, which is the mechanism;
a reconnect against a half-dead connection would also exercise the surrounding single-flight logic
and was not built.

Does NOT cover package:http2 2.3.1, which the workspace also resolves for some packages. Measured
on 3.1.0 only, and `finish()`'s behaviour already changed once across versions (B-53).

## Reading

rpc_dart_http2 — **measures WHERE an error arrives**, by destination: the zone
handler, the call site's `catch`, or nowhere. Four arms on `terminate()`
(healthy or socket destroyed, future dropped or awaited) all silent, against a
POSITIVE CONTROL where `finish()` escapes `Bad state: Cannot add event after
closing`. **That control is the whole probe** — four clean rows mean
"terminate is safe" or "this rig cannot produce the condition", and nothing
else separates them. Its first version had no working control: the peer was a
bare TCP listener and `finish()` never completed against it, so the silence
would have read as proof. Measured on package:http2 3.1.0 only, and does not
drive the transport's own `reconnect()`.
