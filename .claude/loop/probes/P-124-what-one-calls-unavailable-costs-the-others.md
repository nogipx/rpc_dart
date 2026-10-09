---
file: packages/transport/rpc_dart_websocket/.dart_tool/probe/b94_retry_reconnect.dart
round: 485
commit: 93a37821
paths: [packages/core/rpc_dart/lib/src/resilience/retry_interceptor.dart, packages/transport/rpc_dart_websocket/lib/src/websocket_caller_transport.dart]
status: valid
---

# P-124 — what one call's UNAVAILABLE costs the others

## Why it exists

`RpcRetryInterceptor` reconnects the transport before retrying an UNAVAILABLE.
The question B-94 asks is whether that status was ever evidence about the
CONNECTION. A handler can throw it, a draining server answers it, and a single
truncated stream synthesises it — and on a websocket `reconnect()` closes the
live socket every other call is riding on.

So the bench puts two calls on one socket and fails only one of them.

## The harness

A real `RpcWebSocketServer` on an ephemeral port, counting accepted sockets. A
caller endpoint with `RpcRetryInterceptor(maxAttempts: 2)`. Call A is a
server stream yielding every 20 ms; call B is one unary call whose handler
throws a configurable status.

Three arms, one varied thing each:

- **case** — B's handler throws UNAVAILABLE.
- **control** — B's handler throws RESOURCE_EXHAUSTED, which the interceptor
  deliberately never reconnects on. Same code, same rig, one constant different.
- **dropped** — no application failure at all: a slow unary call is in flight
  when the server closes the socket from under it. This is the capability B-61
  added, and it is what keeps the fix from being a revert.

## The numbers (round 485)

```
                              sockets  A                B
case    unavailable        before  2   errored, 4 msgs  RpcStatusException
case    unavailable        after   1   alive,   30 msgs RpcStatusException
control resourceExhausted          1   alive,   30 msgs RpcStatusException

dropped (the path really died)
  with the reconnect               2   recovered: slow:x
  reconnect ablated                1   RpcNoConnectionException
```

## Measures

Sockets accepted at the server — a direct count of connections opened, not an
inference from a log — plus whether the OTHER call errored and how many messages
it went on receiving.

## Control

The RESOURCE_EXHAUSTED arm: the same failing call on the same rig, differing
only in a status the interceptor treats differently. It reads one socket both
before and after, so the second socket in the case arm is the reconnect and not
the failure.

The dropped arm carries its own control, an ablation that removes the reconnect
entirely: `sockets=1, RpcNoConnectionException` against `sockets=2, slow:x`. So
that arm is load-bearing rather than decorative.

## What it establishes, and what it does not

Establishes: one call's application-level UNAVAILABLE tore down a live socket
and failed an unrelated call on it, and gating the reconnect on the transport's
own `health()` stops that without giving up recovery on a genuinely dead path.

Does NOT establish anything about N concurrent retrying calls cascading into
serial reconnects — the lead names it and one failing call is enough to settle
the mechanism.

## Reading

485), rpc_dart + rpc_dart_websocket — **two calls on one socket, only one of
them failing.** Counts sockets ACCEPTED at a real `RpcWebSocketServer`, so the
blast radius is a connection count rather than an inference from a log. Its
control is the same rig with one constant changed — the status the failing
handler throws — and the arm that keeps the fix honest is a third one where
the path really dies, carrying its own ablation: remove the reconnect and it
falls from `sockets=2, slow:x` to `sockets=1, RpcNoConnectionException`
