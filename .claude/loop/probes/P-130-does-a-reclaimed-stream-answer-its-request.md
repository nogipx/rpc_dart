---
file: packages/transport/rpc_dart_http/.dart_tool/probe/b100_release_hangs.dart
round: 491
commit: 00e27930
paths: [packages/transport/rpc_dart_http/lib/src/rpc_http_responder_transport.dart, packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart]
status: valid
---

# P-130 — does a reclaimed stream answer its request?

## Why it exists

On HTTP/1.1 the shelf handler returns a completer's future, so "the call ended"
and "the HTTP request was answered" are two different facts. The bench asks the
second one, which nothing in the library reports.

## The harness

One unary call with a 500 ms deadline against a handler that sleeps 10 s, so the
pipeline's reclaim (deadline plus a 2 s grace) fires while the handler is still
running. The varied thing is whether the handler COOPERATES with its
cancellation token.

Counted in a shelf middleware wrapped around `responder.handler`: requests
`arrived`, and requests `answered` — incremented only after the awaited future
completes. Plus `health().details['pendingRequests']`.

## The numbers (round 491)

```
                                 arrived  answered  pendingRequests
ignores its token   before          1        0            0
ignores its token   after           1        1            0
cooperates (control)                1        1            0
```

## Measures

Whether the future the shelf server is awaiting ever completed, counted on the
server side of the boundary. The CALLER cannot serve: it reports
`RpcDeadlineExceededException` in every arm, because its own deadline fires
regardless of what the server does.

## Control

The same rig with a cooperative handler, which answers all along. One varied
thing — the handler's own `await context.cancellationToken.cancelled`.

`pendingRequests: 0` in every arm is the second finding rather than a control:
`health()` reads `_pending`, and the reclaim has already removed the entry, so a
drain polling it sees an idle server with a response still unwritten.

## What it establishes, and what it does not

Establishes: a stream released before it answered left its HTTP request open,
and the transport's own health could not see it.

Does NOT measure how long the socket then stays open, nor what the client
eventually does with it — the arm ends at three seconds. And it drives only the
DEADLINE reclaim; `releaseStreamId` has other callers, which the fix covers by
construction but which this bench does not exercise.
