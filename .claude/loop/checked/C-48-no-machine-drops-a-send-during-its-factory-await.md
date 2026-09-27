---
round: 449
commit: 3f88d9fa
paths: [packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart, packages/core/rpc_dart/lib/src/resilience/client_connection.dart, packages/transport/rpc_dart_websocket/lib/src/websocket_caller_transport.dart]
probe: packages/transport/rpc_dart_http2/.dart_tool/probe/send_during_the_factory_await.dart
scope: [rpc_dart_http2]
---

> **Read the scope line before reusing this.** http2 was BENCHED; the proxy was
> settled structurally by reading; the WEBSOCKET arm was not exercised at all.
> The negative covers the silent-drop claim, not the whole table below.

# C-48 — no reconnect machine drops a send during its factory await

## The claim that was checked

B-76, quoting the websocket transport's own comment: `_disconnected` set only in
the catch was *"false for the whole factory await … so `_ensureUsable` passed and
work went into the CLOSED inner: sends accepted and dropped silently."* The lead
carried that forward to http2, which does set the flag only in its catch
(`:1848`).

**The window is real and the consequence is not.** All three machines refuse a
send during their factory await, by three different mechanisms.

## Measured

http2, factory stalled 800 ms, a send issued 200 ms in:

```
control, no reconnect        ACCEPTED (no error)
during the factory await     RpcStatusException code=14
after reconnect completed    ACCEPTED (no error)
during the await: health=degraded  disconnected=false
```

`disconnected=false` confirms the flag-timing window exactly as the lead
describes it. The send is still refused: the old connection was discarded before
the await, so the send path answers UNAVAILABLE rather than accepting anything.
The control on both sides of the window is what makes that a measurement — the
harness does let a send through when nothing is reconnecting.

## Control

Two, one on each side of the window: the same `createStream()` + `sendMetadata()`
before any reconnect and after it completed, both ACCEPTED. Without them a
refusal inside the window is equally consistent with a harness that cannot send
at all, and the negative would be hope.

The third control is the `health()` read INSIDE the window. It reports
`disconnected=false`, which is what makes this a refutation of the claim rather
than an untested claim: without it, the refusal could simply be the flag having
been set earlier than the lead assumed, and nothing would have been measured.

## The other two machines

The proxy was established by READING, and structurally rather than by timing:
`_retire` and `detach` set `_inner = null` before any factory runs, and
`_require()` throws `FAILED_PRECONDITION` on a null or closed inner. There is no
flag whose timing could be wrong, because the guard is the ABSENCE of the
transport.

## Why this is not simply good news

The three refusals disagree, and one of them disagrees with itself:

```
websocket   _disconnected before the await   FAILED_PRECONDITION
http2       old connection discarded         UNAVAILABLE   (during the await)
http2       _ensureUsable, flag set          FAILED_PRECONDITION
the proxy   _inner = null, _require()        FAILED_PRECONDITION
```

http2's `_ensureUsable` carries a comment saying its code matches the websocket
sibling *"deliberately: this state used to surface as StateError there and
RpcStatusException here, so no single `catch` covered both"*. During the factory
await that care is undone by timing alone: the same logical state — this
transport is between connections — answers UNAVAILABLE.

FAILED_PRECONDITION says *call reconnect()*; UNAVAILABLE says *retry*. A caller
that reconnects on one and retries on the other gets a different strategy
depending on how far into a reconnect its send happened to land.

**That is what remains of B-76**, and it is not the silent drop the lead was
filed for.

## Do not re-run this to look for the silent drop

It is not there on http2 and cannot be on the proxy. What is worth measuring is
the CODE a caller receives, per machine and per moment, which the table above
starts and does not finish: the websocket arm was not benched here, only read.
