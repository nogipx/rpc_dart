---
status: open
round: 405
commit: baa8f457
paths: [packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart, packages/transport/rpc_dart_websocket/lib/src/websocket_caller_transport.dart]
probe: packages/transport/rpc_dart_http2/.dart_tool/probe/which_type_escapes_when_disconnected.dart, with the websocket half in that package's copy
reason: behaviour decision — setting the flag changes what a dead http2 connection does to every in-flight and subsequent call, and the sibling's choice of type here was itself a deliberate decision by an earlier round
---

# B-61 — the http2 caller never notices it is disconnected

`RpcHttp2CallerTransport._ensureUsable` exists to "refuse work the transport
genuinely cannot do, naming which state it is in", and its message prescribes
the remedy: *"Transport is disconnected and has no connection; call
reconnect()."*

With the server gone it never fires. Measured, both transports driven the same
way, each gated on its own `health()` report first so neither arm can be
accused of racing a dying socket:

```
transport   health     createStream()   a unary call          isClosed
websocket   degraded   StateError       StateError            false
http2       degraded   no throw         RpcStatusException    false
```

Both report `degraded`, so both reached the state. Only one guard fires.

## Why

`_disconnected` is set in exactly two places on http2:

```
line 285   the KEEPALIVE failure path
line 1805  the catch in reconnect()
```

There is no connection-lost path. `pingInterval` is opt-in, so on a default
http2 caller a server that goes away leaves `_disconnected` false forever: the
guard never runs, the prescriptive message is never shown, and `createStream()`
hands out ids on a dead connection.

The websocket sibling sets it from the channel's `onDone`, with a comment that
names this exact case — *"Reached by any server restart or dropped network, with
no reconnect call involved."*

RPC-19: a flag with no value for a third state. Here the third state is "the
connection died and nobody was pinging".

## What it costs

Not a hang and not a leak — each call still fails, with a status. What is lost
is the fail-fast and the instruction: the user is never told the transport is
disconnected or that `reconnect()` is the way out, and every call pays a full
round trip to discover individually what the transport already knew.

And the same failure is classified differently per transport.
`RpcRetryInterceptor._shouldRetry` retries only `RpcStatusException` with
UNAVAILABLE or RESOURCE_EXHAUSTED, so on http2 a dead-connection call may be
retried and on websocket it never is.

## Why it is filed rather than fixed

**The websocket side's type is a deliberate decision by an earlier round**, and
its test states the argument in a table: during the reconnect window a read used
to answer "a synthetic UNAVAILABLE — which is RETRYABLE, so the caller is
invited to try the thing that cannot work", and `StateError` replaced it on
purpose. That argument applies here too, which means http2's `RpcStatusException`
may be the wrong one of the pair rather than the right one — and picking a side
is a contract decision across two published transports.

Setting `_disconnected` on connection loss is also not cosmetic: `createStream()`
would start throwing where it currently returns an id, which is the failure mode
existing http2 tests were written against.

## Owner decision

Two, and the second depends on the first:

1. Should a dead connection put the http2 caller into `_disconnected`, the way a
   dead socket does for websocket?
2. If so, should the refusal be `StateError` (websocket's deliberate choice, not
   retryable, names the remedy) or `RpcStatusException(UNAVAILABLE)` (gRPC's
   semantics, retryable — and rpc_dart's retry interceptor does not call
   `reconnect()`, so a retry would spin)?
