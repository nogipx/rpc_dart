---
file: packages/transport/rpc_dart_http2/.dart_tool/probe/send_during_the_factory_await.dart
round: 449
commit: 3f88d9fa
paths: [packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart]
status: valid
---

# P-103 — a send during the reconnect factory await

## Why it exists

B-76 claims http2 accepts and silently drops sends for the duration of
`await factory()`, because `_disconnected` is set only in the catch. The window is
a matter of TIMING, so the bench makes it wide on purpose rather than racing it.

## The harness

A `ServerSocket` that completes the HTTP/2 handshake — empty SETTINGS, then its
ACK — and answers nothing else. That is enough: the question is about the sender.

`RpcHttp2CallerTransport.viaSocket` takes an injectable `connectionFactory`
(`@visibleForTesting`, and its doc says it exists for a reconnect that behaves
differently from the original dial). The factory sleeps 800 ms, and a send is
issued 200 ms in.

`connect()` does NOT take the factory — only `viaSocket` does, which is why the
first socket is dialled by hand.

## The numbers (round 449)

```
control, no reconnect        ACCEPTED (no error)
during the factory await     RpcStatusException code=14
after reconnect completed    ACCEPTED (no error)

during the await: health=degraded  disconnected=false
```

## Measures

The outcome of one `createStream()` + `sendMetadata()`, as a string: accepted,
or the exception type and status code. Plus `health()` inside the window, which
is what confirms the flag really is false there — otherwise a refusal could be
the flag having been set after all, and the claim would be untested rather than
refuted.

## Control

Two, one on each side of the window: the same send before any reconnect and
after it completes, both ACCEPTED. Without them a refusal inside the window is
equally consistent with a harness that cannot send at all.

## What it establishes, and what it does not

Establishes: the flag-timing window is real (`disconnected=false`) and no send is
lost in it — the discarded connection refuses, UNAVAILABLE.

Does not establish what the other two machines answer. The proxy was read rather
than benched (`_inner = null` before any factory, `_require()` throws on null),
and the WEBSOCKET arm was not exercised at all. Finishing that table is what
B-76 is now for.

## Reading

rpc_dart_http2 — the window is a matter of TIMING, so it is made 800 ms wide
on purpose rather than raced. **Reads `health()` INSIDE the window**, which is
what turns "the send was refused" into a refutation rather than an untested
claim: without it the refusal could be the flag having been set after all.
Controls on both sides of the window, both ACCEPTED. `connect()` does not take
the injectable factory — only `viaSocket` does
